import Foundation
import CircleCore

/// The list of vaults, synced (encrypted) like any list: each vault is a row whose title is its name.
/// Personal ("") is built in and always first.
@MainActor @Observable
final class VaultIndex {
    struct Info: Identifiable, Equatable { let id: String; var name: String }

    private(set) var vaults: [Info] = [Info(id: "", name: "Personal")]
    var syncState: SyncState = .local

    @ObservationIgnored private let repo: TodoRepo?
    @ObservationIgnored private let q = DispatchQueue(label: "circle.vaults", qos: .userInitiated)
    @ObservationIgnored private var rows: [String: Todo] = [:]
    @ObservationIgnored private let device: String
    @ObservationIgnored var onLocalChange: (() -> Void)?

    init(device: String) {
        self.device = device
        repo = try? TodoRepo(vault: Vaults.index)
        for t in (try? repo?.all()) ?? [] { rows[t.id] = t }
        rebuild()
    }

    func name(_ id: String) -> String { vaults.first { $0.id == id }?.name ?? "Personal" }

    private func rebuild() {
        let named = rows.values.filter { !$0.deleted && Vaults.isValidID($0.id) && !$0.id.isEmpty }
            .sorted { $0.sort != $1.sort ? $0.sort < $1.sort : $0.createdAt < $1.createdAt }
            .map { Info(id: $0.id, name: $0.title) }
        vaults = [Info(id: "", name: "Personal")] + named
    }

    private func commit(_ t: Todo) {
        let t = t.touched(by: device)
        rows[t.id] = t
        rebuild()
        guard let repo else { return }
        q.async { [weak self] in
            try? repo.saveLocal([t])
            DispatchQueue.main.async { self?.onLocalChange?() }
        }
    }

    @discardableResult
    func create(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let sort = (rows.values.map(\.sort).max() ?? 0) + 1
        let t = Todo(id: Vaults.newID(), title: name, sort: sort, origin: device)
        commit(t)
        return t.id
    }

    func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !name.isEmpty, var t = rows[id] else { return }
        t.title = name
        commit(t)
    }

    /// Removes the vault from every device's list. Its items stay in its own database and sync room.
    func remove(_ id: String) {
        guard !id.isEmpty, var t = rows[id] else { return }
        t.deleted = true
        commit(t)
    }
}

extension VaultIndex: SyncTarget {
    var vaultID: String { Vaults.index }
    func setSyncState(_ s: SyncState) { syncState = s }

    func pendingRows(_ done: @escaping ([Todo]) -> Void) {
        guard let repo else { return done([]) }
        q.async { let r = (try? repo.dirty()) ?? []; DispatchQueue.main.async { done(r) } }
    }

    func cursor(_ done: @escaping (Int64) -> Void) {
        guard let repo else { return done(0) }
        q.async { let c = Int64((try? repo.meta("cursor")) ?? "0") ?? 0; DispatchQueue.main.async { done(c) } }
    }

    func applyRemote(_ incoming: [Todo], cursor: Int64?) {
        guard let repo else { return }
        q.async { [weak self] in
            let applied = (try? repo.applyRemote(incoming)) ?? []
            if let c = cursor, c > (Int64((try? repo.meta("cursor")) ?? "0") ?? 0) { try? repo.setMeta("cursor", String(c)) }
            DispatchQueue.main.async {
                guard let self, !applied.isEmpty else { return }
                for t in applied { self.rows[t.id] = t }
                self.rebuild()
            }
        }
    }
}
