import SwiftUI
import AppKit
import CircleCore

@MainActor
enum Theme {
    static let bg = Color(nsColor: .textBackgroundColor)
    static let line = Color.primary.opacity(0.06)
    static let selection = Color.primary.opacity(0.075)
    static let dim = Color.primary.opacity(0.38)
    static let faint = Color.primary.opacity(0.22)
    /// Sizes follow settings.json "font_size" live.
    static var font: Font { .system(size: Settings.shared.fontSize, design: .monospaced) }
    /// Details title: one step up from body text so it reads as the heading.
    static var title: Font { .system(size: Settings.shared.fontSize + 4, weight: .semibold, design: .monospaced) }
    /// Notes body: readable, but quieter than the title.
    static let body = Color.primary.opacity(0.72)
    static var small: Font { .system(size: max(9, Settings.shared.fontSize - 2.5), design: .monospaced) }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focus: Field?

    var body: some View {
        let compact = app.compact
        let panelID = app.panelOpen ? app.store.selection : nil
        let listColumn = VStack(spacing: 0) {
            InputLine(focus: $focus)
            Rectangle().fill(Theme.line).frame(height: 1)
            TodoList(focus: $focus)
            Rectangle().fill(Theme.line).frame(height: 1)
            StatusLine()
        }
        Group {
            if compact {
                if let id = panelID { AgentPanel(todoID: id, focus: $focus) } else { listColumn }
            } else {
                HStack(spacing: 0) {
                    listColumn.frame(minWidth: 280, maxWidth: .infinity)
                    if let id = panelID {
                        SplitHandle()
                        AgentPanel(todoID: id, focus: $focus)
                            .frame(width: app.clampedPanelWidth)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { app.windowWidth = $0 }
        // Use the hidden title bar's strip: rows start just under the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .font(Theme.font)
        .background(Theme.bg)
        .overlay(alignment: .top) {
            if app.paletteOpen { Palette(focus: $focus).padding(.top, 44) }
        }
        .overlay {
            if app.helpOpen { HelpOverlay().onTapGesture { app.helpOpen = false } }
        }
        .transaction { $0.animation = nil }   // nothing animates; everything is immediate
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "circle", let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "t" })?.value else { return .systemAction }
            app.openLink(named: name)
            return .handled
        })
        .onAppear { app.openWindow = openWindow; applyFocus() }
        // Opening or closing details in compact mode swaps which view holds the keys.
        .onChange(of: panelID) { _, _ in if compact { DispatchQueue.main.async { focus = .list } } }
        .onChange(of: app.focusRequest) { applyFocus() }
        .onChange(of: focus) { _, f in app.currentFocus = f }
    }

    private func applyFocus() {
        guard let f = app.focusRequest else { return }
        app.focusRequest = nil
        // The target may only exist after this render (list <-> details swap in compact mode).
        DispatchQueue.main.async { focus = f }
    }
}

// MARK: input

struct InputLine: View {
    @Environment(AppModel.self) private var app
    var focus: FocusState<Field?>.Binding
    @State private var draft = ""
    @State private var pick = 0

    /// The text after an unclosed "[[", if the caret is inside a link being typed.
    private var linkQuery: String? {
        guard let r = draft.range(of: "[[", options: .backwards) else { return nil }
        let rest = draft[r.upperBound...]
        return rest.contains("]]") ? nil : String(rest)
    }

    private func complete(_ t: Todo) {
        guard let r = draft.range(of: "[[", options: .backwards) else { return }
        draft = String(draft[..<r.lowerBound]) + "[[" + t.displayTitle + "]] "
        pick = 0
    }

    var body: some View {
        let sugg = linkQuery.map { app.store.suggestions($0) } ?? []
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
            Text(app.insertAfter == nil ? "+" : "↳").foregroundStyle(Theme.dim)
            TextField("", text: $draft, prompt: Text(placeholder).foregroundColor(Theme.faint))
                .textFieldStyle(.plain)
                .focused(focus, equals: .input)
                .onSubmit {
                    if !sugg.isEmpty { complete(sugg[min(pick, sugg.count - 1)]); focus.wrappedValue = .input }
                    else { submit() }
                }
                .onExitCommand {
                    if linkQuery != nil { draft += "]]"; return }
                    draft = ""; app.insertAfter = nil; focus.wrappedValue = .list
                }
                .onKeyPress(.downArrow) {
                    if !sugg.isEmpty { pick = min(pick + 1, sugg.count - 1); return .handled }
                    if app.store.selection == nil { app.store.selection = app.store.ordered.first?.id }
                    focus.wrappedValue = .list; return .handled
                }
                .onKeyPress(.upArrow) {
                    if !sugg.isEmpty { pick = max(pick - 1, 0); return .handled }
                    return .ignored
                }
                .onKeyPress(.tab) {
                    if !sugg.isEmpty { complete(sugg[min(pick, sugg.count - 1)]); return .handled }
                    return .ignored
                }
                .onChange(of: linkQuery) { pick = 0 }
                .onChange(of: app.inputPrefill) { _, v in if let v { draft = v; app.inputPrefill = nil } }
                .onAppear { if let v = app.inputPrefill { draft = v; app.inputPrefill = nil } }
        }
        .padding(.leading, 16).padding(.trailing, 16)
        .padding(.top, 30).padding(.bottom, 12)   // clears the traffic lights
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = .input }
        if !sugg.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sugg.enumerated()), id: \.element.id) { i, t in
                    HStack(spacing: 8) {
                        Text(t.glyph).foregroundStyle(Theme.faint)
                        Text(t.title).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(i == pick ? Theme.selection : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { complete(t); focus.wrappedValue = .input }
                }
            }
            .padding(.vertical, 4)
            .padding(.leading, 30).padding(.trailing, 16).padding(.bottom, 8)
        }
        }
    }

    private var placeholder: String {
        if let a = app.insertAfter, let t = app.store.todo(a) { return "add below “\(t.title.prefix(30))”" }
        guard app.settings.hints && !app.compact else { return "add a todo" }
        return "add a todo   ·   end with @\(app.registry.current?.id ?? "claude") to hand it off"
    }

    private func submit() {
        if let t = app.submit(draft, after: app.insertAfter) {
            if app.insertAfter != nil { app.insertAfter = t.id } // keep chaining downward
            app.store.selection = t.id
        }
        draft = ""
        focus.wrappedValue = .input   // stay in flow: type, enter, type, enter
    }
}

// MARK: list

struct TodoList: View {
    @Environment(AppModel.self) private var app
    var focus: FocusState<Field?>.Binding

    var body: some View {
        let store = app.store
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.ordered.enumerated()), id: \.element.id) { i, t in
                        if store.logbook, let label = dayLabel(t, previous: i > 0 ? store.ordered[i - 1] : nil) {
                            Text(label).font(Theme.small).fontWeight(.semibold).tracking(0.8)
                                .foregroundStyle(Theme.dim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 18).padding(.top, i == 0 ? 6 : 16).padding(.bottom, 4)
                        }
                        TodoRow(todo: t, selected: t.id == store.selection, focus: focus)
                            .id(t.id)
                    }
                }
                .padding(.vertical, 6)
                .coordinateSpace(.named(listSpace))
                .overlay(alignment: .topLeading) { DragGhost() }
                if store.ordered.isEmpty {
                    Text(store.logbook ? "nothing in the logbook yet. completed items land here the next day."
                         : store.hideDone ? "all clear. completed items hidden." : "nothing here. start typing.")
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 40)
                }
                if app.dropHint?.id == AppModel.endDropID {
                    Rectangle().fill(Color.accentColor).frame(height: 2).padding(.leading, 30)
                }
            }
            .scrollIndicators(.never)
            .onChange(of: store.selection) { _, id in if let id { proxy.scrollTo(id) } }
        }
        .focusable()
        .focused(focus, equals: .list)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
    }

    /// "TODAY", "YESTERDAY", "TUE NOV 18" headers in the logbook.
    private func dayLabel(_ t: Todo, previous: Todo?) -> String? {
        let cal = Calendar.current
        let day = Date(timeIntervalSince1970: Double(t.updatedAt) / 1000)
        if let p = previous, cal.isDate(day, inSameDayAs: Date(timeIntervalSince1970: Double(p.updatedAt) / 1000)) { return nil }
        if cal.isDateInToday(day) { return "TODAY" }
        if cal.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
    }

    private func handle(_ k: KeyPress) -> KeyPress.Result {
        // While a row is being renamed inline, keys belong to the text field.
        guard focus.wrappedValue == .list else { return .ignored }
        return app.handleKey(k)
    }


}

struct TodoRow: View {
    @Environment(AppModel.self) private var app
    let todo: Todo
    let selected: Bool
    var focus: FocusState<Field?>.Binding
    @State private var editText = ""

    var body: some View {
        let run = app.runner.run(for: todo.id)
        let store = app.store
        let level = store.filter == nil ? (store.depth[todo.id] ?? 0) : 0
        let hasKids = store.hasChildren(todo.id)
        HStack(spacing: 10) {
            Group {
                if hasKids && store.filter == nil {
                    Text(store.collapsed.contains(todo.id) ? "▸" : "▾")
                        .foregroundStyle(Theme.faint)
                        .contentShape(Rectangle())
                        .onTapGesture { store.setCollapsed(todo.id, !store.collapsed.contains(todo.id)) }
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            .padding(.leading, CGFloat(level) * 22)
            .padding(.trailing, -4)
            if !todo.isSection {
                ShapeGlyph(todo: todo, running: run?.status == .running)
                    .frame(width: 14)
                    .contentShape(Rectangle())
                    .onTapGesture { app.store.toggle(todo.id) }
                    .help("click to fill in · 1 ○ mine · 2 △ agent · 3 □ waiting")
            }
            if app.editingID == todo.id {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .focused(focus, equals: .edit)
                    .onAppear { editText = todo.title }
                    .onSubmit { app.store.rename(todo.id, editText); endEdit() }
                    .onExitCommand { endEdit() }
                    .onChange(of: focus.wrappedValue) { _, f in
                        if f != .edit && app.editingID == todo.id { app.store.rename(todo.id, editText); app.editingID = nil }
                    }
            } else {
                if todo.isSection {
                    Text(todo.displayTitle.uppercased())
                        .font(Theme.small).fontWeight(.semibold).tracking(0.8)
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                } else {
                    LinkedText(text: todo.title, done: todo.done)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if todo.remindAt > 0 && !todo.done {
                let overdue = todo.remindAt < Int64(Date().timeIntervalSince1970 * 1000)
                Text((todo.repeatRule.isEmpty ? "" : "↻ ") + When.short(todo.remindAt))
                    .font(Theme.small)
                    .foregroundStyle(overdue ? Color.accentColor : Theme.dim)
                    .lineLimit(1)
            }
            if let p = store.progress[todo.id] {
                Text("\(p.done)/\(p.total)").font(Theme.small)
                    .foregroundStyle(p.done == p.total ? Theme.faint : Theme.dim)
            }
            if !todo.notes.isEmpty { Text("¶").foregroundStyle(Theme.faint) }
            if store.logbook {
                Text(Date(timeIntervalSince1970: Double(todo.completedAt) / 1000), format: .dateTime.hour().minute())
                    .font(Theme.small).foregroundStyle(Theme.faint)
            }
            if let run { RunBadge(run: run) }
            else if selected && app.settings.hints && !app.compact && !todo.done && !todo.isSection && app.editingID != todo.id, let a = app.registry.current {
                Text("r → \(a.id)").font(Theme.small).foregroundStyle(Theme.faint)
            }
        }
        .padding(.leading, 8).padding(.trailing, 16)
        .padding(.vertical, 5)
        .background(selected ? (focus.wrappedValue == .list ? Color.accentColor.opacity(0.16) : Theme.selection) : .clear)
        // Breathing room above top-level sections sits outside the highlight.
        .padding(.top, todo.isSection && level == 0 ? 9 : 0)
        .overlay(alignment: app.dropHint?.after == true ? .bottom : .top) {
            if let h = app.dropHint, h.id == todo.id {
                Rectangle().fill(Color.accentColor).frame(height: 2)
                    .padding(.leading, 8 + CGFloat(h.depth) * 22 + 14)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { RowMenu(todo: todo) }
        .onTapGesture {
            app.store.selection = todo.id
            focus.wrappedValue = .list
            if todo.isSection { app.store.setCollapsed(todo.id, !app.store.collapsed.contains(todo.id)); return }
            if NSApp.currentEvent?.clickCount == 2 { app.panelOpen = true }
        }
        .opacity(app.draggingID == todo.id ? 0.35 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(listSpace)) } action: { app.rowFrames[todo.id] = $0 }
        // In-app drag: no system drag session, so nothing floats or animates after the drop.
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(listSpace))
                .onChanged { v in app.dragMoved(todo.id, to: v.location) }
                .onEnded { v in app.dragEnded(at: v.location) }
        )
    }

    private func endEdit() {
        app.editingID = nil
        focus.wrappedValue = .list
    }
}

struct RunBadge: View {
    let run: AgentRun
    var body: some View {
        switch run.status {
        case .running: Text("● \(run.agent)").foregroundStyle(Color.accentColor).font(Theme.small)
        case .done: Text(run.agent).foregroundStyle(Theme.faint).font(Theme.small)
        case .failed: Text("✕ \(run.agent)").foregroundStyle(.red.opacity(0.7)).font(Theme.small)
        case .cancelled: Text("– \(run.agent)").foregroundStyle(Theme.faint).font(Theme.small)
        }
    }
}

// MARK: status line

struct StatusLine: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let reg = app.registry
        HStack(spacing: 14) {
            Button { app.paletteOpen = true } label: {
                if let a = reg.current { Text("\(a.id) · \(reg.model)") }
                else { Text(reg.scanned ? "no agents" : "scanning…") }
            }
            .buttonStyle(.plain)
            .lineLimit(1)
            if app.settings.hints && app.windowWidth > 460 {
                Text(hint).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if let f = app.flash, !f.isEmpty { Text(f).foregroundStyle(Color.primary.opacity(0.7)).lineLimit(1) }
            if app.store.logbook { Text("logbook").foregroundStyle(Color.primary) }
            ShapeCounts()
            HStack(spacing: 5) {
                Circle().fill(syncColor).frame(width: 6, height: 6)
                if !app.compact { Text(app.store.syncState.label) }
            }
        }
        .font(Theme.small)
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, app.compact ? 12 : 16)
        .frame(height: 26)
    }

    /// The few keys that matter for where the keyboard is right now.
    private var hint: String {
        switch app.currentFocus {
        case .input: return "↩ add · # section · !remind · @agent · ↓ list"
        case .notes, .title, .remind, .edit: return "esc done"
        case .palette: return "↑↓ pick · ↩ run · esc close"
        default:
            if app.panelOpen { return "← back · ↩ notes · ↑↓ next · m remind" }
            if app.store.ordered.isEmpty { return "a add · ⇧⌘N section" }
            return "↩ open · space done · tab nest · ⌘K"
        }
    }

    private var syncColor: Color {
        switch app.store.syncState {
        case .synced: return .green.opacity(0.75)
        case .connecting: return .yellow.opacity(0.8)
        case .offline: return .orange.opacity(0.8)
        case .local: return Theme.faint
        }
    }
}

// MARK: agent panel

struct AgentPanel: View {
    @Environment(AppModel.self) private var app
    let todoID: String
    var focus: FocusState<Field?>.Binding
    @State private var notes = ""
    @State private var title = ""
    @State private var editingTitle = false

    var body: some View {
        let todo = app.store.todo(todoID)
        let run = app.runner.run(for: todoID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
            if editingTitle {
                TextField("", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.title)
                    .lineLimit(1...4)
                    .focused(focus, equals: .title)
                    .onSubmit { app.store.rename(todoID, title); editingTitle = false; app.focusRequest = .list }
                    .onExitCommand { title = todo?.title ?? ""; editingTitle = false; app.focusRequest = .list }
                    .onChange(of: focus.wrappedValue) { old, new in
                        if old == .title && new != .title { app.store.rename(todoID, title); editingTitle = false }
                    }
                    .onAppear { DispatchQueue.main.async { focus.wrappedValue = .title } }
            } else {
                // Reads like the list: [[links]] are links. Click the text (or press e) to edit the raw title.
                LinkedText(text: todo?.title ?? "", done: todo?.done ?? false)
                    .font(Theme.title)
                    .lineSpacing(2)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .help(todo.map { Stamps.text(for: $0) } ?? "")
                    .contextMenu { if let t = todo { RowMenu(todo: t) } }
                    .onTapGesture { title = todo?.title ?? ""; editingTitle = true }
            }
            }
            .padding(.leading, 16).padding(.trailing, 28).padding(.top, 30).padding(.bottom, 16)
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("notes").foregroundStyle(Theme.faint).padding(.leading, 5)
                }
                TextEditor(text: $notes)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Theme.body)
                    .lineSpacing(4)
                    .background(MarkdownHook { app.openLink(named: $0) })
                    .focused(focus, equals: .notes)
                    .onExitCommand { app.focusRequest = .list }
            }
            .font(Theme.font)
            .frame(minHeight: 80, maxHeight: run == nil ? .infinity : 260)
            .padding(.horizontal, 11)
            if todo?.isSection != true, run != nil {
            Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 6)
            HStack {
                if let run {
                    Text("\(run.agent) · \(run.model) · \(run.status.rawValue)")
                } else {
                    Text("not run yet")
                }
                Spacer()
                Text(run?.status == .running ? "c cancel" : "⌘↩ run").foregroundStyle(Theme.faint)
            }
            .font(Theme.small).foregroundStyle(Theme.dim)
            .padding(.horizontal, 16).frame(height: 26)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(run?.output ?? "")
                        .font(Theme.small)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: run?.output.count ?? 0) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            }
            if let t = todo { DetailsFooter(todo: t, focus: focus) }
        }
        .modifier(PanelKeys(focus: focus, active: app.compact))
        .overlay(alignment: .topTrailing) {
            Button { app.panelOpen = false; app.focusRequest = .list } label: {
                Text("×").font(.system(size: 15)).foregroundStyle(Theme.dim)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("close  (esc · \(app.keymap.label(.details)))")
            .padding(.top, 3).padding(.trailing, 8)
        }
        .onAppear { load() }
        .onChange(of: todoID) { _, _ in load() }
        .onChange(of: app.titleEditRequest) { title = todo?.title ?? ""; editingTitle = true }
        .onChange(of: notes) { _, v in
            if focus.wrappedValue == .notes { app.store.setNotes(todoID, v) }
        }
    }

    private func load() {
        editingTitle = false
        title = app.store.todo(todoID)?.title ?? ""
        notes = app.store.todo(todoID)?.notes ?? ""
        app.runner.loadHistory(todoID)
    }
}

// MARK: help

struct HelpOverlay: View {
    @Environment(AppModel.self) private var app

    private let extras: [(String, String)] = [
        ("type ↩", "add todo (input stays focused)"),
        ("…@claude ↩", "add and hand straight to an agent"),
        ("[[ ", "link another todo (↑↓ tab to pick)"),
        ("# name ↩", "add a section header"),
        ("…!fri 9am ↩", "add with a reminder (!1st every month, !30m)"),
        ("dbl-click", "details"),
        ("drag", "reorder · right half nests"),
        ("esc", "close panel / leave logbook or filter"),
    ]

    var body: some View {
        let km = app.keymap
        let rows: [(String, String)] = Action.allCases.compactMap { a in
            let l = km.label(a); return l.isEmpty ? nil : (l, a.title)
        } + extras + [(Chord(km.globalHotkey)?.label ?? km.globalHotkey, "summon Circle from anywhere")]
        let half = (rows.count + 1) / 2
        VStack(alignment: .leading, spacing: 10) {
            if app.compact {
                ScrollView { column(rows) }.frame(maxHeight: 460)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    column(Array(rows[..<half]))
                    column(Array(rows[half...]))
                }
            }
            Text("keymap.json · settings.json (⌘,)").foregroundStyle(Theme.faint)
        }
        .font(Theme.small)
        .padding(20)
        .background(Theme.bg)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
    }

    private func column(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 0) {
                    Text(rows[i].0).frame(width: 96, alignment: .leading).foregroundStyle(.primary)
                    Text(rows[i].1).foregroundStyle(Theme.dim)
                }
            }
        }
    }
}


// MARK: shapes

struct ShapeGlyph: View {
    let todo: Todo
    let running: Bool

    var body: some View {
        if running {
            // The one moving thing in the app: a triangle that breathes while an agent works.
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                Text(todo.glyph)
                    .foregroundStyle(Color.accentColor)
                    .opacity(0.45 + 0.55 * (0.5 + 0.5 * sin(t * 3)))
            }
        } else {
            Text(todo.glyph).foregroundStyle(todo.done ? Theme.faint : Theme.dim)
        }
    }
}

struct ShapeCounts: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.store
        HStack(spacing: 10) {
            ForEach(Kind.allCases, id: \.self) { k in
                Button {
                    s.filter = s.filter == k ? nil : k
                } label: {
                    Text("\(k.glyph(done: false)) \(s.openCounts[k] ?? 0)")
                        .foregroundStyle(s.filter == k ? Color.primary : Theme.dim)
                        .fontWeight(s.filter == k ? .semibold : .regular)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct RowMenu: View {
    @Environment(AppModel.self) private var app
    let todo: Todo

    var body: some View {
        if todo.isSection {
            Button("Edit") { edit() }
            Button("Delete Section") { app.store.delete(todo.id) }
        } else {
            Button(todo.done ? "Mark Not Done" : "Mark Done") { app.store.toggle(todo.id) }
            Button("Open Details") { app.store.selection = todo.id; app.panelOpen = true }
            Divider()
            if let a = app.registry.current {
                Button("△  Hand to \(a.id) · \(app.registry.model)") { app.store.selection = todo.id; app.handToAgent(todo.id) }
            }
            Button("○  Mine") { app.store.setKind(todo.id, .mine) }
            Button("□  Waiting") { app.store.setKind(todo.id, .waiting) }
            Divider()
            Menu(todo.remindAt > 0 ? "Remind · \(When.short(todo.remindAt))" : "Remind") {
                ForEach(Self.presets.indices, id: \.self) { i in
                    Button(Self.presets[i].0) { remind(Self.presets[i].1, keepRule: true) }
                }
                Divider()
                Button("Custom…") { app.store.selection = todo.id; app.perform(.remind) }
                if todo.remindAt > 0 {
                    Divider()
                    Button("Clear Reminder") { app.store.setReminder(todo.id, at: 0, rule: "") }
                }
            }
            Menu(todo.repeatRule.isEmpty ? "Repeat" : "Repeat · \(When.describe(rule: todo.repeatRule))") {
                ForEach(Self.rules.indices, id: \.self) { i in
                    let (label, rule) = Self.rules[i]
                    Button((todo.repeatRule == rule ? "✓ " : "") + label) { setRepeat(rule) }
                }
                if !todo.repeatRule.isEmpty {
                    Divider()
                    Button("Don't Repeat") { setRepeat("") }
                }
            }
            Divider()
            Button("Nest Under Item Above") { app.store.indent(todo.id) }
            Button("Un-nest") { app.store.outdent(todo.id) }
            Divider()
            Button("Edit Title") { edit() }
            Button("Copy as [[link]]") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[[\(todo.displayTitle)]]", forType: .string)
            }
            Menu("Info") {
                Text(Stamps.text(for: todo))
                if todo.remindAt > 0 { Text("remind " + When.long(todo.remindAt, rule: todo.repeatRule)) }
                Text("id \(todo.id)")
            }
            Divider()
            Button("Delete") { app.store.delete(todo.id) }
        }
        Divider()
        Button("New Section") { app.newSection() }
    }

    static let presets: [(String, String)] = [
        ("In 30 Minutes", "30m"), ("In 1 Hour", "1h"), ("This Evening", "6pm"),
        ("Tomorrow Morning", "tomorrow"), ("Next Monday", "next monday"),
    ]
    static let rules: [(String, String)] = [
        ("Daily", "day:1"), ("Weekdays", "weekdays"), ("Weekly", "week:1"), ("Monthly", "month:1"), ("Yearly", "year:1"),
    ]

    private func edit() {
        app.store.selection = todo.id
        if app.panelOpen { app.titleEditRequest += 1 } else { app.editingID = todo.id; app.focusRequest = .edit }
    }

    private func remind(_ phrase: String, keepRule: Bool) {
        guard let p = When.parse(phrase, defaultHour: app.settings.reminderHour) else { return }
        let ms = Int64(p.date.timeIntervalSince1970 * 1000)
        app.store.setReminder(todo.id, at: ms, rule: keepRule && p.rule.isEmpty ? todo.repeatRule : p.rule)
        app.say("remind " + When.long(ms, rule: keepRule ? todo.repeatRule : p.rule))
    }

    /// Repeating needs a time: with none set, start tomorrow at the reminder hour.
    private func setRepeat(_ rule: String) {
        if rule.isEmpty { app.store.setReminder(todo.id, at: todo.remindAt, rule: ""); return }
        var at = todo.remindAt
        if at == 0, let p = When.parse("tomorrow", defaultHour: app.settings.reminderHour) {
            at = Int64(p.date.timeIntervalSince1970 * 1000)
        }
        app.store.setReminder(todo.id, at: at, rule: rule)
        app.say("↻ " + When.long(at, rule: rule))
    }
}


// MARK: drag

let listSpace = "circle.list"

/// The row being dragged, following the cursor. Never intercepts the mouse.
struct DragGhost: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let id = app.draggingID, let t = app.store.todo(id) {
            HStack(spacing: 8) {
                Text(t.isSection ? "#" : t.glyph).foregroundStyle(Theme.dim)
                Text(t.displayTitle).lineLimit(1)
            }
            .font(Theme.font)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .frame(maxWidth: 360, alignment: .leading)
            .offset(x: app.dragPoint.x + 10, y: app.dragPoint.y - 12)
            .allowsHitTesting(false)
        }
    }
}

// MARK: links and timestamps

/// A title with [[links]] rendered as clickable, underlined text.
struct LinkedText: View {
    @Environment(AppModel.self) private var app
    let text: String
    let done: Bool

    var body: some View {
        if text.contains("[[") { Text(attributed) } else {
            Text(text)
                .strikethrough(done, color: Theme.faint)
                .foregroundStyle(done ? Theme.faint : .primary)
        }
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        let base: Color = done ? Theme.faint : .primary
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            var plain = AttributedString(String(rest[..<open.lowerBound]))
            plain.foregroundColor = base
            out += plain
            let name = String(rest[open.upperBound..<close.lowerBound])
            var link = AttributedString(name)
            let exists = app.store.resolve(name) != nil
            let linkColor: Color = done ? Theme.faint : (exists ? Color.accentColor : Theme.dim)
            link.foregroundColor = linkColor
            link.underlineStyle = exists ? Text.LineStyle.single : Text.LineStyle(pattern: .dot)
            var c = URLComponents(); c.scheme = "circle"; c.host = "open"; c.queryItems = [URLQueryItem(name: "t", value: name)]
            link.link = c.url
            out += link
            rest = rest[close.upperBound...]
        }
        var tail = AttributedString(String(rest)); tail.foregroundColor = base
        out += tail
        if done { out.strikethroughStyle = Text.LineStyle.single }
        return out
    }
}

/// "created Nov 20, 6:12 PM · done 2h ago"
struct Stamps: View {
    let todo: Todo

    var body: some View {
        Text(line)
            .font(Theme.small).foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
        .help("id \(todo.id)")
    }

    /// Plain text for tooltips: "created 7 hours ago · edited 2 hours ago".
    static func text(for t: Todo) -> String { Stamps(todo: t).line.replacingOccurrences(of: "\u{00A0}", with: " ") }

    private var line: String {
        var parts = ["created \(fmt(todo.createdAt))"]
        if todo.done { parts.append("done \(fmt(todo.completedAt))") }
        else if todo.updatedAt - todo.createdAt > 60_000 { parts.append("edited \(fmt(todo.updatedAt))") }
        // Non-breaking spaces keep "3 hours ago" together; lines wrap only at the separators.
        return parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
    }

    private func fmt(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        if Date().timeIntervalSince(d) < 3600 * 12 { return d.formatted(.relative(presentation: .named)) }
        return d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// Outgoing [[links]] and backlinks for the details panel.
struct LinksBlock: View {
    @Environment(AppModel.self) private var app
    let todoID: String

    var body: some View {
        let store = app.store
        let t = store.todo(todoID)
        var seen = Set<String>()
        let out = (Links.names(in: t?.title ?? "") + Links.names(in: t?.notes ?? ""))
            .filter { seen.insert(Links.key($0)).inserted }
        let back = store.backlinks(todoID)
        if !out.isEmpty || !back.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !out.isEmpty {
                    row("links to", out.map { name in (name, store.resolve(name)?.glyph ?? "+") })
                }
                if !back.isEmpty {
                    row("linked from", back.map { ($0.displayTitle, $0.glyph) })
                }
            }
            .font(Theme.small)
            .padding(.horizontal, 16).padding(.top, 6)
        }
    }

    private func row(_ label: String, _ items: [(String, String)]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Theme.faint).lineLimit(1).fixedSize().frame(minWidth: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items.indices, id: \.self) { i in
                    Button { app.openLink(named: items[i].0) } label: {
                        HStack(spacing: 6) {
                            Text(items[i].1).foregroundStyle(Theme.faint)
                            Text(items[i].0).foregroundStyle(Color.accentColor).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}


// MARK: reminders and panel keys

/// In compact mode the list is hidden while details are open, so the panel
/// takes keyboard focus and runs the same key handler.
struct PanelKeys: ViewModifier {
    @Environment(AppModel.self) private var app
    var focus: FocusState<Field?>.Binding
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .focusable()
                .focused(focus, equals: .list)
                .focusEffectDisabled()
                // Keys typed into the notes / title / reminder fields are text, not shortcuts.
                .onKeyPress(phases: [.down, .repeat]) { focus.wrappedValue == .list ? app.handleKey($0) : .ignored }
        } else {
            content
        }
    }
}

/// "remind  tomorrow 9am, every weekday" — type a phrase, ↩ to set, empty to clear.
struct ReminderField: View {
    @Environment(AppModel.self) private var app
    let todo: Todo
    var focus: FocusState<Field?>.Binding
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "alarm").font(.system(size: 11)).foregroundStyle(Theme.faint)
            TextField("", text: $text, prompt: Text(todo.remindAt > 0 ? When.long(todo.remindAt, rule: todo.repeatRule)
                                                                      : "when? tomorrow 9am, every weekday, 30m")
                .foregroundColor(todo.remindAt > 0 ? Theme.dim : Theme.faint))
                .textFieldStyle(.plain)
                .lineLimit(1)
                .focused(focus, equals: .remind)
                .onSubmit(apply)
                .onExitCommand { text = ""; app.remindEditing = false; app.focusRequest = .list }
                .onAppear { if app.remindEditing { DispatchQueue.main.async { focus.wrappedValue = .remind } } }
                .onChange(of: focus.wrappedValue) { old, new in if old == .remind && new != .remind { app.remindEditing = false } }
            if todo.remindAt > 0 {
                Button { app.store.setReminder(todo.id, at: 0, rule: "") } label: { Text("×").foregroundStyle(Theme.faint) }
                    .buttonStyle(.plain).help("clear reminder")
            }
            Spacer(minLength: 0)
        }
        .font(Theme.small)
    }

    private func apply() {
        let spec = text.trimmingCharacters(in: .whitespaces)
        defer { text = "" }
        if spec.isEmpty { app.remindEditing = false; app.focusRequest = .list; return }
        if spec == "none" || spec == "clear" {
            app.store.setReminder(todo.id, at: 0, rule: "")
        } else if let p = When.parse(spec, defaultHour: app.settings.reminderHour) {
            let ms = Int64(p.date.timeIntervalSince1970 * 1000)
            app.store.setReminder(todo.id, at: ms, rule: p.rule)
            app.say("remind " + When.long(ms, rule: p.rule))
        } else {
            app.say("couldn't read “\(spec)” as a time")
            return
        }
        app.remindEditing = false
        app.focusRequest = .list
    }
}


/// The quiet bottom of the details panel: links, reminder, timestamps.
struct DetailsFooter: View {
    @Environment(AppModel.self) private var app
    let todo: Todo
    var focus: FocusState<Field?>.Binding

    var body: some View {
        let showRemind = !todo.isSection && (todo.remindAt > 0 || app.remindEditing)
        let hasLinks = LinksSection.count(todo, app.store) > 0
        VStack(alignment: .leading, spacing: 0) {
            if hasLinks || showRemind {
                Rectangle().fill(Theme.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    LinksSection(todo: todo)
                    if showRemind { ReminderField(todo: todo, focus: focus) }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            // Same line, height and type as the status bar on the left, so the bottom reads as one bar.
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 10) {
                Text(stamp).lineLimit(1).truncationMode(.tail)
                    .help(Stamps.text(for: todo))
                Spacer(minLength: 8)
                if !todo.isSection {
                    Button { app.store.selection = todo.id; app.perform(.remind) } label: {
                        Image(systemName: todo.remindAt > 0 ? "alarm.fill" : "alarm")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(todo.remindAt > 0 ? Theme.dim : Theme.faint)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(todo.remindAt > 0 ? When.long(todo.remindAt, rule: todo.repeatRule) + "  (m to change)" : "Remind me (m)")
                }
            }
            .font(Theme.small)
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 16)
            .frame(height: 26)
        }
    }

    /// One short stamp for the bar ("edited 37 min ago"); the full line is in the tooltip.
    private var stamp: String {
        func rel(_ ms: Int64) -> String {
            Date(timeIntervalSince1970: Double(ms) / 1000).formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        }
        if todo.done { return "done " + rel(todo.completedAt) }
        if todo.updatedAt - todo.createdAt > 60_000 { return "edited " + rel(todo.updatedAt) }
        return "created " + rel(todo.createdAt)
    }
}


/// "▸ links (2)" — collapsed by default, remembers its state.
struct LinksSection: View {
    @Environment(AppModel.self) private var app
    let todo: Todo
    @AppStorage("linksOpen") private var open = false

    static func count(_ todo: Todo, _ store: Store) -> Int {
        Set((Links.names(in: todo.title) + Links.names(in: todo.notes)).map(Links.key)).count + store.backlinks(todo.id).count
    }

    var body: some View {
        let total = Self.count(todo, app.store)
        if total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Button { open.toggle() } label: {
                    Text("\(open ? "▾" : "▸") links (\(total))").foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                if open { LinksBlock(todoID: todo.id).padding(.horizontal, -16).padding(.top, -6) }
            }
        }
    }
}


/// The divider between list and details: drag to resize (width is remembered).
struct SplitHandle: View {
    @Environment(AppModel.self) private var app
    @State private var start: CGFloat?

    var body: some View {
        Rectangle().fill(Theme.line).frame(width: 1)
            .padding(.horizontal, 3)          // wider grab area than the visible line
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let s0 = start ?? app.clampedPanelWidth
                        if start == nil { start = s0 }
                        app.panelWidth = s0 - v.translation.width
                    }
                    .onEnded { _ in
                        start = nil
                        app.panelWidth = app.clampedPanelWidth
                        UserDefaults.standard.set(Double(app.panelWidth), forKey: "panelWidth")
                    }
            )
            .padding(.horizontal, -3)
    }
}
