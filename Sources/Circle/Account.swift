import Foundation
import SwiftUI
import AuthenticationServices
import CircleCore

/// Sign in with Apple + the account key. The server knows who you are (your Apple user id)
/// but never sees your todos: they are sealed with a key that lives only in your keychain
/// (synced to your other Macs through iCloud Keychain) and in the recovery key you keep.
@MainActor @Observable
final class Account {
    enum State: Equatable {
        case signedOut
        case working(String)
        case needsKey            // signed in, but this Mac doesn't have the account key yet
        case showRecovery        // a new account key was just made: write the recovery key down
        case ready
    }

    private(set) var state: State = .signedOut
    private(set) var user: String?
    private(set) var email: String?
    private(set) var vault: Vault?
    private(set) var keyWhere: Secrets.Where?
    var error: String?

    @ObservationIgnored private(set) var session: String?
    @ObservationIgnored private weak var app: AppModel?

    static let defaultServer = "https://circle-sync.timwheeler.workers.dev"

    init(app: AppModel) {
        self.app = app
        let cfg = SyncConfig.load()
        user = cfg?.user
        email = cfg?.email
        if let u = user {
            session = Secrets.load(account: "session:" + u).flatMap { String(data: $0, encoding: .utf8) }
            vault = Secrets.vault(for: u)
        }
        if session == nil { state = .signedOut }
        else if vault == nil { state = .needsKey }
        else { state = .ready }
    }

    var serverURL: String { SyncConfig.load()?.url ?? Self.defaultServer }
    var isReady: Bool { state == .ready && session != nil && vault != nil }

    // MARK: sign in

    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private let presenter = SheetPresenter()

    /// Sign in with Apple through Apple's own secure web sheet (works for Developer ID apps,
    /// which can't carry the native Sign in with Apple entitlement).
    func startSignIn() {
        error = nil
        guard let url = URL(string: serverURL + "/auth/apple/start") else { return }
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "circle") { [weak self] callback, err in
            DispatchQueue.main.async { self?.finishWebSignIn(callback, err) }
        }
        s.presentationContextProvider = presenter
        s.prefersEphemeralWebBrowserSession = false
        webSession = s
        state = .working("waiting for Apple…")
        if !s.start() { state = .signedOut; error = "Couldn't open the Apple sign-in sheet." }
    }

    func cancelSignIn() {
        webSession?.cancel()
        webSession = nil
        if session == nil { state = .signedOut } else if vault == nil { state = .needsKey }
    }

    private func finishWebSignIn(_ callback: URL?, _ err: Error?) {
        webSession = nil
        if let err {
            state = .signedOut
            if (err as? ASWebAuthenticationSessionError)?.code != .canceledLogin { error = err.localizedDescription }
            return
        }
        guard let callback, let q = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            state = .signedOut; error = "Sign in didn't complete."; return
        }
        func v(_ k: String) -> String? { q.first { $0.name == k }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        if let e = v("error") { state = .signedOut; error = "Sign in failed: \(e)"; return }
        guard let s = v("session"), let u = v("user") else { state = .signedOut; error = "Sign in didn't complete."; return }
        user = u
        email = v("email") ?? email
        session = s
        Secrets.save(Data(s.utf8), account: "session:" + u, synced: false)
        saveConfig()
        Task { await setUpKey() }
    }

    func completeSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let e):
            if (e as? ASAuthorizationError)?.code == .canceled { return }
            error = "Sign in with Apple failed: \(e.localizedDescription)"
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                error = "Apple didn't return an identity token"; return
            }
            Task { await signIn(identityToken: token, email: cred.email) }
        }
    }

    private struct AuthReply: Decodable { let session: String; let user: String; let email: String? }

    func signIn(identityToken: String, email givenEmail: String?) async {
        error = nil
        state = .working("signing in…")
        do {
            var req = URLRequest(url: URL(string: serverURL + "/auth/apple")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["identityToken": identityToken])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw Problem(String(data: data, encoding: .utf8) ?? "server refused sign in")
            }
            let r = try JSONDecoder().decode(AuthReply.self, from: data)
            user = r.user
            email = givenEmail ?? r.email ?? email
            session = r.session
            Secrets.save(Data(r.session.utf8), account: "session:" + r.user, synced: false)
            saveConfig()
            await setUpKey()
        } catch {
            self.error = "\(error.localizedDescription)"
            state = .signedOut
        }
    }

    /// New account: make the key, publish its sealed check, show the recovery key.
    /// Existing account: use the key from iCloud Keychain, or ask for the recovery key.
    func setUpKey() async {
        guard let u = user else { return }
        state = .working("unlocking…")
        do {
            let check = try await getKeyCheck()
            if let check {
                if let v = Secrets.vault(for: u), v.verify(keyCheck: check) {
                    vault = v; keyWhere = nil
                    finish()
                } else {
                    state = .needsKey
                }
            } else {
                let v = Vault.generate()
                keyWhere = Secrets.store(v, for: u)
                try await putKeyCheck(try v.keyCheck())
                vault = v
                state = .showRecovery
            }
        } catch {
            self.error = "\(error.localizedDescription)"
            state = .needsKey
        }
    }

    /// Unlocks this Mac with the recovery key (or checks again for the iCloud Keychain copy).
    func unlock(recoveryKey: String?) async {
        guard let u = user else { return }
        error = nil
        do {
            guard let check = try await getKeyCheck() else { await setUpKey(); return }
            let candidate = recoveryKey.flatMap { Vault(recoveryKey: $0) } ?? Secrets.vault(for: u)
            guard let v = candidate else {
                error = recoveryKey == nil ? "No key from iCloud Keychain yet." : "That doesn't look like a recovery key."
                return
            }
            guard v.verify(keyCheck: check) else { error = "That key doesn't unlock this account."; return }
            keyWhere = Secrets.store(v, for: u)
            vault = v
            finish()
        } catch {
            self.error = "\(error.localizedDescription)"
        }
    }

    /// The recovery key has been written down: start syncing.
    func confirmRecoverySaved() { finish() }

    private func finish() {
        state = .ready
        app?.store.prepareForEncryptedSync()
        app?.sync.reload()
        Task { await wipeLegacyCopy() }
    }

    func signOut() {
        if let u = user { Secrets.delete(account: "session:" + u) }
        session = nil
        vault = nil
        user = nil
        email = nil
        state = .signedOut
        saveConfig()
        app?.sync.reload()
    }

    // MARK: server

    private struct Problem: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

    private func authed(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Data, Int) {
        guard let session else { throw Problem("not signed in") }
        var req = URLRequest(url: URL(string: serverURL + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, r) = try await URLSession.shared.data(for: req)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw Problem("session expired, sign in again") }
        return (d, code)
    }

    private func getKeyCheck() async throws -> String? {
        let (d, code) = try await authed("/api/keycheck")
        guard code == 200 else { throw Problem("server error \(code)") }
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["keycheck"] as? String
    }

    private func putKeyCheck(_ check: String) async throws {
        let (_, code) = try await authed("/api/keycheck", method: "PUT", body: ["keycheck": check])
        guard code == 200 else { throw Problem("couldn't save the key check (\(code))") }
    }

    /// The old unencrypted server copy (from before accounts) is deleted once this Mac
    /// has re-uploaded everything sealed.
    private func wipeLegacyCopy() async {
        guard var cfg = SyncConfig.load(), let legacy = cfg.token, !legacy.isEmpty else { return }
        var req = URLRequest(url: URL(string: serverURL + "/api/legacy/wipe")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(legacy)", forHTTPHeaderField: "Authorization")
        guard let (_, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return }
        cfg.token = nil
        cfg.save()
        app?.say("old unencrypted server copy deleted")
    }

    private func saveConfig() {
        var cfg = SyncConfig.load() ?? SyncConfig(url: Self.defaultServer)
        cfg.user = user
        cfg.email = email
        cfg.save()
    }
}

// MARK: sheet

struct AccountSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var recovery = ""
    @State private var revealed = false

    var body: some View {
        let acct: Account = app.account
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Sync").font(Theme.uiTitle)
                Spacer()
                Button { app.accountOpen = false } label: { Text("×").foregroundStyle(Theme.dim) }.buttonStyle(.plain)
            }
            switch acct.state {
            case .signedOut:
                Text("Sign in to sync your list across your Macs. Everything is encrypted on this Mac before it leaves; the server can't read your todos.")
                    .foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                Button { acct.startSignIn() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "applelogo")
                        Text("Sign in with Apple").fontWeight(.medium)
                    }
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                    .background(scheme == .dark ? Color.white : Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            case .working(let what):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(what).foregroundStyle(Theme.dim)
                    Spacer()
                    Button("Cancel") { acct.cancelSignIn() }
                }
            case .needsKey:
                Text("This account already has an encrypted list. Enter your recovery key, or wait a moment for iCloud Keychain to bring the key over from your other Mac.")
                    .foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                TextField("XXXX-XXXX-…", text: $recovery)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                    .padding(8).background(Theme.selection).clipShape(RoundedRectangle(cornerRadius: 5))
                    .onSubmit { Task { await acct.unlock(recoveryKey: recovery) } }
                HStack {
                    Button("Unlock") { Task { await acct.unlock(recoveryKey: recovery) } }.disabled(recovery.isEmpty)
                    Button("Check iCloud Keychain again") { Task { await acct.unlock(recoveryKey: nil) } }
                    Spacer()
                    Button("Sign out") { acct.signOut() }.buttonStyle(.plain).foregroundStyle(Theme.dim)
                }
            case .showRecovery:
                Text("Your recovery key").fontWeight(.semibold)
                Text("Keep it somewhere safe, like 1Password. It's the only way to unlock your list if you lose access to all your Macs. Circle can't recover it for you.")
                    .foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                recoveryBox(acct.vault?.recoveryKey ?? "")
                if acct.keyWhere == .thisMac {
                    Text("The key is saved on this Mac only (iCloud Keychain isn't available to this build), so use the recovery key on your other Macs.")
                        .font(Theme.uiSmall).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
                HStack { Spacer(); Button("I've saved it") { acct.confirmRecoverySaved() }.keyboardShortcut(.defaultAction) }
            case .ready:
                Text("Signed in\(acct.email.map { " as \($0)" } ?? "") · end-to-end encrypted")
                    .foregroundStyle(Theme.body)
                Text("Status: \(app.store.syncState.label)").font(Theme.uiSmall).foregroundStyle(Theme.dim)
                if revealed { recoveryBox(acct.vault?.recoveryKey ?? "") }
                HStack {
                    Button(revealed ? "Hide recovery key" : "Show recovery key") { revealed.toggle() }
                    Spacer()
                    Button("Sign out") { acct.signOut() }.buttonStyle(.plain).foregroundStyle(Theme.dim)
                }
            }
            if let e = acct.error {
                Text(e).font(Theme.uiSmall).foregroundStyle(.red.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.ui)
        .padding(22)
        .frame(width: 440)
        .background(Theme.bg)
    }

    private func recoveryBox(_ key: String) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
                app.say("recovery key copied")
            }
        }
        .padding(10)
        .background(Theme.selection)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}


/// Where the Apple sign-in sheet attaches: Circle's main window.
final class SheetPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { AppModel.shared.mainWindow ?? NSApp.keyWindow ?? NSWindow() }
    }
}
