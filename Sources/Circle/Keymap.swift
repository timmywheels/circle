import SwiftUI
import AppKit
import Carbon.HIToolbox
import CircleCore

/// Every keyboard command in the list. One table drives the key handler,
/// the ⌘K palette, the ? overlay and keymap.json.
enum Action: String, CaseIterable, Identifiable {
    case down, up, top, bottom
    case moveDown = "move_down", moveUp = "move_up"
    case indent, outdent, collapse, expand
    case toggle, edit, delete, undo
    case addTop = "add_top", addBelow = "add_below", newSection = "new_section"
    case run, cancel
    case details, notes, remind
    case shapeMine = "shape_mine", shapeAgent = "shape_agent", shapeWaiting = "shape_waiting", cycleShape = "cycle_shape"
    case filterMine = "filter_mine", filterAgent = "filter_agent", filterWaiting = "filter_waiting", filterAll = "filter_all"
    case followLink = "follow_link", back
    case hideDone = "hide_done", logbook
    case palette, help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .down: return "select next"
        case .up: return "select previous"
        case .top: return "select first"
        case .bottom: return "select last"
        case .moveDown: return "move down"
        case .moveUp: return "move up"
        case .indent: return "nest under item above"
        case .outdent: return "un-nest"
        case .collapse: return "collapse / go to parent"
        case .expand: return "expand / go to first child"
        case .toggle: return "fill in (done)"
        case .edit: return "edit title"
        case .delete: return "delete"
        case .undo: return "undo"
        case .addTop: return "add at top"
        case .addBelow: return "add below selection"
        case .newSection: return "new section"
        case .run: return "hand to agent △"
        case .cancel: return "cancel agent run"
        case .details: return "open details (again: notes)"
        case .remind: return "set reminder"
        case .notes: return "edit notes"
        case .shapeMine: return "shape ○ mine"
        case .shapeAgent: return "shape △ agent (runs it)"
        case .shapeWaiting: return "shape □ waiting"
        case .cycleShape: return "cycle shape"
        case .filterMine: return "show only ○"
        case .filterAgent: return "show only △"
        case .filterWaiting: return "show only □"
        case .filterAll: return "show all"
        case .followLink: return "follow [[link]]"
        case .back: return "back"
        case .hideDone: return "hide / show completed"
        case .logbook: return "logbook"
        case .palette: return "command palette"
        case .help: return "keyboard shortcuts"
        }
    }

    static let defaults: [Action: [String]] = [
        .down: ["j", "down"], .up: ["k", "up"], .top: ["g", "home"], .bottom: ["shift+g", "end"],
        .moveDown: ["shift+j", "alt+down"], .moveUp: ["shift+k", "alt+up"],
        .indent: ["tab"], .outdent: ["shift+tab"], .collapse: ["h", "left"], .expand: ["l", "right"],
        .toggle: ["space", "x"], .edit: ["e"], .delete: ["d", "backspace", "delete"], .undo: ["u", "cmd+z"],
        .addTop: ["a", "n", "/"], .addBelow: ["o"], .newSection: ["shift+s"],
        .run: ["r", "2", "cmd+enter"], .cancel: ["c"],
        .details: ["enter", "p", "cmd+j"], .notes: ["shift+n"], .remind: ["m"],
        .shapeMine: ["1"], .shapeAgent: [], .shapeWaiting: ["3"], .cycleShape: ["t"],
        .filterMine: ["alt+1"], .filterAgent: ["alt+2"], .filterWaiting: ["alt+3"], .filterAll: ["alt+0", "0"],
        .followLink: ["f"], .back: ["cmd+["],
        .hideDone: ["shift+h"], .logbook: ["shift+l"],
        .palette: ["cmd+k"], .help: ["?", "cmd+/"],
    ]
}

/// A key plus modifiers, normalised: "cmd+shift+k", "space", "alt+down".
struct Chord: Hashable {
    let key: String
    let mods: Set<String>

    static let modOrder = ["ctrl", "alt", "shift", "cmd"]

    init(key: String, mods: Set<String>) { self.key = key; self.mods = mods }

    /// Parses "shift+j", "J" (same thing), "cmd+enter", "?".
    init?(_ s: String) {
        let raw = s.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        var parts = raw == "+" ? ["+"] : raw.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if raw.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        var key = parts.removeLast().lowercased()
        var mods = Set<String>()
        for p in parts {
            switch p.lowercased() {
            case "cmd", "command", "super": mods.insert("cmd")
            case "alt", "opt", "option": mods.insert("alt")
            case "ctrl", "control": mods.insert("ctrl")
            case "shift": mods.insert("shift")
            default: return nil
            }
        }
        let original = raw.split(separator: "+").last.map(String.init) ?? raw
        if original.count == 1, let c = original.first, c.isLetter, c.isUppercase { mods.insert("shift") }
        if key == "return" { key = "enter" }
        if key == "esc" { key = "escape" }
        self.key = key
        self.mods = mods
    }

    var label: String {
        let sym: [String: String] = ["cmd": "⌘", "alt": "⌥", "shift": "⇧", "ctrl": "⌃"]
        let keySym: [String: String] = ["enter": "↩", "space": "space", "tab": "tab", "backspace": "⌫", "delete": "⌦",
                                        "escape": "esc", "up": "↑", "down": "↓", "left": "←", "right": "→",
                                        "home": "home", "end": "end"]
        let m = Self.modOrder.filter(mods.contains).map { sym[$0]! }.joined()
        return m + (keySym[key] ?? key)
    }

    /// Candidate chords for a key press (shifted symbols like "?" match with or without shift).
    static func from(_ k: KeyPress) -> [Chord] {
        var mods = Set<String>()
        if k.modifiers.contains(.command) { mods.insert("cmd") }
        if k.modifiers.contains(.option) { mods.insert("alt") }
        if k.modifiers.contains(.control) { mods.insert("ctrl") }
        if k.modifiers.contains(.shift) { mods.insert("shift") }
        let named: [KeyEquivalent: String] = [.upArrow: "up", .downArrow: "down", .leftArrow: "left", .rightArrow: "right",
                                             .return: "enter", .space: "space", .tab: "tab", .delete: "backspace",
                                             .deleteForward: "delete", .escape: "escape", .home: "home", .end: "end"]
        if k.key == KeyEquivalent("\u{19}") { return [Chord(key: "tab", mods: mods.union(["shift"]))] } // backtab
        if let n = named[k.key] { return [Chord(key: n, mods: mods)] }
        var out: [Chord] = []
        // Base key without Option-produced symbols (⌥1 types "¡").
        var base = String(k.key.character).lowercased()
        let optionSymbols: [String: String] = ["¡": "1", "™": "2", "£": "3", "¢": "4", "∞": "5", "§": "6",
                                               "¶": "7", "•": "8", "ª": "9", "º": "0", "“": "[", "‘": "]"]
        if mods.contains("alt"), let b = optionSymbols[base] { base = b }
        out.append(Chord(key: base, mods: mods))
        let typed = k.characters.lowercased()
        if !typed.isEmpty && typed != base {
            var m = mods; m.remove("shift"); m.remove("alt")
            out.append(Chord(key: typed, mods: m))
        }
        if mods.contains("shift"), !k.characters.isEmpty, k.characters != k.characters.lowercased() || !(k.characters.first?.isLetter ?? true) {
            var m = mods; m.remove("shift")
            out.append(Chord(key: k.characters, mods: m))    // "?" bound without shift
        }
        return out
    }
}

/// Loads defaults, applies ~/Library/Application Support/Circle/keymap.json on top.
@MainActor @Observable
final class Keymap {
    private(set) var bindings: [Action: [Chord]] = [:]
    @ObservationIgnored private var lookup: [Chord: Action] = [:]
    private(set) var globalHotkey = "ctrl+alt+space"
    var error: String?

    static var file: URL { Paths.support.appendingPathComponent("keymap.json") }

    init() { reload() }

    func reload() {
        var map: [Action: [String]] = Action.defaults
        error = nil
        if let data = try? Data(contentsOf: Self.file) {
            do {
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                if let b = obj["bindings"] as? [String: Any] {
                    for (name, v) in b {
                        guard let a = Action(rawValue: name) else { error = "unknown action \"\(name)\""; continue }
                        if let one = v as? String { map[a] = [one] } else if let many = v as? [String] { map[a] = many }
                    }
                }
                if let g = obj["global"] as? String { globalHotkey = g }
            } catch { self.error = "keymap.json: \(error.localizedDescription)" }
        }
        var b: [Action: [Chord]] = [:], l: [Chord: Action] = [:]
        for a in Action.allCases {
            let chords = (map[a] ?? []).compactMap(Chord.init)
            b[a] = chords
            for c in chords where l[c] == nil { l[c] = a }
        }
        bindings = b
        lookup = l
    }

    func action(for k: KeyPress) -> Action? {
        for c in Chord.from(k) { if let a = lookup[c] { return a } }
        return nil
    }

    func label(_ a: Action) -> String { (bindings[a] ?? []).prefix(2).map(\.label).joined(separator: "  ") }

    /// Writes the current bindings to keymap.json (if missing) and opens it.
    func openFile() {
        if !FileManager.default.fileExists(atPath: Self.file.path) {
            var b: [String: [String]] = [:]
            for a in Action.allCases { b[a.rawValue] = Action.defaults[a] ?? [] }
            let obj: [String: Any] = ["global": globalHotkey, "bindings": b]
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: Self.file)
            }
        }
        NSWorkspace.shared.open(Self.file)
    }

    /// Carbon key code + modifiers for the global summon chord.
    var carbonHotkey: (code: UInt32, mods: UInt32)? {
        guard let c = Chord(globalHotkey), let code = Self.keyCodes[c.key] else { return nil }
        var m: Int = 0
        if c.mods.contains("cmd") { m |= cmdKey }
        if c.mods.contains("alt") { m |= optionKey }
        if c.mods.contains("ctrl") { m |= controlKey }
        if c.mods.contains("shift") { m |= shiftKey }
        return (UInt32(code), UInt32(m))
    }

    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
        "/": kVK_ANSI_Slash, ".": kVK_ANSI_Period, ",": kVK_ANSI_Comma, ";": kVK_ANSI_Semicolon,
        "`": kVK_ANSI_Grave, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
    ]
}
