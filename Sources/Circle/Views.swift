import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CircleCore

enum Theme {
    static let bg = Color(nsColor: .textBackgroundColor)
    static let line = Color.primary.opacity(0.06)
    static let selection = Color.primary.opacity(0.075)
    static let dim = Color.primary.opacity(0.38)
    static let faint = Color.primary.opacity(0.22)
    static let font = Font.system(size: 13.5, design: .monospaced)
    static let small = Font.system(size: 11, design: .monospaced)
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focus: Field?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                InputLine(focus: $focus)
                Rectangle().fill(Theme.line).frame(height: 1)
                TodoList(focus: $focus)
                Rectangle().fill(Theme.line).frame(height: 1)
                StatusLine()
            }
            .frame(minWidth: 340)
            if app.panelOpen, let id = app.store.selection {
                Rectangle().fill(Theme.line).frame(width: 1)
                AgentPanel(todoID: id, focus: $focus)
                    .frame(minWidth: 300, idealWidth: 400)
            }
        }
        .font(Theme.font)
        .background(Theme.bg)
        .overlay(alignment: .top) {
            if app.paletteOpen { Palette(focus: $focus).padding(.top, 44) }
        }
        .overlay {
            if app.helpOpen { HelpOverlay().onTapGesture { app.helpOpen = false } }
        }
        .transaction { $0.animation = nil }   // nothing animates; everything is immediate
        .onAppear { app.openWindow = openWindow; applyFocus() }
        .onChange(of: app.focusRequest) { applyFocus() }
    }

    private func applyFocus() {
        guard let f = app.focusRequest else { return }
        focus = f
        app.focusRequest = nil
    }
}

// MARK: input

struct InputLine: View {
    @Environment(AppModel.self) private var app
    var focus: FocusState<Field?>.Binding
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(app.insertAfter == nil ? "+" : "↳").foregroundStyle(Theme.dim)
            TextField("", text: $draft, prompt: Text(placeholder).foregroundColor(Theme.faint))
                .textFieldStyle(.plain)
                .focused(focus, equals: .input)
                .onSubmit(submit)
                .onExitCommand { draft = ""; app.insertAfter = nil; focus.wrappedValue = .list }
                .onKeyPress(.downArrow) { focus.wrappedValue = .list; return .handled }
        }
        .padding(.leading, 16).padding(.trailing, 16)
        .padding(.top, 30).padding(.bottom, 12)   // clears the traffic lights
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = .input }
    }

    private var placeholder: String {
        if let a = app.insertAfter, let t = app.store.todo(a) { return "add below “\(t.title.prefix(30))”" }
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
                if store.ordered.isEmpty {
                    Text(store.logbook ? "nothing in the logbook yet. completed items land here the next day."
                         : store.hideDone ? "all clear. completed items hidden." : "nothing here. start typing.")
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 40)
                }
                if app.dropHint?.id == EndDrop.id {
                    Rectangle().fill(Color.accentColor).frame(height: 2).padding(.leading, 30)
                }
            }
            .scrollIndicators(.never)
            // Rows handle their own drops; anything that lands in the empty space below goes to the end.
            .onDrop(of: [.text], delegate: EndDrop(app: app))
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
        let s = app.store
        let sel = s.selection
        let cmd = k.modifiers.contains(.command)
        let opt = k.modifiers.contains(.option)

        switch k.key {
        case .downArrow: if opt, let id = sel { s.move(id, 1) } else { s.select(1) }; return .handled
        case .upArrow: if opt, let id = sel { s.move(id, -1) } else { s.select(-1) }; return .handled
        case .return:
            if cmd { app.runSelected() } else if sel != nil { app.editingID = sel; app.focusRequest = .edit }
            return .handled
        case .delete, .deleteForward:
            if let id = sel { s.delete(id) }; return .handled
        case .space:
            if let id = sel { s.toggle(id) }; return .handled
        case .tab:
            if let id = sel {
                if k.modifiers.contains(.shift) { s.outdent(id) } else { s.indent(id) }
            }
            return .handled
        case KeyEquivalent("\u{19}"):   // backtab
            if let id = sel { s.outdent(id) }
            return .handled
        case .leftArrow: s.left(); return .handled
        case .rightArrow: s.right(); return .handled
        case .escape:
            if app.panelOpen { app.panelOpen = false }
            else if app.helpOpen { app.helpOpen = false }
            else if s.logbook { s.logbook = false }
            else if s.filter != nil { s.filter = nil }
            else { s.selection = nil }
            return .handled
        case .home: s.selection = s.ordered.first?.id; return .handled
        case .end: s.selection = s.ordered.last?.id; return .handled
        default: break
        }
        if cmd {
            if k.characters == "z" { s.undo(); return .handled }
            return .ignored
        }
        if opt {
            switch k.key.character {
            case "1", "¡": s.filter = s.filter == .mine ? nil : .mine
            case "2", "™": s.filter = s.filter == .agent ? nil : .agent
            case "3", "£": s.filter = s.filter == .waiting ? nil : .waiting
            case "0", "º": s.filter = nil
            default: return .ignored
            }
            return .handled
        }
        switch k.characters {
        case "j": s.select(1)
        case "k": s.select(-1)
        case "J": if let id = sel { s.move(id, 1) }
        case "K": if let id = sel { s.move(id, -1) }
        case "g": s.selection = s.ordered.first?.id
        case "G": s.selection = s.ordered.last?.id
        case "x": if let id = sel { s.toggle(id) }
        case "e": if sel != nil { app.editingID = sel; app.focusRequest = .edit }
        case "d": if let id = sel { s.delete(id) }
        case "u": s.undo()
        case "o": app.focusInput(top: false)
        case "O", "a", "i", "n", "/": app.focusInput(top: true)
        case "r", "2": app.runSelected()
        case "1": if let id = sel { s.setKind(id, .mine) }
        case "3": if let id = sel { s.setKind(id, .waiting) }
        case "t": if let id = sel, let t = s.todo(id) { s.setKind(id, t.kind.next) }
        case "0": s.filter = nil
        case "c": if let id = sel { app.runner.cancel(id) }
        case "p": app.panelOpen.toggle()
        case "h": s.left()
        case "l": s.right()
        case "N": if sel != nil { app.panelOpen = true; app.focusRequest = .notes }
        case "L": s.logbook.toggle(); app.say(s.logbook ? "logbook · space restores · esc back" : "")
        case "H": s.hideDone.toggle(); app.say(s.hideDone ? "hiding completed" : "showing completed")
        case "?": app.helpOpen.toggle()
        default: return .ignored
        }
        return .handled
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
                    Text(todo.title)
                        .strikethrough(todo.done, color: Theme.faint)
                        .foregroundStyle(todo.done ? Theme.faint : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let p = store.progress[todo.id] {
                Text("\(p.done)/\(p.total)").font(Theme.small)
                    .foregroundStyle(p.done == p.total ? Theme.faint : Theme.dim)
            }
            if !todo.notes.isEmpty { Text("¶").foregroundStyle(Theme.faint) }
            if let run { RunBadge(run: run) }
            else if selected && !todo.done && !todo.isSection && app.editingID != todo.id, let a = app.registry.current {
                Text("r → \(a.id)").font(Theme.small).foregroundStyle(Theme.faint)
            }
        }
        .padding(.leading, 8).padding(.trailing, 16)
        .padding(.top, todo.isSection && level == 0 ? 14 : 5).padding(.bottom, 5)
        .background(selected ? Theme.selection : .clear)
        .overlay(alignment: app.dropHint?.after == true ? .bottom : .top) {
            if let h = app.dropHint, h.id == todo.id {
                Rectangle().fill(Color.accentColor).frame(height: 2)
                    .padding(.leading, 8 + CGFloat(level + (h.nest ? 1 : 0)) * 22 + 14)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { RowMenu(todo: todo) }
        .onTapGesture {
            app.store.selection = todo.id
            if NSApp.currentEvent?.clickCount == 2 { app.panelOpen = true; focus.wrappedValue = .list }
            else { focus.wrappedValue = .list }
        }
        .onDrag {
            app.draggingID = todo.id
            return NSItemProvider(object: todo.id as NSString)
        }
        .onDrop(of: [.text], delegate: RowDrop(target: todo, level: level, app: app))
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
            Text(abbreviate(reg.cwd)).lineLimit(1).truncationMode(.head)
            Text(reg.autonomy.rawValue)
            Spacer()
            if let f = app.flash, !f.isEmpty { Text(f).foregroundStyle(Color.primary.opacity(0.7)) }
            if app.store.logbook { Text("logbook").foregroundStyle(Color.primary) }
            ShapeCounts()
            HStack(spacing: 5) {
                Circle().fill(syncColor).frame(width: 6, height: 6)
                Text(app.store.syncState.label)
            }
        }
        .font(Theme.small)
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 16)
        .frame(height: 26)
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

    var body: some View {
        let todo = app.store.todo(todoID)
        let run = app.runner.run(for: todoID)
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .fontWeight(.semibold)
                .lineLimit(1...4)
                .focused(focus, equals: .title)
                .onSubmit { app.store.rename(todoID, title); focus.wrappedValue = .notes }
                .onExitCommand { title = todo?.title ?? ""; focus.wrappedValue = .list }
                .onChange(of: focus.wrappedValue) { old, new in
                    if old == .title && new != .title { app.store.rename(todoID, title) }
                }
                .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 8)
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("notes").foregroundStyle(Theme.faint).padding(.leading, 5)
                }
                TextEditor(text: $notes)
                    .scrollContentBackground(.hidden)
                    .focused(focus, equals: .notes)
                    .onExitCommand { focus.wrappedValue = .list }
            }
            .font(Theme.small)
            .frame(height: 64)
            .padding(.horizontal, 11)
            if todo?.isSection != true {
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
            } else {
                Spacer()
            }
        }
        .onAppear { load() }
        .onChange(of: todoID) { _, _ in load() }
        .onChange(of: notes) { _, v in
            if focus.wrappedValue == .notes { app.store.setNotes(todoID, v) }
        }
    }

    private func load() {
        title = app.store.todo(todoID)?.title ?? ""
        notes = app.store.todo(todoID)?.notes ?? ""
        app.runner.loadHistory(todoID)
    }
}

// MARK: help

struct HelpOverlay: View {
    private let rows: [(String, String)] = [
        ("type + ↩", "add todo (input stays focused)"),
        ("esc / ↓", "input → list"),
        ("j k  ↑ ↓", "move selection"),
        ("J K  ⌥↑ ⌥↓", "reorder"),
        ("space  x", "fill in (done)"),
        ("1  2  3", "○ mine  △ agent (runs it)  □ waiting"),
        ("t", "cycle shape"),
        ("⌥1 ⌥2 ⌥3", "show one shape   ⌥0 / esc all"),
        ("…@claude ↩", "add and hand straight to an agent"),
        ("↩  e", "edit title"),
        ("o", "add below selection"),
        ("a  n  /", "add at top"),
        ("d  ⌫", "delete      u  ⌘z  undo"),
        ("r  ⌘↩", "hand selected todo to the agent"),
        ("c", "cancel run"),
        ("tab  ⇧tab", "nest under item above / un-nest"),
        ("← →  h l", "collapse / expand, jump to parent"),
        ("dbl-click  p", "details: title, notes, agent output"),
        ("drag", "reorder · drop on right half to nest"),
        ("# name ↩", "add a section header"),
        ("L", "logbook: completed before today"),
        ("N", "edit notes"),
        ("H", "hide / show completed"),
        ("⌘k", "palette: agent, model, folder, autonomy"),
        ("⌃⌥space", "summon Circle from anywhere"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                HStack(spacing: 0) {
                    Text(r.0).frame(width: 130, alignment: .leading).foregroundStyle(.primary)
                    Text(r.1).foregroundStyle(Theme.dim)
                }
            }
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
        Button(todo.done ? "Mark Not Done" : "Mark Done") { app.store.toggle(todo.id) }
        Divider()
        if let a = app.registry.current {
            Button("△  Hand to \(a.id) · \(app.registry.model)") { app.store.selection = todo.id; app.handToAgent(todo.id) }
        }
        Button("○  Mine") { app.store.setKind(todo.id, .mine) }
        Button("□  Waiting") { app.store.setKind(todo.id, .waiting) }
        Divider()
        Button("Nest Under Item Above") { app.store.indent(todo.id) }
        Button("Un-nest") { app.store.outdent(todo.id) }
        Divider()
        Button("Edit") { app.store.selection = todo.id; app.editingID = todo.id; app.focusRequest = .edit }
        Button("Delete") { app.store.delete(todo.id) }
    }
}


// MARK: drag and drop

struct RowDrop: DropDelegate {
    let target: Todo
    let level: Int
    let app: AppModel

    private func hint(_ info: DropInfo) -> DropHint {
        let rowHeight: CGFloat = target.isSection && level == 0 ? 36 : 27
        let after = info.location.y > rowHeight / 2
        // Dragging well right of the title start on the lower half nests under this row.
        let titleStart = 8 + CGFloat(level) * 22 + 34
        let nest = after && app.store.filter == nil && !app.store.logbook && info.location.x > titleStart + 60
        return DropHint(id: target.id, after: after, nest: nest)
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let id = app.draggingID else { return false }
        return id != target.id && !app.store.logbook
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let h = hint(info)
        if app.dropHint != h { app.dropHint = h }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if app.dropHint?.id == target.id { app.dropHint = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { app.dropHint = nil; app.draggingID = nil }
        guard let id = app.draggingID, id != target.id else { return false }
        let h = hint(info)
        if h.nest { app.store.nest(id, under: target.id) }
        else { app.store.place(id, relativeTo: target.id, after: h.after) }
        return true
    }
}


/// Drop target for the empty area below the last row.
struct EndDrop: DropDelegate {
    static let id = "__end__"
    let app: AppModel

    func validateDrop(info: DropInfo) -> Bool { app.draggingID != nil && !app.store.logbook }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if app.dropHint?.id != Self.id { app.dropHint = DropHint(id: Self.id, after: false, nest: false) }
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if app.dropHint?.id == Self.id { app.dropHint = nil } }
    func performDrop(info: DropInfo) -> Bool {
        defer { app.dropHint = nil; app.draggingID = nil }
        guard let id = app.draggingID else { return false }
        app.store.moveToEnd(id)
        return true
    }
}
