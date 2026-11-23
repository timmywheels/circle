import Foundation
import CryptoKit
import CircleCore

/// Your account's vaults, like Obsidian Sync: the server keeps the directory (ids and names, which it
/// can see), and every vault's contents are sealed with that vault's own random key. A device opens a
/// vault only once it holds the key (pasted as the vault code), so a work Mac holding Work's code can't
/// read Personal or any other vault. Personal unlocks with the account recovery key.
@MainActor @Observable
final class VaultIndex {
    struct Info: Identifiable, Equatable, Codable {
        let id: String
        var name: String
        var unlocked = false
    }

    private(set) var vaults: [Info] = []
    var unlocked: [Info] { vaults.filter(\.unlocked) }
    var error: String?

    @ObservationIgnored private weak var account: Account?
    @ObservationIgnored private var directory: [Info] = []      // from the server (cached)

    private var cacheKey: String { "vault-directory:" + (account?.user ?? "") }

    func attach(_ account: Account) { self.account = account }

    /// Rebuilds from the cached directory and this Mac's keychain, then refreshes from the server.
    func reload() {
        directory = UserDefaults.standard.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode([Info].self, from: $0) } ?? []
        publish()
        Task { await refresh() }
    }

    private func publish() {
        guard let acct = account, let user = acct.user else { vaults = [Info(id: "", name: "Personal", unlocked: true)]; return }
        let personal = Info(id: "", name: "Personal", unlocked: acct.vault != nil)
        vaults = [personal] + directory.map { var v = $0; v.unlocked = Secrets.vaultKey(user: user, id: v.id) != nil; return v }
    }

    func name(_ id: String) -> String { vaults.first { $0.id == id }?.name ?? (id.isEmpty ? "Personal" : "Vault") }
    func isUnlocked(_ id: String) -> Bool { vaults.first { $0.id == id }?.unlocked ?? false }

    // MARK: server

    private struct Problem: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

    private func saveCache() { UserDefaults.standard.set(try? JSONEncoder().encode(directory), forKey: cacheKey) }

    func refresh() async {
        guard let acct = account, acct.session != nil else { return }
        do {
            let (d, code) = try await acct.authed("/api/vaults")
            guard code == 200 else { return }
            struct Row: Decodable { let id: String; let name: String }
            struct Reply: Decodable { let vaults: [Row] }
            let rows = try JSONDecoder().decode(Reply.self, from: d).vaults
            directory = rows.filter { Vaults.isValidID($0.id) && !$0.id.isEmpty }.map { Info(id: $0.id, name: $0.name) }
            await adoptLegacy()
            saveCache()
            publish()
        } catch { self.error = error.localizedDescription }
    }

    /// A brand-new vault: random key (kept on this Mac), listed in the account's directory.
    /// Returns its id and code; show the code once so it can be saved.
    func create(_ name: String) async throws -> (id: String, code: String) {
        guard let acct = account, let user = acct.user else { throw Problem("Sign in first.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Vaults.newID()
        let v = Vault.generate()
        let (_, c1) = try await acct.authed("/api/vaults", method: "POST", body: ["id": id, "name": name])
        guard c1 == 200 else { throw Problem("Couldn't create the vault (\(c1)).") }
        let (_, c2) = try await acct.authed("/api/keycheck?vault=" + id, method: "PUT", body: ["keycheck": try v.keyCheck()])
        guard c2 == 200 else { throw Problem("Couldn't save the vault's key check (\(c2)).") }
        Secrets.storeVaultKey(v, user: user, id: id)
        directory.append(Info(id: id, name: name))
        saveCache()
        publish()
        return (id, VaultCode.make(id: id, vault: v))
    }

    /// Unlocks a vault on this Mac with its code, after checking it against the vault's key check.
    @discardableResult
    func unlock(code: String, expecting id: String? = nil) async throws -> String {
        guard let acct = account, let user = acct.user else { throw Problem("Sign in first.") }
        guard let (cid, v) = VaultCode.parse(code) else { throw Problem("That doesn't look like a vault code (it starts with CV1-).") }
        if let id, id != cid { throw Problem("That code is for a different vault.") }
        let (d, status) = try await acct.authed("/api/keycheck?vault=" + cid)
        guard status == 200 else { throw Problem("Server error \(status).") }
        let check = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["keycheck"] as? String
        guard let check else { throw Problem("No vault with that code on this account.") }
        guard v.verify(keyCheck: check) else { throw Problem("That code doesn't unlock this vault.") }
        Secrets.storeVaultKey(v, user: user, id: cid)
        if !directory.contains(where: { $0.id == cid }) { await refresh() }
        publish()
        return cid
    }

    func rename(_ id: String, to name: String) async {
        guard let acct = account, !id.isEmpty else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let (_, code) = try? await acct.authed("/api/vaults/" + id, method: "PATCH", body: ["name": name]),
              code == 200 else { return }
        if let i = directory.firstIndex(where: { $0.id == id }) { directory[i].name = name }
        saveCache()
        publish()
    }

    /// Removes the vault from the account's directory (every device). Its sealed contents stay on the server.
    func delete(_ id: String) async {
        guard let acct = account, !id.isEmpty else { return }
        _ = try? await acct.authed("/api/vaults/" + id, method: "DELETE")
        lock(id)
        directory.removeAll { $0.id == id }
        saveCache()
        publish()
    }

    /// Locks the vault on this Mac only: its key and local copy go away; other devices keep it.
    func lock(_ id: String) {
        guard let user = account?.user, !id.isEmpty else { return }
        Secrets.deleteVaultKey(user: user, id: id)
        let db = Paths.database(vault: id).path
        for f in [db, db + "-wal", db + "-shm"] { try? FileManager.default.removeItem(atPath: f) }
        publish()
    }

    func code(_ id: String) -> String? {
        guard let user = account?.user, let v = Secrets.vaultKey(user: user, id: id) else { return nil }
        return VaultCode.make(id: id, vault: v)
    }

    /// Vaults made earlier today (key derived from the account key, listed in a synced index) move into
    /// the directory once, keeping their key so they keep working.
    private func adoptLegacy() async {
        guard let acct = account, let user = acct.user, let accountKey = acct.vault,
              let repo = try? TodoRepo(vault: Vaults.index) else { return }
        for t in (try? repo.all()) ?? [] where !t.deleted && Vaults.isValidID(t.id) && !t.id.isEmpty {
            guard !directory.contains(where: { $0.id == t.id }) else { continue }
            let v = accountKey.forVault(t.id)
            guard let (_, c) = try? await acct.authed("/api/vaults", method: "POST", body: ["id": t.id, "name": t.title]),
                  c == 200 || c == 409 else { continue }
            if let check = try? v.keyCheck() {
                _ = try? await acct.authed("/api/keycheck?vault=" + t.id, method: "PUT", body: ["keycheck": check])
            }
            if Secrets.vaultKey(user: user, id: t.id) == nil { Secrets.storeVaultKey(v, user: user, id: t.id) }
            directory.append(Info(id: t.id, name: t.title))
        }
    }
}
