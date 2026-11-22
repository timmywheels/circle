import AppKit
import SwiftUI
import CircleCore

extension NSAttributedString.Key {
    /// The todo a line of the list buffer belongs to (set on every character, newline included).
    static let todoID = NSAttributedString.Key("circleTodoID")
}

/// The list as one editable text buffer, Zed style: every line is a todo. Typing edits it,
/// ↩ splits, ⌫ joins, tab nests, selections and copy/paste span lines. Shapes, folds and
/// badges are drawn in the margins, so the text is only ever the titles.
struct ListBuffer: NSViewRepresentable {
    let app: AppModel
    // Read in the parent's body, so SwiftUI calls updateNSView whenever any of them change.
    let revision: Int
    let selection: String?
    let focusToken: Int
    let caretToken: Int
    let dropHint: DropHint?
    let runsKey: String
    let styleKey: String
    let editable: Bool
    let panelOpen: Bool

    func makeCoordinator() -> BufferController { BufferController(app: app) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)

        // Start at the clip view's size (zero here) so autoresizing keeps the text exactly as wide as the view.
        let tv = BufferTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: tc)
        tv.controller = c
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 0, height: BufferController.topInset)
        tv.insertionPointColor = .controlAccentColor
        tv.delegate = c
        scroll.documentView = tv
        c.textView = tv
        c.update(self, first: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let tv = scroll.documentView, abs(tv.frame.width - scroll.contentSize.width) > 0.5 {
            tv.setFrameSize(NSSize(width: scroll.contentSize.width, height: tv.frame.height))
        }
        context.coordinator.update(self, first: false)
    }
}

@MainActor
final class BufferController: NSObject, NSTextViewDelegate {
    static let topInset: CGFloat = 34
    static let indentStep: CGFloat = 22

    let app: AppModel
    weak var textView: BufferTextView?
    var store: Store { app.store }

    struct LineInfo {
        var todo: Todo
        var depth: Int
        var hasKids: Bool
        var collapsed: Bool
        var meta: NSAttributedString?
        var running: Bool
    }

    /// Per todo id, everything the margins need.
    private(set) var info: [String: LineInfo] = [:]
    /// Line order as last rendered (or reconciled).
    private(set) var renderedIDs: [String] = []
    /// The id of a blank last line (it has no characters to carry the id attribute).
    private var tailID: String?
    private var signature = ""
    private var knownRevision = -1
    private var lastFocusToken = 0, lastCaretToken = 0
    private var styleKey = ""
    private var runsKey = ""
    private var applying = false
    /// The line the caret is on, and its title when the caret arrived (for link rewrites).
    private(set) var caretID: String?
    private var titleOnEnter = ""
    var completing = false
    var editable = true

    init(app: AppModel) { self.app = app }

    // MARK: fonts and geometry

    var fontSize: CGFloat { CGFloat(Settings.shared.fontSize) }
    var font: NSFont { Fonts.ns(size: fontSize) }
    var smallFont: NSFont { Fonts.ns(size: max(9, fontSize - 2.5)) }
    var sectionFont: NSFont { Fonts.bolder(size: max(9, fontSize - 1.5)) }
    var glyphWidth: CGFloat { ("○" as NSString).size(withAttributes: [.font: font]).width }

    /// Where a line's title starts (same numbers the drag-and-drop code uses).
    func textX(depth: Int, section: Bool) -> CGFloat {
        let x = 8 + CGFloat(depth) * Self.indentStep + 34
        return section ? x - glyphWidth - 10 : x
    }
    func glyphX(depth: Int) -> CGFloat { textX(depth: depth, section: false) - 10 - glyphWidth }
    func chevronX(depth: Int) -> CGFloat { glyphX(depth: depth) - 14 }

    static let label = NSColor.labelColor
    static var dim: NSColor { NSColor.labelColor.withAlphaComponent(0.38) }
    static var faint: NSColor { NSColor.labelColor.withAlphaComponent(0.24) }

    // MARK: SwiftUI -> buffer

    func update(_ v: ListBuffer, first: Bool) {
        guard let tv = textView else { return }
        editable = v.editable
        tv.isEditable = v.editable
        tv.isSelectable = true
        if first || v.styleKey != styleKey {
            styleKey = v.styleKey
            runsKey = v.runsKey
            render(force: true)
        } else if v.revision != knownRevision || v.runsKey != runsKey {
            runsKey = v.runsKey
            render(force: false)
        }
        if v.caretToken != lastCaretToken {
            lastCaretToken = v.caretToken
            if let r = app.caretRequest { app.caretRequest = nil; placeCaret(on: r.id, column: r.column) }
        } else if let s = v.selection, s != caretID, !applying, renderedIDs.contains(s) {
            placeCaret(on: s, column: nil)
        }
        if v.focusToken != lastFocusToken || first {
            lastFocusToken = v.focusToken
            DispatchQueue.main.async { [weak tv] in
                guard let tv, let w = tv.window else { return }
                w.makeFirstResponder(tv)
            }
        }
        tv.needsDisplay = true
    }

    // MARK: rendering

    private func meta(for t: Todo) -> NSAttributedString? {
        var parts: [(String, NSColor)] = []
        if t.remindAt > 0 && !t.done {
            let overdue = t.remindAt < Int64(Date().timeIntervalSince1970 * 1000)
            parts.append(((t.repeatRule.isEmpty ? "" : "↻ ") + When.short(t.remindAt), overdue ? .controlAccentColor : Self.dim))
        }
        if let p = store.progress[t.id] { parts.append(("\(p.done)/\(p.total)", p.done == p.total ? Self.faint : Self.dim)) }
        if !t.notes.isEmpty { parts.append(("¶", Self.faint)) }
        if store.logbook {
            parts.append((Date(timeIntervalSince1970: Double(t.completedAt) / 1000).formatted(.dateTime.month(.abbreviated).day().hour().minute()), Self.faint))
        }
        if let run = app.runner.run(for: t.id) {
            switch run.status {
            case .running: parts.append(("● \(run.agent)", .controlAccentColor))
            case .failed: parts.append(("✕ \(run.agent)", NSColor.systemRed.withAlphaComponent(0.75)))
            case .cancelled: parts.append(("– \(run.agent)", Self.faint))
            case .done: parts.append((run.agent, Self.faint))
            }
        }
        guard !parts.isEmpty else { return nil }
        let out = NSMutableAttributedString()
        for (i, p) in parts.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "  ", attributes: [.font: smallFont])) }
            out.append(NSAttributedString(string: p.0, attributes: [.font: smallFont, .foregroundColor: p.1]))
        }
        return out
    }

    /// Recomputes margin info from the store and returns a signature of what the text depends on.
    private func refreshInfo() -> String {
        var next: [String: LineInfo] = [:]
        var sig = ""
        sig.reserveCapacity(store.ordered.count * 24)
        for t in store.ordered {
            let d = store.filter == nil && !store.logbook ? (store.depth[t.id] ?? 0) : 0
            let kids = store.filter == nil && !store.logbook && store.hasChildren(t.id)
            let m = meta(for: t)
            next[t.id] = LineInfo(todo: t, depth: d, hasKids: kids, collapsed: store.collapsed.contains(t.id),
                                  meta: m, running: app.runner.run(for: t.id)?.status == .running)
            sig += t.id; sig += "\u{1}"; sig += t.title; sig += "\u{1}\(d)\(t.done ? 1 : 0)\(m?.length ?? 0)\u{2}"
        }
        info = next
        knownRevision = store.revision
        return sig
    }

    /// Full paragraph attributes for one line (text, indent, id, link styling).
    private func style(_ s: NSMutableAttributedString, range r: NSRange, id: String, first: Bool) {
        guard let li = info[id] else { return }
        let t = li.todo
        let p = NSMutableParagraphStyle()
        let x = textX(depth: li.depth, section: t.isSection)
        p.firstLineHeadIndent = x
        p.headIndent = x
        let mw = li.meta.map { $0.size().width + 14 } ?? 0
        p.tailIndent = -(16 + mw)
        p.lineSpacing = 2
        p.paragraphSpacingBefore = t.isSection && li.depth == 0 && !first ? 15 : 5
        p.paragraphSpacing = 5
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: t.done ? Self.faint : Self.label,
                                                    .paragraphStyle: p, .todoID: id]
        if t.done { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; attrs[.strikethroughColor] = Self.faint }
        if t.isSection { attrs[.font] = sectionFont; attrs[.foregroundColor] = Self.dim; attrs[.kern] = 0.6 }
        s.setAttributes(attrs, range: r)
        let text = s.string as NSString
        if t.isSection, r.length >= 2, text.substring(with: NSRange(location: r.location, length: 2)) == "# " {
            s.addAttribute(.foregroundColor, value: Self.faint, range: NSRange(location: r.location, length: 2))
        }
        // [[links]]: name in the accent color, brackets quiet, click follows.
        let line = text.substring(with: r)
        guard line.contains("[[") else { return }
        let re = Self.linkRE
        for m in re.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            let name = (line as NSString).substring(with: m.range(at: 1))
            let whole = NSRange(location: r.location + m.range.location, length: m.range.length)
            let inner = NSRange(location: r.location + m.range(at: 1).location, length: m.range(at: 1).length)
            s.addAttribute(.foregroundColor, value: Self.faint, range: whole)
            let exists = store.resolve(name) != nil
            s.addAttributes([.foregroundColor: t.done ? Self.faint : (exists ? NSColor.controlAccentColor : Self.dim),
                             .circleLink: "wiki:" + name], range: inner)
        }
    }

    private static let linkRE = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#)

    /// Rebuilds the text from the store when the lines changed shape; otherwise just repaints.
    func render(force: Bool) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let sig = refreshInfo()
        let rows = store.ordered
        tailID = rows.last.flatMap { $0.title.isEmpty ? $0.id : nil }
        if !force && sig == signature {
            renderedIDs = rows.map(\.id)
            tv.needsDisplay = true
            return
        }
        signature = sig
        let keep = captureSelection()
        let out = NSMutableAttributedString()
        for (i, t) in rows.enumerated() {
            let start = out.length
            out.append(NSAttributedString(string: t.title))
            if i < rows.count - 1 { out.append(NSAttributedString(string: "\n")) }
            style(out, range: NSRange(location: start, length: out.length - start), id: t.id, first: i == 0)
        }
        applying = true
        ts.setAttributedString(out)
        tv.localUndo.removeAllActions()
        renderedIDs = rows.map(\.id)
        restoreSelection(keep)
        applying = false
        updateTyping()
        tv.needsDisplay = true
    }

    // MARK: lines

    struct Line { var range: NSRange; var id: String? }

    /// Every line of the buffer, a trailing empty one included.
    func lines() -> [Line] {
        guard let ts = textView?.textStorage else { return [] }
        let s = ts.string as NSString
        let n = s.length
        var out: [Line] = []
        var start = 0
        var i = 0
        while i <= n {
            if i == n || s.character(at: i) == 10 {
                let r = NSRange(location: start, length: i - start)
                var id: String?
                if r.length > 0 { id = ts.attribute(.todoID, at: r.location, effectiveRange: nil) as? String }
                else if i < n { id = ts.attribute(.todoID, at: i, effectiveRange: nil) as? String }
                else { id = tailID }
                out.append(Line(range: r, id: id))
                start = i + 1
            }
            i += 1
        }
        return out
    }

    func lineIndex(at loc: Int, in ls: [Line]) -> Int? {
        ls.firstIndex { loc >= $0.range.location && loc <= $0.range.location + $0.range.length }
    }

    func caretLine() -> (index: Int, line: Line, column: Int)? {
        guard let tv = textView else { return nil }
        let ls = lines()
        let loc = tv.selectedRange().location
        guard let i = lineIndex(at: loc, in: ls) else { return nil }
        return (i, ls[i], loc - ls[i].range.location)
    }

    /// Ids of every line the selection touches (the caret line when nothing is selected).
    func selectedIDs() -> [String] {
        guard let tv = textView else { return [] }
        let ls = lines()
        let sel = tv.selectedRange()
        guard let a = lineIndex(at: sel.location, in: ls), let b = lineIndex(at: sel.location + sel.length, in: ls) else { return [] }
        var hi = b
        // A selection ending at the very start of a line doesn't include that line.
        if b > a && sel.location + sel.length == ls[b].range.location { hi = b - 1 }
        return ls[a...hi].compactMap(\.id)
    }

    private struct Kept { var caret: (String, Int)?; var anchor: (String, Int)? }

    private func captureSelection() -> Kept {
        guard let tv = textView else { return Kept() }
        let ls = lines()
        let sel = tv.selectedRange()
        func at(_ loc: Int) -> (String, Int)? {
            guard let i = lineIndex(at: loc, in: ls), let id = ls[i].id else { return nil }
            return (id, loc - ls[i].range.location)
        }
        return Kept(caret: at(sel.location + sel.length), anchor: at(sel.location))
    }

    private func restoreSelection(_ k: Kept) {
        guard let tv = textView else { return }
        let ls = lines()
        func loc(_ p: (String, Int)?) -> Int? {
            guard let p, let i = renderedIDs.firstIndex(of: p.0), i < ls.count else { return nil }
            return ls[i].range.location + min(p.1, ls[i].range.length)
        }
        if let c = loc(k.caret) {
            let a = loc(k.anchor) ?? c
            tv.setSelectedRange(NSRange(location: min(a, c), length: abs(c - a)))
        } else if let s = store.selection, let i = renderedIDs.firstIndex(of: s), i < ls.count {
            tv.setSelectedRange(NSRange(location: ls[i].range.location + ls[i].range.length, length: 0))
        }
    }

    /// Puts the caret on a todo's line (end of line unless a column is given) and scrolls to it.
    func placeCaret(on id: String, column: Int?) {
        guard let tv = textView else { return }
        let ls = lines()
        guard let i = renderedIDs.firstIndex(of: id), i < ls.count else { return }
        let r = ls[i].range
        let loc = r.location + min(column ?? r.length, r.length)
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        tv.scrollRangeToVisible(NSRange(location: loc, length: 0))
    }

    /// Typed text takes the caret line's attributes (an empty line carries them on its newline).
    private func updateTyping() {
        guard let tv = textView, let c = caretLine(), let id = c.line.id, info[id] != nil else { return }
        let tmp = NSMutableAttributedString(string: " ")
        style(tmp, range: NSRange(location: 0, length: 1), id: id, first: c.index == 0)
        var a = tmp.attributes(at: 0, effectiveRange: nil)
        a[.circleLink] = nil
        tv.typingAttributes = a
    }

    // MARK: edits -> store

    func textDidChange(_ notification: Notification) {
        guard !applying else { return }
        reconcile()
        checkCompletion()
    }

    /// Reads the buffer back into todos: renamed lines, new lines, removed or joined lines.
    func reconcile() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let ls = lines()
        // Where each id's characters ended up (a joined line leaves its chars on the line above).
        var foundIn: [String: Int] = [:]
        for (i, l) in ls.enumerated() where l.range.length > 0 {
            ts.enumerateAttribute(.todoID, in: l.range) { v, _, _ in
                if let v = v as? String, foundIn[v] == nil { foundIn[v] = i }
            }
        }
        var seen = Set<String>()
        var ids: [String] = []
        var structural = false
        var prev: String?
        let s = ts.string as NSString
        for l in ls {
            let text = s.substring(with: l.range)
            var id = l.id
            if let x = id, seen.contains(x) || store.todo(x)?.deleted != false { id = nil }
            if let x = id, let t = store.todo(x) {
                seen.insert(x)
                if t.title != text {
                    if t.isSection != text.hasPrefix("# ") { structural = true }
                    store.setTitle(x, text)
                }
            } else {
                let t = store.insertLine(after: prev, title: text, undoable: false)
                seen.insert(t.id)
                id = t.id
                structural = true
            }
            ids.append(id!)
            prev = id
        }
        for r in renderedIDs.reversed() where !seen.contains(r) {
            if let i = foundIn[r], i < ids.count { store.removeLine(r, mergeInto: ids[i]) } else { store.removeLine(r) }
            structural = true
        }
        if structural {
            let caret = caretLine()
            let want = caret.map { (ids[min($0.index, ids.count - 1)], $0.column) }
            render(force: true)
            if let w = want { placeCaret(on: w.0, column: w.1) }
        } else {
            renderedIDs = ids
            signature = refreshInfo()
            // Restyle the edited line so links and the section marker update as you type.
            if let c = caretLine(), let id = c.line.id {
                applying = true
                let full = NSRange(location: c.line.range.location, length: min(c.line.range.length + 1, ts.length - c.line.range.location))
                ts.beginEditing()
                style(ts, range: full, id: id, first: c.index == 0)
                ts.endEditing()
                applying = false
            }
        }
        syncSelection()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applying else { return }
        syncSelection()
        textView?.needsDisplay = true
    }

    /// The caret line drives the store's selection (and so the details panel).
    private func syncSelection() {
        updateTyping()
        let id = caretLine()?.line.id
        guard id != caretID else { return }
        let old = caretID
        let oldTitle = titleOnEnter
        caretID = id
        titleOnEnter = id.flatMap { store.todo($0)?.title } ?? ""
        if let id, store.selection != id { store.selection = id }
        if let old { DispatchQueue.main.async { [weak self] in self?.left(old, titleWas: oldTitle) } }
    }

    /// The caret left a line: blank lines go away, renamed ones fix links pointing at them.
    private func left(_ id: String, titleWas: String) {
        guard let t = store.todo(id), !t.deleted, id != caretID else { return }
        if Store.isBlank(t.title) {
            store.removeLine(id, undoable: false)
            render(force: true)
        } else if t.title != titleWas {
            store.rewriteLinks(id, from: titleWas)
        }
    }

    // MARK: commands from the text view

    /// ↩: split the line at the caret (the rest becomes the next todo).
    func newline() -> Bool {
        guard editable, let tv = textView else { return false }
        if tv.selectedRange().length > 0 { tv.insertText("", replacementRange: tv.selectedRange()) }
        guard let c = caretLine(), let id = c.line.id, let t = store.todo(id) else {
            let n = store.insertLine(after: nil)
            render(force: true); placeCaret(on: n.id, column: 0)
            return true
        }
        let text = (tv.string as NSString).substring(with: c.line.range)
        let depth = info[id]?.depth ?? 0
        // ↩ on an empty nested line steps it out a level instead.
        if Store.isBlank(text) && depth > 0 && store.filter == nil {
            store.outdent(id)
            render(force: true); placeCaret(on: id, column: (text as NSString).length)
            return true
        }
        if c.column == 0 && !text.isEmpty {
            if let n = store.insertLine(before: id) { render(force: true); _ = n; placeCaret(on: id, column: 0) }
            return true
        }
        var head = (text as NSString).substring(to: c.column)
        let tail = (text as NSString).substring(from: c.column)
        if tail.isEmpty { head = app.applyLineCommands(id, head) }
        if head != t.title { store.setTitle(id, head) }
        let n = store.insertLine(after: id, title: tail)
        if head != titleOnEnter { store.rewriteLinks(id, from: titleOnEnter); titleOnEnter = head }
        render(force: true)
        placeCaret(on: n.id, column: 0)
        return true
    }

    /// Chords from keymap.json (anything with ⌘ ⌥ ⌃, and tab). Returns true when handled.
    func handleKey(_ e: NSEvent) -> Bool {
        guard let a = app.keymap.action(for: e), Chord.from(e).contains(where: Action.isCommandChord) else { return false }
        perform(a)
        return true
    }

    func perform(_ a: Action) {
        let ids = selectedIDs()
        switch a {
        case .indent: guard editable else { return }; for id in ids { store.indent(id) }
        case .outdent: guard editable else { return }; for id in ids.reversed() { store.outdent(id) }
        case .moveUp: guard editable else { return }; for id in ids { store.move(id, -1) }
        case .moveDown: guard editable else { return }; for id in ids.reversed() { store.move(id, 1) }
        case .toggle:
            let open = ids.contains { store.todo($0)?.done == false }
            if ids.count == 1, let id = ids.first { store.toggle(id) } else { for id in ids { store.setDone(id, open) } }
        case .delete:
            guard editable else { return }
            let next = nextLine(after: ids)
            for id in ids.reversed() { store.removeLine(id) }
            render(force: true)
            if let n = next { placeCaret(on: n, column: nil) }
            return
        case .shapeMine: for id in ids { store.setKind(id, .mine) }
        case .shapeWaiting: for id in ids { store.setKind(id, .waiting) }
        case .collapse:
            if let id = caretID, store.hasChildren(id) { store.setCollapsed(id, true) }
            else if let id = caretID, let t = store.todo(id), !t.parent.isEmpty, renderedIDs.contains(t.parent) {
                store.setCollapsed(t.parent, true); render(force: true); placeCaret(on: t.parent, column: nil); return
            }
        case .expand: if let id = caretID { store.setCollapsed(id, false) }
        default:
            app.perform(a)
            return
        }
        render(force: false)
        if let tv = textView { tv.scrollRangeToVisible(tv.selectedRange()) }
    }

    private func nextLine(after ids: [String]) -> String? {
        guard let last = ids.last, let i = renderedIDs.firstIndex(of: last) else { return nil }
        let gone = Set(ids)
        return renderedIDs[(i + 1)...].first { !gone.contains($0) } ?? renderedIDs[..<i].last { !gone.contains($0) }
    }

    func toggleDone(_ id: String) { store.toggle(id) }
    func toggleCollapse(_ id: String) { store.setCollapsed(id, !store.collapsed.contains(id)) }

    // MARK: copy / paste whole lines as a markdown list

    /// Multi-line copy: the lines (and anything folded under them) as "- [ ] title" markdown.
    func copyLines() -> Bool {
        guard let tv = textView, tv.selectedRange().length > 0,
              (tv.string as NSString).substring(with: tv.selectedRange()).contains("\n") else { return false }
        let ids = selectedIDs()
        guard !ids.isEmpty else { return false }
        let base = ids.compactMap { info[$0]?.depth }.min() ?? 0
        var out: [String] = []
        func emit(_ t: Todo, _ level: Int) {
            let pad = String(repeating: "  ", count: max(0, level))
            out.append(t.isSection ? pad + t.title : pad + (t.done ? "- [x] " : "- [ ] ") + t.title)
            if store.collapsed.contains(t.id) { for c in store.children(t.id) where !c.deleted { emit(c, level + 1) } }
        }
        for id in ids { if let li = info[id] { emit(li.todo, li.depth - base) } }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(out.joined(separator: "\n"), forType: .string)
        return true
    }

    func deleteSelectedLines() {
        let ids = selectedIDs()
        let next = nextLine(after: ids)
        for id in ids.reversed() { store.removeLine(id) }
        render(force: true)
        if let n = next { placeCaret(on: n, column: nil) }
    }

    private static let itemRE = try! NSRegularExpression(pattern: #"^(?:[-*+]|\d{1,3}[.)])\s+(?:\[([ xX])\]\s+)?"#)

    /// Pasting several lines makes several todos; indentation nests them.
    func paste() -> Bool {
        guard editable, let raw = NSPasteboard.general.string(forType: .string), raw.contains("\n") else { return false }
        var items: [(level: Int, title: String, done: Bool)] = []
        var unit = Int.max
        let rows = raw.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var indents: [Int] = []
        for row in rows {
            var spaces = 0
            for ch in row { if ch == " " { spaces += 1 } else if ch == "\t" { spaces += 4 } else { break } }
            let body = row.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            var title = body, done = false
            let ns = body as NSString
            if let m = Self.itemRE.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
                if m.range(at: 1).location != NSNotFound { done = ns.substring(with: m.range(at: 1)).lowercased() == "x" }
                title = ns.substring(from: m.range.length)
            }
            if spaces > 0 { unit = min(unit, spaces) }
            indents.append(spaces)
            items.append((0, title, done))
        }
        guard !items.isEmpty else { return false }
        let minIndent = indents.min() ?? 0
        if unit == .max { unit = 2 }
        for i in items.indices { items[i].level = max(0, (indents[i] - minIndent) / max(1, unit)) }

        var anchor = caretLine()?.line.id
        var lastAt: [Int: String] = [:]
        var lastID: String?
        for (k, it) in items.enumerated() {
            var t: Todo?
            if k == 0, let a = anchor, let cur = store.todo(a), Store.isBlank(cur.title) {
                store.setTitle(a, it.title); t = store.todo(a)
            } else if it.level == 0 || lastAt[it.level - 1] == nil {
                t = store.insertLine(after: lastAt[0] ?? anchor, title: it.title, firstChildIfOpen: false, undoable: false)
            } else if let parent = lastAt[it.level - 1] {
                t = store.appendChild(parent, title: it.title)
            }
            guard let made = t else { continue }
            if it.done { store.setDone(made.id, true) }
            lastAt[it.level] = made.id
            for deeper in lastAt.keys where deeper > it.level { lastAt[deeper] = nil }
            if it.level == 0 { anchor = made.id }
            lastID = made.id
        }
        render(force: true)
        if let l = lastID { placeCaret(on: l, column: nil) }
        return true
    }

    // MARK: [[ completion

    private var openLinkRange: NSRange? {
        guard let tv = textView, let c = caretLine(), tv.selectedRange().length == 0 else { return nil }
        let s = tv.string as NSString
        let before = s.substring(with: NSRange(location: c.line.range.location, length: c.column))
        guard let r = before.range(of: "[[", options: .backwards) else { return nil }
        let rest = before[r.upperBound...]
        guard !rest.contains("]]") else { return nil }
        let start = c.line.range.location + (before as NSString).range(of: "[[", options: .backwards).location + 2
        return NSRange(location: start, length: tv.selectedRange().location - start)
    }

    private func checkCompletion() {
        guard let tv = textView else { return }
        if openLinkRange == nil { completing = false; return }
        guard !completing else { return }
        completing = true
        DispatchQueue.main.async { [weak tv] in tv?.complete(nil) }
    }

    func completionRange() -> NSRange? { openLinkRange }

    func completions(for r: NSRange) -> [String] {
        guard let tv = textView else { return [] }
        let q = (tv.string as NSString).substring(with: r)
        let out = store.suggestions(q, limit: 8).map(\.displayTitle).filter { !$0.isEmpty }
        if out.isEmpty { completing = false }
        return out
    }

    // MARK: hit testing for the margins

    enum Zone { case chevron(String), glyph(String), meta(String), link(String), text }

    /// The rect a line occupies (every wrapped fragment, spacing included), in view coordinates.
    func rect(for l: Line) -> NSRect? {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let ts = tv.textStorage else { return nil }
        let o = tv.textContainerOrigin
        let n = ts.length
        if l.range.location >= n && l.range.length == 0 {
            // Trailing empty line: the extra line fragment.
            let r = lm.extraLineFragmentRect
            return r.isEmpty ? nil : r.offsetBy(dx: o.x, dy: o.y)
        }
        let chars = NSRange(location: l.range.location, length: min(l.range.length + 1, n - l.range.location))
        let glyphs = lm.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
        var out = NSRect.null
        lm.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in out = out.union(rect) }
        _ = tc
        return out.isNull ? nil : out.offsetBy(dx: o.x, dy: o.y)
    }

    /// Baseline of a line's first row, in view coordinates.
    func baseline(for l: Line) -> CGFloat? {
        guard let tv = textView, let lm = tv.layoutManager, let ts = tv.textStorage else { return nil }
        let o = tv.textContainerOrigin
        if l.range.location >= ts.length {
            let r = lm.extraLineFragmentRect
            guard !r.isEmpty else { return nil }
            return r.minY + o.y + 5 + font.ascender
        }
        let gi = lm.glyphIndexForCharacter(at: l.range.location)
        let frag = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
        return frag.minY + lm.location(forGlyphAt: gi).y + o.y
    }

    func hit(_ p: NSPoint) -> Zone {
        guard let tv = textView else { return .text }
        for l in lines() {
            guard let id = l.id, let li = info[id], let r = rect(for: l), p.y >= r.minY, p.y < r.maxY else { continue }
            let gx = glyphX(depth: li.depth)
            if li.hasKids, p.x >= chevronX(depth: li.depth) - 4, p.x < gx - 2 { return .chevron(id) }
            if !li.todo.isSection, p.x >= gx - 5, p.x < gx + glyphWidth + 5 { return .glyph(id) }
            if let m = li.meta, p.x > tv.bounds.width - 16 - m.size().width - 8 { return .meta(id) }
            if let lm = tv.layoutManager, let tc = tv.textContainer, let ts = tv.textStorage, ts.length > 0 {
                let o = tv.textContainerOrigin
                let pt = NSPoint(x: p.x - o.x, y: p.y - o.y)
                var frac: CGFloat = 0
                let gi = lm.glyphIndex(for: pt, in: tc, fractionOfDistanceThroughGlyph: &frac)
                if lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tc).contains(pt) {
                    let ci = lm.characterIndexForGlyph(at: gi)
                    if ci < ts.length, let link = ts.attribute(.circleLink, at: ci, effectiveRange: nil) as? String {
                        return .link(link)
                    }
                }
            }
            return .text
        }
        return .text
    }

    /// Row frames for the drag-and-drop code (same coordinate space as the mouse points we pass it).
    func publishFrames() {
        var frames: [String: CGRect] = [:]
        for l in lines() { if let id = l.id, let r = rect(for: l) { frames[id] = r } }
        app.rowFrames = frames
    }

    var placeholder: String {
        if store.logbook { return "nothing in the logbook yet. completed items land here the next day." }
        if store.hideDone && !store.allLive.isEmpty { return "all clear. completed items hidden." }
        return "start typing. ↩ new line · # section · [[ link · ⌘K commands"
    }

    func contextMenu(for id: String) -> NSMenu {
        let m = NSMenu()
        guard let t = store.todo(id) else { return m }
        func item(_ title: String, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, action: action)
            m.addItem(i)
        }
        if !t.isSection {
            item(t.done ? "Mark Not Done" : "Mark Done") { [weak self] in self?.store.toggle(id) }
            item("Open Details") { [weak self] in self?.store.selection = id; self?.app.panelOpen = true }
            m.addItem(.separator())
            if let a = app.registry.current {
                item("△  Hand to \(a.id) · \(app.registry.model)") { [weak self] in self?.app.handToAgent(id) }
            }
            item("○  Mine") { [weak self] in self?.store.setKind(id, .mine) }
            item("□  Waiting") { [weak self] in self?.store.setKind(id, .waiting) }
            m.addItem(.separator())
            let remind = NSMenu()
            for (label, phrase) in RowMenu.presets {
                remind.addItem(ClosureMenuItem(title: label) { [weak self] in
                    guard let self, let p = When.parse(phrase, defaultHour: Settings.shared.reminderHour) else { return }
                    let ms = Int64(p.date.timeIntervalSince1970 * 1000)
                    self.store.setReminder(id, at: ms, rule: t.repeatRule)
                    self.app.say("remind " + When.long(ms, rule: t.repeatRule))
                })
            }
            remind.addItem(.separator())
            remind.addItem(ClosureMenuItem(title: "Custom…") { [weak self] in self?.store.selection = id; self?.app.perform(.remind) })
            if t.remindAt > 0 {
                remind.addItem(ClosureMenuItem(title: "Clear Reminder") { [weak self] in self?.store.setReminder(id, at: 0, rule: "") })
            }
            let r = NSMenuItem(title: t.remindAt > 0 ? "Remind · \(When.short(t.remindAt))" : "Remind", action: nil, keyEquivalent: "")
            r.submenu = remind
            m.addItem(r)
            m.addItem(.separator())
        }
        item("Copy as [[link]]") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("[[\(t.displayTitle)]]", forType: .string)
        }
        m.addItem(.separator())
        item(t.isSection ? "Delete Section" : "Delete") { [weak self] in
            guard let self else { return }
            self.store.removeLine(id); self.render(force: true)
        }
        return m
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// The text view behind the buffer: draws the margins, routes chords, and handles
/// the line-level parts of editing (↩, copy/paste of lines, clicks on shapes).
final class BufferTextView: NSTextView {
    weak var controller: BufferController?
    let localUndo = UndoManager()

    override var undoManager: UndoManager? { localUndo }

    override func keyDown(with e: NSEvent) {
        if let c = controller, MainActor.assumeIsolated({ c.handleKey(e) }) { return }
        super.keyDown(with: e)
    }

    override func insertNewline(_ sender: Any?) {
        if let c = controller, MainActor.assumeIsolated({ c.newline() }) { return }
        super.insertNewline(sender)
    }
    override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }

    override func insertTab(_ sender: Any?) {
        if let c = controller { MainActor.assumeIsolated { c.perform(.indent) } }
    }
    override func insertBacktab(_ sender: Any?) {
        if let c = controller { MainActor.assumeIsolated { c.perform(.outdent) } }
    }

    override func cancelOperation(_ sender: Any?) {
        if let c = controller { MainActor.assumeIsolated { c.app.escape() } }
    }

    override func paste(_ sender: Any?) {
        if let c = controller, MainActor.assumeIsolated({ c.paste() }) { return }
        pasteAsPlainText(sender)
    }

    override func copy(_ sender: Any?) {
        if let c = controller, MainActor.assumeIsolated({ c.copyLines() }) { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if let c = controller, MainActor.assumeIsolated({ c.copyLines() }) {
            MainActor.assumeIsolated { c.deleteSelectedLines() }
            return
        }
        super.cut(sender)
    }

    @objc func undo(_ sender: Any?) {
        if localUndo.canUndo { localUndo.undo(); return }
        if let c = controller { MainActor.assumeIsolated { c.store.undo(); c.render(force: true) } }
    }

    @objc func redo(_ sender: Any?) {
        if localUndo.canRedo { localUndo.redo() }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let c = controller { MainActor.assumeIsolated { c.app.currentFocus = .list } }
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // [[ completion uses the system completion popup, fed with todo titles.
    override var rangeForUserCompletion: NSRange {
        if let c = controller, let r = MainActor.assumeIsolated({ c.completionRange() }) { return r }
        return super.rangeForUserCompletion
    }

    override func completions(forPartialWordRange r: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard let c = controller else { return nil }
        index.pointee = 0
        return MainActor.assumeIsolated { c.completions(for: r) }
    }

    override func insertCompletion(_ word: String, forPartialWordRange r: NSRange, movement: Int, isFinal: Bool) {
        let accept = isFinal && (movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue)
        super.insertCompletion(accept ? word + "]]" : word, forPartialWordRange: r, movement: movement, isFinal: isFinal)
        if isFinal, let c = controller { MainActor.assumeIsolated { c.completing = false } }
    }

    // MARK: mouse

    override func mouseDown(with e: NSEvent) {
        guard let c = controller else { return super.mouseDown(with: e) }
        let p = convert(e.locationInWindow, from: nil)
        let zone = MainActor.assumeIsolated { c.hit(p) }
        switch zone {
        case .chevron(let id):
            MainActor.assumeIsolated { c.toggleCollapse(id) }
        case .glyph(let id):
            trackGlyph(id, from: p, controller: c)
        case .meta(let id):
            MainActor.assumeIsolated {
                c.placeCaret(on: id, column: nil)
                c.store.selection = id
                c.app.panelOpen = true
            }
            window?.makeFirstResponder(self)
        case .link(let link) where e.clickCount == 1 && e.modifierFlags.intersection([.shift, .command, .option]).isEmpty:
            MainActor.assumeIsolated {
                if link.hasPrefix("wiki:") { c.app.openLink(named: String(link.dropFirst(5))) }
            }
        default:
            super.mouseDown(with: e)
        }
    }

    /// Click a shape to fill it in; drag it to move the todo (x picks the nesting level).
    private func trackGlyph(_ id: String, from start: NSPoint, controller c: BufferController) {
        var dragging = false
        while let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let q = convert(ev.locationInWindow, from: nil)
            if ev.type == .leftMouseDragged {
                if !dragging && hypot(q.x - start.x, q.y - start.y) > 4 {
                    dragging = true
                    MainActor.assumeIsolated { c.publishFrames() }
                }
                if dragging {
                    MainActor.assumeIsolated { c.app.dragMoved(id, to: q) }
                    autoscroll(with: ev)
                    needsDisplay = true
                }
            } else {
                MainActor.assumeIsolated {
                    if dragging { c.app.dragEnded(at: q) } else { c.toggleDone(id) }
                }
                needsDisplay = true
                break
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let c = controller else { return super.menu(for: event) }
        let p = convert(event.locationInWindow, from: nil)
        return MainActor.assumeIsolated {
            for l in c.lines() {
                guard let id = l.id, let r = c.rect(for: l), p.y >= r.minY, p.y < r.maxY else { continue }
                if c.caretID != id { c.placeCaret(on: id, column: nil) }
                return c.contextMenu(for: id)
            }
            return super.menu(for: event)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let c = controller else { return }
        MainActor.assumeIsolated {
            for l in c.lines() {
                guard let id = l.id, let li = c.info[id], let r = c.rect(for: l) else { continue }
                if !li.todo.isSection {
                    addCursorRect(NSRect(x: c.glyphX(depth: li.depth) - 5, y: r.minY, width: c.glyphWidth + 10, height: r.height), cursor: .pointingHand)
                }
                if li.hasKids {
                    addCursorRect(NSRect(x: c.chevronX(depth: li.depth) - 4, y: r.minY, width: 14, height: r.height), cursor: .pointingHand)
                }
            }
        }
    }

    // MARK: drawing the margins

    /// Margins first (the current-line band sits under the text), then the text itself.
    override func draw(_ dirty: NSRect) {
        if let c = controller { MainActor.assumeIsolated { drawMargins(c, dirty) } }
        super.draw(dirty)
    }

    private func drawMargins(_ c: BufferController, _ dirty: NSRect) {
        let ls = c.lines()
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        let sel = selectedRange()
        let caretIdx = c.lineIndex(at: sel.location, in: ls)

        // Current line: a quiet band, stronger when the list has the keyboard.
        if let i = caretIdx, (focused || c.app.panelOpen), sel.length == 0 || !(string as NSString).substring(with: sel).contains("\n"),
           let r = c.rect(for: ls[i]) {
            (focused ? NSColor.controlAccentColor.withAlphaComponent(0.11) : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
            NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height).fill()
        }

        let font = c.font
        let draggingID = c.app.draggingID
        for l in ls {
            guard let id = l.id, let li = c.info[id], let r = c.rect(for: l) else { continue }
            guard r.maxY >= dirty.minY - 4, r.minY <= dirty.maxY + 4 else { continue }
            guard let base = c.baseline(for: l) else { continue }
            if draggingID == id {
                NSColor.labelColor.withAlphaComponent(0.05).setFill()
                NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height).fill()
            }
            if li.hasKids {
                let chev = NSAttributedString(string: li.collapsed ? "▸" : "▾",
                                              attributes: [.font: c.smallFont, .foregroundColor: BufferController.faint])
                chev.draw(at: NSPoint(x: c.chevronX(depth: li.depth), y: base - c.smallFont.ascender))
            }
            if !li.todo.isSection {
                let color: NSColor = li.running ? .controlAccentColor : (li.todo.done ? BufferController.faint : BufferController.dim)
                let g = NSAttributedString(string: li.todo.glyph, attributes: [.font: font, .foregroundColor: color])
                g.draw(at: NSPoint(x: c.glyphX(depth: li.depth), y: base - font.ascender))
            }
            if let m = li.meta {
                let w = m.size().width
                m.draw(at: NSPoint(x: bounds.width - 16 - w, y: base - c.smallFont.ascender))
            }
        }

        // Drop line while dragging a shape.
        if let h = c.app.dropHint {
            var y: CGFloat?
            var x: CGFloat = 30
            if h.id == AppModel.endDropID, let last = ls.last, let r = c.rect(for: last) { y = r.maxY }
            else if let l = ls.first(where: { $0.id == h.id }), let r = c.rect(for: l) {
                y = h.after ? r.maxY : r.minY
                x = 8 + CGFloat(h.depth) * BufferController.indentStep + 14
            }
            if let y {
                NSColor.controlAccentColor.setFill()
                NSRect(x: x, y: y - 1, width: bounds.width - x - 16, height: 2).fill()
            }
        }

        // Empty buffer.
        if (textStorage?.length ?? 0) == 0 && c.renderedIDs.isEmpty {
            let s = NSAttributedString(string: c.placeholder, attributes: [.font: font, .foregroundColor: BufferController.faint])
            s.draw(at: NSPoint(x: c.textX(depth: 0, section: false), y: BufferController.topInset + 5))
        }
    }
}
