import Foundation
import AppKit
import Observation
import CircleCore

/// ~/Library/Application Support/Circle/settings.json, Zed style:
/// hand-editable, reloads live on save, and the app writes back what you change in it.
@MainActor @Observable
final class Settings {
    static let shared = Settings()

    var fontSize: Double = 13.5 { didSet { changed() } }
    var agent: String = "claude" { didSet { changed() } }
    var model: String = "sonnet" { didSet { changed() } }
    var autonomy: String = "edits" { didSet { changed() } }
    var workingDirectory: String = "~" { didSet { changed() } }
    var hideCompleted = false { didSet { changed() } }
    /// "next_day": completed items move to the logbook after today. "never": they stay in the list.
    var logbook: String = "next_day" { didSet { changed() } }
    /// "auto" (side by side when there is room), "side", or "overlay".
    var panel: String = "auto" { didSet { changed() } }
    /// Inline hints such as "r → claude" and the input's @agent tip.
    var hints = true { didSet { changed() } }
    var customModels: [String: [String]] = [:] { didSet { changed() } }

    var error: String?
    @ObservationIgnored var onReload: (() -> Void)?

    @ObservationIgnored private var loading = false
    @ObservationIgnored private var lastWritten: Data?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    static var file: URL { Paths.support.appendingPathComponent("settings.json") }

    var workingDirectoryPath: String {
        (workingDirectory as NSString).expandingTildeInPath
    }

    private init() {
        if FileManager.default.fileExists(atPath: Self.file.path) {
            load()
        } else {
            migrateFromDefaults()
            writeNow()
        }
        watch()
    }

    // MARK: file

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: Self.stripComments(data))) as? [String: Any] else {
            error = "settings.json is not valid JSON"
            return
        }
        error = nil
        loading = true
        defer { loading = false }
        if let v = obj["font_size"] as? Double { fontSize = min(max(v, 9), 28) }
        if let v = obj["agent"] as? String { agent = v }
        if let v = obj["model"] as? String { model = v }
        if let v = obj["autonomy"] as? String, Autonomy(rawValue: v) != nil { autonomy = v }
        if let v = obj["working_directory"] as? String { workingDirectory = v }
        if let v = obj["hide_completed"] as? Bool { hideCompleted = v }
        if let v = obj["logbook"] as? String, ["next_day", "never"].contains(v) { logbook = v }
        if let v = obj["panel"] as? String, ["auto", "side", "overlay"].contains(v) { panel = v }
        if let v = obj["hints"] as? Bool { hints = v }
        if let v = obj["custom_models"] as? [String: [String]] { customModels = v }
    }

    private var json: [String: Any] {
        [
            "font_size": fontSize,
            "agent": agent,
            "model": model,
            "autonomy": autonomy,
            "working_directory": workingDirectory,
            "hide_completed": hideCompleted,
            "logbook": logbook,
            "panel": panel,
            "hints": hints,
            "custom_models": customModels,
        ]
    }

    private func changed() {
        guard !loading else { return }
        // Coalesce bursts (e.g. agent + model chosen together) into one write.
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.writeNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    private func writeNow() {
        guard let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        lastWritten = d
        try? d.write(to: Self.file, options: .atomic)
    }

    func open() {
        writeNowIfMissing()
        NSWorkspace.shared.open(Self.file)
    }

    private func writeNowIfMissing() {
        if !FileManager.default.fileExists(atPath: Self.file.path) { writeNow() }
    }

    /// Allows // line comments so the file can be annotated by hand.
    private static func stripComments(_ d: Data) -> Data {
        guard let s = String(data: d, encoding: .utf8), s.contains("//") else { return d }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var inString = false, prev: Character = " "
            for (i, c) in line.enumerated() {
                if c == "\"" && prev != "\\" { inString.toggle() }
                if !inString && c == "/" && prev == "/" { return line.prefix(i - 1) }
                prev = c
            }
            return line
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? d
    }

    // MARK: live reload

    private func watch() {
        watcher?.cancel()
        let fd = Darwin.open(Self.file.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.watch() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let events = src.data
            // Editors save by replacing the file: re-attach to the new one.
            if events.contains(.delete) || events.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reloadFromDisk(); self.watch() }
            } else {
                self.reloadFromDisk()
            }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watcher = src
    }

    private func reloadFromDisk() {
        guard let d = try? Data(contentsOf: Self.file), d != lastWritten else { return }
        load()
        onReload?()
    }

    private func migrateFromDefaults() {
        let u = UserDefaults.standard
        loading = true
        defer { loading = false }
        if let v = u.string(forKey: "agent") { agent = v }
        if let v = u.string(forKey: "model") { model = v }
        if let v = u.string(forKey: "autonomy") { autonomy = v }
        if let v = u.string(forKey: "cwd") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            workingDirectory = v.hasPrefix(home) ? "~" + v.dropFirst(home.count) : v
        }
        hideCompleted = u.bool(forKey: "hideDone")
        if let v = u.dictionary(forKey: "customModels") as? [String: [String]] { customModels = v }
    }
}
