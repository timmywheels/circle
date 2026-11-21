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
                .frame(minWidth: 300, minHeight: 220)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 640, height: 640)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { Settings.shared.open() }.keyboardShortcut(",")
                Button("Keymap…") { app.keymap.openFile() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Todo") { app.focusInput(top: true) }.keyboardShortcut("n")
            }
            CommandMenu("Go") {
                // Menu shortcuts work even while typing in a field; list keys live in keymap.json.
                Button("Command Palette") { app.paletteOpen.toggle() }.keyboardShortcut("k")
                Button("Details Panel") { app.perform(.details) }.keyboardShortcut("j")
                Button("Hand to Agent") { app.runSelected() }.keyboardShortcut(.return, modifiers: .command)
                Button("Back") { app.perform(.back) }.keyboardShortcut("[")
                Divider()
                Button("Keyboard Shortcuts") { app.helpOpen.toggle() }.keyboardShortcut("/")
                Button("Edit Keymap…") { app.keymap.openFile() }
                Button("Reload Keymap") { app.reloadKeymap() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { AppModel.shared.boot() }
        registerHotkey()
    }

    /// Summon chord from keymap.json ("global"), default ⌃⌥Space.
    func registerHotkey() {
        hotKey = nil
        let hk = MainActor.assumeIsolated { AppModel.shared.keymap.carbonHotkey }
            ?? (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        hotKey = HotKey(keyCode: hk.code, modifiers: hk.mods) {
            MainActor.assumeIsolated { AppModel.shared.summon() }
        }
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
    let keymap = Keymap()
    @ObservationIgnored let sync: SyncClient
    /// Where `back` (⌘[) returns to after following links.
    @ObservationIgnored var history: [String] = []

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
    /// Current window width; below ~640pt the layout goes compact.
    var windowWidth: CGFloat = 800
    var settings: Settings { Settings.shared }
    /// One column: the details panel replaces the list instead of sitting beside it.
    var compact: Bool {
        settings.panel == "overlay" || (settings.panel == "auto" && windowWidth < 640)
    }
    /// In-app drag state for the list.
    static let endDropID = "__end__"
    var dropHint: DropHint?
    var draggingID: String?
    var dragPoint: CGPoint = .zero
    @ObservationIgnored var rowFrames: [String: CGRect] = [:]
    var flash: String?
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored private var flashWork: DispatchWorkItem?

    func boot() {
        settings.onReload = { [weak self] in
            guard let self else { return }
            if store.hideDone != settings.hideCompleted { store.hideDone = settings.hideCompleted }
            store.autoArchive = settings.logbook != "never"
            say(settings.error ?? "settings reloaded")
        }
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

    /// Runs a keymap action against the current selection.
    func perform(_ a: Action) {
        let s = store
        let sel = s.selection
        switch a {
        case .down: s.select(1)
        case .up: s.select(-1)
        case .top: s.selection = s.ordered.first?.id
        case .bottom: s.selection = s.ordered.last?.id
        case .moveDown: if let id = sel { s.move(id, 1) }
        case .moveUp: if let id = sel { s.move(id, -1) }
        case .indent: if let id = sel { s.indent(id) }
        case .outdent: if let id = sel { s.outdent(id) }
        case .collapse: s.left()
        case .expand: s.right()
        case .toggle: if let id = sel { s.toggle(id) }
        case .edit: if sel != nil { editingID = sel; focusRequest = .edit }
        case .delete: if let id = sel { s.delete(id) }
        case .undo: s.undo()
        case .addTop: focusInput(top: true)
        case .addBelow: focusInput(top: false)
        case .run, .shapeAgent: runSelected()
        case .cancel: if let id = sel { runner.cancel(id) }
        case .details: panelOpen.toggle(); if !panelOpen { focusRequest = .list }
        case .notes: if sel != nil { panelOpen = true; focusRequest = .notes }
        case .shapeMine: if let id = sel { s.setKind(id, .mine) }
        case .shapeWaiting: if let id = sel { s.setKind(id, .waiting) }
        case .cycleShape: if let id = sel, let t = s.todo(id) { s.setKind(id, t.kind.next) }
        case .filterMine: s.filter = s.filter == .mine ? nil : .mine
        case .filterAgent: s.filter = s.filter == .agent ? nil : .agent
        case .filterWaiting: s.filter = s.filter == .waiting ? nil : .waiting
        case .filterAll: s.filter = nil; s.logbook = false
        case .followLink:
            guard let t = s.todo(sel) else { return }
            let names = Links.names(in: t.title) + Links.names(in: t.notes)
            guard let first = names.first else { say("no [[links]] in this todo"); return }
            openLink(named: first)
        case .back:
            guard let id = history.popLast(), s.todo(id) != nil else { return }
            reveal(id)
        case .hideDone: s.hideDone.toggle(); say(s.hideDone ? "hiding completed" : "showing completed")
        case .logbook: s.logbook.toggle(); say(s.logbook ? "logbook · space restores · esc back" : "")
        case .palette: paletteOpen.toggle()
        case .help: helpOpen.toggle()
        }
    }

    /// Opens the todo a [[link]] points at, creating it if it doesn't exist yet.
    func openLink(named name: String) {
        if let from = store.selection { history.append(from); if history.count > 50 { history.removeFirst() } }
        if let target = store.resolve(name) { reveal(target.id); return }
        if let t = store.add(name) { reveal(t.id); say("created [[\(name)]]") }
    }

    /// Selects a todo, expanding its ancestors and leaving filters/logbook so it is visible.
    func reveal(_ id: String) {
        store.reveal(id)
        store.selection = id
        panelOpen = true
        focusRequest = .list
    }

    func reloadKeymap() {
        keymap.reload()
        AppDelegate.shared?.registerHotkey()
        say(keymap.error ?? "keymap reloaded")
    }

    func dragMoved(_ id: String, to p: CGPoint) {
        guard !store.logbook else { return }
        if draggingID != id { draggingID = id; store.selection = id }
        dragPoint = p
        let h = dropTarget(at: p)
        if dropHint != h { dropHint = h }
    }

    func dragEnded(at p: CGPoint) {
        defer { draggingID = nil; dropHint = nil }
        guard let id = draggingID, let h = dropTarget(at: p) else { return }
        if h.id == Self.endDropID { store.moveToEnd(id) }
        else if h.nest { store.nest(id, under: h.id) }
        else { store.place(id, relativeTo: h.id, after: h.after) }
    }

    /// Which row (and which half of it) the cursor is over, in list coordinates.
    private func dropTarget(at p: CGPoint) -> DropHint? {
        guard let dragged = draggingID else { return nil }
        for t in store.ordered {
            guard let f = rowFrames[t.id], p.y >= f.minY, p.y < f.maxY else { continue }
            if t.id == dragged { return nil }
            let after = p.y > f.midY
            let level = store.filter == nil ? (store.depth[t.id] ?? 0) : 0
            let titleStart = 8 + CGFloat(level) * 22 + 34
            let nest = after && store.filter == nil && p.x > titleStart + 60
            return DropHint(id: t.id, after: after, nest: nest)
        }
        if let last = store.ordered.last, let f = rowFrames[last.id], p.y >= f.maxY, last.id != dragged {
            return DropHint(id: Self.endDropID, after: false, nest: false)
        }
        return nil
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
    private static var handlerInstalled = false

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKey.action = action
        if !HotKey.handlerInstalled {
            HotKey.handlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                HotKey.action?()
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = EventHotKeyID(signature: OSType(0x424C4E4B), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }
}
