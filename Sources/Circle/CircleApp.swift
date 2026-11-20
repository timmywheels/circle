import SwiftUI
import AppKit
import Carbon.HIToolbox
import CircleCore

@main
struct CircleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

    var body: some Scene {
        Window("Circle", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 380, minHeight: 260)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 640, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Todo") { app.focusInput(top: true) }.keyboardShortcut("n")
            }
            CommandMenu("Go") {
                Button("Command Palette") { app.paletteOpen.toggle() }.keyboardShortcut("k")
                Button("Toggle Agent Panel") { app.panelOpen.toggle() }.keyboardShortcut("j")
                Button("Run Agent on Selection") { app.runSelected() }.keyboardShortcut(.return, modifiers: .command)
                Divider()
                Button("Keyboard Shortcuts") { app.helpOpen.toggle() }.keyboardShortcut("/")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // ⌃⌥Space summons Circle from anywhere.
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) {
            MainActor.assumeIsolated { AppModel.shared.summon() }
        }
        MainActor.assumeIsolated { AppModel.shared.boot() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { AppModel.shared.summon() } }
        return true
    }
}

enum Field: Hashable { case input, list, edit, palette, notes, title }

struct DropHint: Equatable {
    let id: String
    let after: Bool
    let nest: Bool
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let store: Store
    let registry: AgentRegistry
    let runner: AgentRunner
    @ObservationIgnored let sync: SyncClient

    init() {
        let s = Store(), r = AgentRegistry()
        store = s
        registry = r
        runner = AgentRunner(store: s, registry: r)
        sync = SyncClient(store: s)
    }

    var focusRequest: Field? = .input
    var insertAfter: String?          // "o" adds below this id
    var editingID: String?
    var paletteOpen = false { didSet { if !paletteOpen { focusRequest = .list } } }
    var panelOpen = false
    var helpOpen = false
    /// Drag and drop state for the list.
    var dropHint: DropHint?
    @ObservationIgnored var draggingID: String?
    var flash: String?
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored private var flashWork: DispatchWorkItem?

    func boot() {
        sync.start()
        registry.scan()
    }

    func focusInput(top: Bool) {
        insertAfter = top ? nil : store.selection
        focusRequest = .input
    }

    func summon() {
        if NSApp.isActive, let w = mainWindow, w.isVisible, w.isKeyWindow {
            NSApp.hide(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow { w.makeKeyAndOrderFront(nil) } else { openWindow?(id: "main") }
        focusInput(top: true)
    }

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeKey }
            ?? NSApp.windows.first { $0.canBecomeKey && !($0 is NSPanel) }
    }

    func runSelected() {
        guard let id = store.selection else { return }
        handToAgent(id)
    }

    /// Turns the todo into a triangle and starts the current agent on it.
    func handToAgent(_ id: String) {
        guard registry.current != nil else {
            say(registry.scanned ? "no agent CLIs found on PATH" : "still looking for agents…"); return
        }
        guard let t0 = store.todo(id), !t0.isSection else { return }
        store.setKind(id, .agent)
        guard let t = store.todo(id) else { return }
        if runner.start(t) != nil { panelOpen = true }
    }

    /// Adds a todo from the input line. A trailing `@claude`, `@codex` (any detected
    /// agent) or plain `@` hands it straight to that agent.
    @discardableResult
    func submit(_ raw: String, after anchor: String?) -> Todo? {
        var words = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var agent: AgentDef?
        var mention = false
        if let last = words.last, last.hasPrefix("@") {
            let name = last.dropFirst().lowercased()
            if name.isEmpty || name == "agent" { mention = true; agent = registry.current }
            else if let a = registry.available.first(where: { $0.id == name }) { mention = true; agent = a }
            if mention { words.removeLast() }
        }
        let title = words.joined(separator: " ")
        guard let t = store.add(title, kind: mention ? .agent : .mine, after: anchor) else { return nil }
        if let a = agent {
            if a.id != registry.agentID { registry.choose(a, model: registry.models(for: a).first ?? "default") }
            handToAgent(t.id)
        } else if mention {
            say("no agent CLIs found on PATH")
        }
        return t
    }

    func say(_ s: String) {
        flash = s
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flash = nil }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }
}

/// Carbon global hotkey. Fires on the main thread.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var action: (() -> Void)?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.action?()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x424C4E4B), id: 1) // 'BLNK'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }
}
