import Foundation
import Sparkle

/// Sparkle auto-updates. Checks the appcast on GitHub daily; updates are signed with the EdDSA key
/// in the release Mac's keychain (public half in Info.plist), on top of Apple notarization.
@MainActor
final class Updater {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    /// Only runs from a built Circle.app that carries the public key (not from `swift run`).
    var available: Bool { controller != nil }

    func start() {
        guard controller == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty
        else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func check() {
        if let controller { controller.checkForUpdates(nil) } else { start(); controller?.checkForUpdates(nil) }
    }
}
