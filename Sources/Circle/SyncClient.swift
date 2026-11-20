import Foundation
import CircleCore

/// WebSocket sync with the Cloudflare Durable Object.
/// Protocol (JSON text frames):
///   -> {"t":"hello","since":N}      -> {"t":"push","rows":[...]}
///   <- {"t":"rows","rows":[...],"cursor":N}
@MainActor
final class SyncClient: NSObject, URLSessionWebSocketDelegate {
    private weak var store: Store?
    private var config: SyncConfig?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var open = false
    private var backoff: TimeInterval = 0.5
    private var pushScheduled = false
    private var pingTimer: Timer?

    init(store: Store) {
        self.store = store
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        store.onLocalChange = { [weak self] in self?.schedulePush() }
    }

    func start() {
        config = SyncConfig.load()
        guard config?.socketURL != nil else { store?.syncState = .local; return }
        connect()
    }

    /// Re-read sync.json (after running deploy) and reconnect.
    func reload() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil; open = false
        start()
    }

    private func connect() {
        guard let cfg = config, let url = cfg.socketURL else { return }
        store?.syncState = .connecting
        var req = URLRequest(url: url)
        req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
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
            store?.syncState = .synced
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
        store?.syncState = .offline
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
        let rows: [Todo]?
        let cursor: Int64?
    }

    private func handle(_ text: String) {
        guard let d = text.data(using: .utf8),
              let m = try? JSONDecoder().decode(Incoming.self, from: d) else { return }
        if m.t == "rows" { store?.applyRemote(m.rows ?? [], cursor: m.cursor) }
    }

    private func schedulePush() {
        guard open, !pushScheduled else { return }
        pushScheduled = true
        // Coalesce bursts (typing, multi-edits) into one frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.pushScheduled = false
            self.store?.pendingRows { rows in
                guard !rows.isEmpty, let data = try? JSONEncoder().encode(rows),
                      let json = String(data: data, encoding: .utf8) else { return }
                self.sendRaw("{\"t\":\"push\",\"rows\":\(json)}")
            }
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        sendRaw(s)
    }

    private func sendRaw(_ s: String) {
        task?.send(.string(s)) { _ in }
    }
}
