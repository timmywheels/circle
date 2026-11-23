import Foundation
import CryptoKit
import Security

/// End-to-end encryption for sync. Everything about a todo (title, notes, shape, nesting,
/// reminders, order) is sealed on this device with the account key before it leaves.
/// The server only sees what it needs to merge: id, updated_at, origin, deleted, and an
/// opaque blob. The todo's id is bound into the seal, so a blob can't be moved to another row.
public struct Vault: Sendable {
    public let key: SymmetricKey

    public init(key: SymmetricKey) { self.key = key }

    /// The key for one vault, derived from the account key so the one recovery key unlocks them all.
    /// "" (Personal) is the account key itself. HKDF-SHA256, salt "circle", info "circle-vault:<id>".
    public func forVault(_ id: String) -> Vault {
        guard !id.isEmpty else { return self }
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data("circle".utf8),
                                       info: Data(("circle-vault:" + id).utf8), outputByteCount: 32)
        return Vault(key: k)
    }
    public static func generate() -> Vault { Vault(key: SymmetricKey(size: .bits256)) }

    /// What is encrypted: every field except the merge metadata.
    private struct Payload: Codable {
        var kind: Kind
        var parent: String
        var title: String
        var notes: String
        var done: Bool
        var doneAt: Int64
        var remindAt: Int64
        var repeatRule: String
        var sort: Double
        var createdAt: Int64
    }

    public func seal(_ t: Todo) throws -> SealedRow {
        let p = Payload(kind: t.kind, parent: t.parent, title: t.title, notes: t.notes, done: t.done, doneAt: t.doneAt,
                        remindAt: t.remindAt, repeatRule: t.repeatRule, sort: t.sort, createdAt: t.createdAt)
        let box = try ChaChaPoly.seal(try JSONEncoder().encode(p), using: key, authenticating: Data(t.id.utf8))
        return SealedRow(id: t.id, updated_at: t.updatedAt, origin: t.origin, deleted: t.deleted,
                         blob: box.combined.base64EncodedString())
    }

    public func open(_ r: SealedRow) throws -> Todo {
        guard let data = Data(base64Encoded: r.blob) else { throw VaultError.corrupt }
        let box = try ChaChaPoly.SealedBox(combined: data)
        let plain = try ChaChaPoly.open(box, using: key, authenticating: Data(r.id.utf8))
        let p = try JSONDecoder().decode(Payload.self, from: plain)
        return Todo(id: r.id, kind: p.kind, parent: p.parent, title: p.title, notes: p.notes, done: p.done, sort: p.sort,
                    createdAt: p.createdAt, updatedAt: r.updated_at, deleted: r.deleted, origin: r.origin,
                    doneAt: p.doneAt, remindAt: p.remindAt, repeatRule: p.repeatRule)
    }

    /// A small sealed constant stored on the server, so a device can tell whether the key it
    /// holds is the account's key before it syncs anything.
    private static let checkText = Data("circle-key-check-v1".utf8)
    private static let checkAAD = Data("circle-key-check".utf8)

    public func keyCheck() throws -> String {
        try ChaChaPoly.seal(Self.checkText, using: key, authenticating: Self.checkAAD).combined.base64EncodedString()
    }

    public func verify(keyCheck blob: String) -> Bool {
        guard let d = Data(base64Encoded: blob), let box = try? ChaChaPoly.SealedBox(combined: d),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: Self.checkAAD) else { return false }
        return plain == Self.checkText
    }

    // MARK: recovery key

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")   // Crockford base32

    /// The key written for a person to keep: 52 characters in groups of 4, e.g. "7Q2M-…".
    public var recoveryKey: String {
        let bytes = key.withUnsafeBytes { Array($0) }
        var bits = 0, value = 0
        var out: [Character] = []
        for b in bytes {
            value = (value << 8) | Int(b); bits += 8
            while bits >= 5 { out.append(Self.alphabet[(value >> (bits - 5)) & 31]); bits -= 5 }
            value &= (1 << bits) - 1
        }
        if bits > 0 { out.append(Self.alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map { String(out[$0..<min($0 + 4, out.count)]) }.joined(separator: "-")
    }

    /// Reads a recovery key back (case, dashes, spaces and look-alike letters forgiven).
    public init?(recoveryKey s: String) {
        let map: [Character: Character] = ["O": "0", "I": "1", "L": "1", "U": "V"]
        let chars = s.uppercased().compactMap { c -> Character? in
            if c == "-" || c == " " || c == "\n" { return nil }
            return map[c] ?? c
        }
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for c in chars {
            guard let i = Self.alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | i; bits += 5
            if bits >= 8 { bytes.append(UInt8((value >> (bits - 8)) & 0xFF)); bits -= 8 }
            value &= (1 << bits) - 1
        }
        guard bytes.count == 32 else { return nil }
        self.key = SymmetricKey(data: bytes)
    }
}

/// A todo as it travels to and from the server: merge metadata in the clear, the rest sealed.
public struct SealedRow: Codable, Sendable, Equatable {
    public var id: String
    public var updated_at: Int64
    public var origin: String
    public var deleted: Bool
    public var blob: String
    public init(id: String, updated_at: Int64, origin: String, deleted: Bool, blob: String) {
        self.id = id; self.updated_at = updated_at; self.origin = origin; self.deleted = deleted; self.blob = blob
    }
}

public enum VaultError: Error { case corrupt }

/// A vault code carries one vault's id and its key: "CV1-<id>-<key in recovery-key form>".
/// Pasting it on a device opens that vault there and nothing else.
public enum VaultCode {
    public static func make(id: String, vault: Vault) -> String { "CV1-" + id + "-" + vault.recoveryKey }

    public static func parse(_ s: String) -> (id: String, vault: Vault)? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.uppercased().hasPrefix("CV1-") else { return nil }
        t = String(t.dropFirst(4))
        guard let dash = t.firstIndex(of: "-") else { return nil }
        let id = String(t[..<dash]).lowercased()
        guard !id.isEmpty, id != Vaults.index, Vaults.isValidID(id),
              let v = Vault(recoveryKey: String(t[t.index(after: dash)...])) else { return nil }
        return (id, v)
    }
}

/// Secrets in the keychain. The account key is synchronizable (iCloud Keychain), so a new Mac
/// signed in to the same Apple ID receives it; the session token stays on this device.
public enum Secrets {
    public enum Where: Sendable { case iCloud, thisMac }

    private static let service = "com.timwheeler.circle"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Saves; synced tries iCloud Keychain first (needs the app's keychain entitlement) and falls back to this Mac.
    @discardableResult
    public static func save(_ data: Data, account: String, synced: Bool) -> Where? {
        delete(account: account)
        if synced {
            var q = base(account)
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrSynchronizable as String] = true
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            q[kSecValueData as String] = data
            if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { return .iCloud }
        }
        var q = base(account)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        q[kSecValueData as String] = data
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess ? .thisMac : nil
    }

    public static func load(account: String) -> Data? {
        for useDP in [true, false] {
            var q = base(account)
            if useDP {
                q[kSecUseDataProtectionKeychain as String] = true
                q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            }
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        }
        return nil
    }

    public static func delete(account: String) {
        var q = base(account)
        q[kSecUseDataProtectionKeychain as String] = true
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(q as CFDictionary)
        SecItemDelete(base(account) as CFDictionary)
    }

    /// One vault's own key: this device only (never iCloud Keychain), so separation holds per device.
    public static func vaultKey(user: String, id: String) -> Vault? {
        load(account: "vaultkey:\(user):\(id)").map { Vault(key: SymmetricKey(data: $0)) }
    }

    public static func storeVaultKey(_ v: Vault, user: String, id: String) {
        save(v.key.withUnsafeBytes { Data($0) }, account: "vaultkey:\(user):\(id)", synced: false)
    }

    public static func deleteVaultKey(user: String, id: String) { delete(account: "vaultkey:\(user):\(id)") }

    public static func vault(for user: String) -> Vault? {
        load(account: "vault:" + user).map { Vault(key: SymmetricKey(data: $0)) }
    }

    @discardableResult
    public static func store(_ v: Vault, for user: String) -> Where? {
        save(v.key.withUnsafeBytes { Data($0) }, account: "vault:" + user, synced: true)
    }
}
