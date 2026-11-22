import SwiftUI
import AppKit
import CircleCore

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    var detail: String = ""
    var current = false
    let run: () -> Void
}

/// ⌘K. Every setting lives here so the main window stays empty.
struct Palette: View {
    @Environment(AppModel.self) private var app
    var focus: FocusState<Field?>.Binding
    @State private var query = ""
    @State private var index = 0

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            TextField("", text: $query, prompt: Text("agent, model, folder, command…").foregroundColor(Theme.faint))
                .textFieldStyle(.plain)
                .focused(focus, equals: .palette)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .onSubmit { pick(items) }
                .onExitCommand { app.paletteOpen = false }
                .onKeyPress(.downArrow) { index = min(index + 1, max(items.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onChange(of: query) { index = 0 }
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            HStack {
                                Text(item.title).foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                                Text(item.current ? "●" : item.detail).foregroundStyle(Theme.dim).lineLimit(1)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(i == index ? Theme.selection : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { index = i; pick(items) }
                            .id(i)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)
                .onChange(of: index) { _, i in proxy.scrollTo(i) }
            }
        }
        .font(Theme.font)
        .frame(maxWidth: 480)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 28, y: 10)
        .padding(.horizontal, 16)
        .onAppear { focus.wrappedValue = .palette }
    }

    private func pick(_ items: [PaletteItem]) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        app.paletteOpen = false
        item.run()
    }

    private var filtered: [PaletteItem] {
        let all = allItems
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        var out = all.filter { fuzzy(q, $0.title.lowercased()) }
        // Free-form model: "codex gpt-5" or just "my-model" for the current agent.
        let reg = app.registry
        let parts = q.split(separator: " ", maxSplits: 1).map(String.init)
        if let a = reg.available.first(where: { $0.id == parts.first }), parts.count == 2 {
            if !reg.models(for: a).contains(parts[1]) {
                out.append(PaletteItem(id: "custom:\(a.id):\(parts[1])", title: "\(a.id) · \(parts[1])", detail: "use custom model") {
                    reg.choose(a, model: parts[1])
                })
            }
        } else if let a = reg.current, !q.contains(" "), !reg.models(for: a).contains(q), out.isEmpty {
            out.append(PaletteItem(id: "custom:\(a.id):\(q)", title: "\(a.id) · \(q)", detail: "use custom model") {
                reg.choose(a, model: q)
            })
        }
        return out
    }

    private var allItems: [PaletteItem] {
        let reg = app.registry, store = app.store
        var items: [PaletteItem] = []
        for a in reg.available {
            for m in reg.models(for: a) {
                items.append(PaletteItem(id: "m:\(a.id):\(m)", title: "\(a.id) · \(m)", detail: a.name,
                                         current: reg.agentID == a.id && reg.model == m) { reg.choose(a, model: m) })
            }
        }

        items.append(PaletteItem(id: "cwd", title: "folder…", detail: abbreviate(reg.cwd)) { chooseFolder() })
        for level in Autonomy.allCases {
            items.append(PaletteItem(id: "auto:\(level.rawValue)", title: "autonomy: \(level.rawValue)",
                                     detail: level.label, current: reg.autonomy == level) { reg.autonomy = level })
        }
        items.append(PaletteItem(id: "clear", title: "clear completed", detail: "undo with u") { store.clearCompleted() })
        items.append(PaletteItem(id: "mcp", title: "install mcp in agents", detail: "claude, codex") {
            app.say(reg.installMCP())
        })
        items.append(PaletteItem(id: "rescan", title: "rescan agents") { reg.scan(); app.say("scanning PATH") })
        items.append(PaletteItem(id: "sync", title: "reconnect sync", detail: store.syncState.label) { app.sync.reload() })
        items.append(PaletteItem(id: "account", title: "sync & account", detail: app.account.isReady ? "signed in" : "sign in") { app.accountOpen = true })
        items.append(PaletteItem(id: "section", title: "new section", detail: "⇧⌘N") { app.newSection() })
        items.append(PaletteItem(id: "settings", title: "open settings", detail: "settings.json  ⌘,") { Settings.shared.open() })
        items.append(PaletteItem(id: "keymap", title: "edit keymap", detail: "keymap.json") { app.keymap.openFile() })
        items.append(PaletteItem(id: "keymap-reload", title: "reload keymap") { app.reloadKeymap() })
        // Every keyboard command, with its current shortcut.
        for a in Action.allCases where a != .palette {
            items.append(PaletteItem(id: "act:\(a.rawValue)", title: a.title, detail: app.keymap.label(a)) { app.perform(a) })
        }
        return items
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: app.registry.cwd)
        p.prompt = "Use folder"
        if p.runModal() == .OK, let u = p.url { app.registry.cwd = u.path }
    }

    private func fuzzy(_ q: String, _ s: String) -> Bool {
        var it = s.makeIterator()
        for c in q where c != " " {
            var found = false
            while let x = it.next() { if x == c { found = true; break } }
            if !found { return false }
        }
        return true
    }
}
