import Foundation
import CircleCore

/// WebSocket sync with the Cloudflare Durable Object, end-to-end encrypted:
/// rows are sealed with the account key before they're sent and opened when they arrive.
/// Protocol (JSON text frames):
///   -> {"t":"hello","since":N}      -> {"t":"push","rows":[...]}
///   <- {"t":"rows","rows":[...],"cursor":N}
/// What a sync connection feeds: a vault's list (Store) or the list of vaults (VaultIndex).
@MainActor
protocol SyncTarget: AnyObject {
    var vaultID: String { get }
    var onLocalChange: (() -> Void)? { get set }
    func pendingRows(_ done: @escaping ([Todo]) -> Void)
    func cursor(_ done: @escaping (Int64) -> Void)
    func applyRemote(_ rows: [Todo], cursor: Int64?)
    func setSyncState(_ s: SyncState)
}

@MainActor
final class SyncClient: NSObject, URLSessionWebSocketDelegate {
    private weak var store: SyncTarget?
    weak var account: Account?
    private var config: SyncConfig?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var open = false
    private var backoff: TimeInterval = 0.5
    private var pushScheduled = false
    private var pingTimer: Timer?

    init(store: SyncTarget) {
        self.store = store
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        store.onLocalChange = { [weak self] in self?.schedulePush() }
    }

    func start() {
        config = SyncConfig.load()
        // Personal needs the account key; a vault needs its own key. Either way, a session.
        guard config?.socketURL != nil, account?.session != nil, vaultKey != nil else { config = nil; store?.setSyncState(.local); return }
        connect()
    }

    /// Re-read sync.json (after running deploy) and reconnect.
    func reload() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil; open = false
        start()
    }

    private func connect() {
        guard let cfg = config, let target = store, let url = cfg.socketURL(vault: target.vaultID),
              let bearer = account?.session else { return }
        store?.setSyncState(.connecting)
        var req = URLRequest(url: url)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receive(on: t)
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated {
            guard webSocketTask === task else { return }
            open = true
            backoff = 0.5
            store?.setSyncState(.synced)
            store?.cursor { [weak self] since in self?.send(["t": "hello", "since": since]) }
            schedulePush()
            pingTimer?.invalidate()
            pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.task?.sendPing { _ in } }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated { if webSocketTask === task { dropped() } }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { if task === self.task { dropped() } }
    }

    private func dropped() {
        open = false
        task = nil
        pingTimer?.invalidate()
        guard config != nil else { return }
        store?.setSyncState(.offline)
        let delay = backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.task == nil else { return }
            self.connect()
        }
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, t === self.task else { return }
                switch result {
                case .failure:
                    self.dropped()
                case .success(let msg):
                    if case .string(let s) = msg { self.handle(s) }
                    else if case .data(let d) = msg, let s = String(data: d, encoding: .utf8) { self.handle(s) }
                    self.receive(on: t)
                }
            }
        }
    }

    private struct Incoming: Decodable {
        let t: String
        let rows: [SealedRow]?
        let cursor: Int64?
    }

    private var unreadable = 0

    private func handle(_ text: String) {
        guard let d = text.data(using: .utf8),
              let m = try? JSONDecoder().decode(Incoming.self, from: d), m.t == "rows",
              let vault = vaultKey else { return }
        var todos: [Todo] = []
        for r in m.rows ?? [] {
            if let t = try? vault.open(r) { todos.append(t) } else { unreadable += 1 }
        }
        if unreadable > 0 && todos.isEmpty && !(m.rows ?? []).isEmpty {
            AppModel.shared.say("some synced items couldn't be decrypted with this Mac's key")
        }
        store?.applyRemote(todos, cursor: m.cursor)
        // An echo of our own push: more may be waiting (uploads go 500 at a time).
        if m.cursor == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.schedulePush() } }
    }

    private func schedulePush() {
        guard open, !pushScheduled else { return }
        pushScheduled = true
        // Coalesce bursts (typing, multi-edits) into one frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.pushScheduled = false
            self.store?.pendingRows { rows in
                guard let vault = self.vaultKey else { return }
                let sealed = rows.compactMap { try? vault.seal($0) }
                guard !sealed.isEmpty, let data = try? JSONEncoder().encode(sealed),
                      let json = String(data: data, encoding: .utf8) else { return }
                self.sendRaw("{\"t\":\"push\",\"rows\":\(json)}")
            }
        }
    }

    /// Personal uses the account key; every other vault its own random key from this Mac's keychain.
    private var vaultKey: Vault? {
        guard let t = store, let acct = account else { return nil }
        if t.vaultID.isEmpty { return acct.vault }
        return acct.user.flatMap { Secrets.vaultKey(user: $0, id: t.vaultID) }
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        sendRaw(s)
    }

    private func sendRaw(_ s: String) {
        task?.send(.string(s)) { _ in }
    }
}
