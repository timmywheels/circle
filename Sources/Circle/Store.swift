import Foundation
import Observation
import CircleCore

/// Source of truth for the UI. Every mutation lands in memory first and
/// renders on the same frame; SQLite and sync happen afterwards off-main.
@MainActor @Observable
final class Store {
    /// Visible rows, depth-first through the tree.
    private(set) var ordered: [Todo] = []
    /// Bumped on every rebuild; the list buffer compares it to know when the store moved without it.
    private(set) var revision = 0
    /// Indent level per visible row.
    private(set) var depth: [String: Int] = [:]
    /// (done, total) direct children per parent, for the progress badge.
    private(set) var progress: [String: (done: Int, total: Int)] = [:]
    var selection: String?
    var hideDone = Settings.shared.hideCompleted {
        didSet { if Settings.shared.hideCompleted != hideDone { Settings.shared.hideCompleted = hideDone }; rebuild() }
    }
    /// settings.json "logbook": "never" keeps completed items in the list.
    var autoArchive = Settings.shared.logbook != "never" { didSet { rebuild() } }
    var syncState: SyncState = .local
    /// Show only one shape (⌥1 ⌥2 ⌥3). nil shows everything. Filtered views are flat.
    var filter: Kind? { didSet { rebuild() } }
    /// Open items per shape, for the status line.
    private(set) var openCounts: [Kind: Int] = [:]
    /// Logbook view: everything completed before today, newest first.
    var logbook = false { didSet { rebuild() } }
    @ObservationIgnored private var dayStart: Int64 = Store.startOfToday()
    static func startOfToday() -> Int64 { Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000) }
    /// Collapsed parents (local to this Mac).
    private(set) var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") }
    }

    @ObservationIgnored private var byID: [String: Todo] = [:]
    /// Live (non-deleted) children per parent id ("" = root), sorted.
    @ObservationIgnored private var kids: [String: [Todo]] = [:]
    @ObservationIgnored private var repo: TodoRepo
    /// The open vault ("" = Personal). Each vault is its own database and sync room.
    private(set) var vault: String = Paths.currentVault
    @ObservationIgnored private let q = DispatchQueue(label: "circle.db", qos: .userInitiated)
    @ObservationIgnored private var lastVersion: Int64 = 0
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var undoStack: [[Todo]] = []
    /// While open, every snapshot joins one group, so one ⌘Z undoes one whole edit
    /// (e.g. deleting a section and its items in one keystroke). First snapshot per id wins.
    @ObservationIgnored private var openGroup: [Todo]?
    @ObservationIgnored private var groupIDs = Set<String>()

    @ObservationIgnored private var groupDepth = 0
    @ObservationIgnored private var groupKeep = false

    /// Groups nest (a command can trigger a buffer reconcile); the outermost one decides.
    func beginUndoGroup() {
        if groupDepth == 0 { openGroup = []; groupIDs = []; groupKeep = false }
        groupDepth += 1
    }

    /// keep: false drops the group (an ordinary typing edit, which the text view undoes itself).
    func endUndoGroup(keep: Bool) {
        groupKeep = groupKeep || keep
        groupDepth = max(0, groupDepth - 1)
        guard groupDepth == 0 else { return }
        defer { openGroup = nil; groupIDs = [] }
        guard groupKeep, let g = openGroup, !g.isEmpty else { return }
        undoStack.append(g)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }
    /// Repeating todo -> the next occurrence created when it was checked off (this session).
    @ObservationIgnored private var successor: [String: String] = [:]
    @ObservationIgnored private var undoneRepeat: Set<String> = []
    @ObservationIgnored var onLocalChange: (() -> Void)?
    /// Called after every rebuild with all live todos (reminder scheduling).
    @ObservationIgnored var onRebuilt: (([Todo]) -> Void)?
    @ObservationIgnored let device: String

    init() {
        let repo: TodoRepo
        let start = Paths.currentVault
        // The device id comes from the original database so this Mac signs edits the same way in every vault.
        let personal: TodoRepo
        do { personal = try TodoRepo() } catch { fatalError("Circle: cannot open database: \(error)") }
        repo = start.isEmpty ? personal : ((try? TodoRepo(vault: start)) ?? personal)
        vault = repo === personal ? "" : start
        self.repo = repo
        self.device = personal.device
        // Synchronous initial load so the first frame already has data.
        for t in (try? repo.all()) ?? [] { byID[t.id] = t }
        lastVersion = repo.dataVersion()
        repairSplitLoss()
        rebuild()
        selection = ordered.first?.id
        startPolling()
    }

    // MARK: derived

    private static func order(_ a: Todo, _ b: Todo) -> Bool { a.sort != b.sort ? a.sort < b.sort : a.id < b.id }

    /// Effective parent: "" when the parent is missing or deleted (orphans float to the top level).
    private func parentID(_ t: Todo) -> String {
        guard !t.parent.isEmpty, t.parent != t.id, let p = byID[t.parent], !p.deleted else { return "" }
        return t.parent
    }

    private func rebuild() {
        let live = byID.values.filter { !$0.deleted }
        var counts: [Kind: Int] = [:]
        var k: [String: [Todo]] = [:]
        for t in live {
            if !t.done && !t.isSection && !Self.isBlank(t.title) { counts[t.kind, default: 0] += 1 }
            k[parentID(t), default: []].append(t)
        }
        for key in k.keys { k[key]!.sort(by: Self.order) }
        kids = k
        openCounts = counts
        var prog: [String: (done: Int, total: Int)] = [:]
        for (p, cs) in k where !p.isEmpty { prog[p] = (cs.filter(\.done).count, cs.count) }
        progress = prog

        // Archived = completed before today, with nothing open underneath. Out of the list, into the logbook.
        var memo: [String: Bool] = [:]
        func archived(_ t: Todo) -> Bool {
            if let m = memo[t.id] { return m }
            memo[t.id] = false // cycle guard
            let r = autoArchive && t.done && !t.isSection && t.completedAt < dayStart && (k[t.id] ?? []).allSatisfy { archived($0) }
            memo[t.id] = r
            return r
        }

        var rows: [Todo] = []
        var d: [String: Int] = [:]
        if logbook {
            rows = live.filter { $0.done && !$0.isSection && $0.completedAt < dayStart }.sorted { $0.completedAt > $1.completedAt }
        } else if let f = filter {
            rows = live.filter { $0.kind == f && !$0.isSection && !archived($0) && !(hideDone && $0.done) }.sorted(by: Self.order)
        } else {
            var seen = Set<String>()
            func walk(_ p: String, _ level: Int) {
                for t in k[p] ?? [] where !seen.contains(t.id) {
                    seen.insert(t.id)
                    if archived(t) || (hideDone && t.done) { continue }
                    rows.append(t); d[t.id] = level
                    if !collapsed.contains(t.id) { walk(t.id, level + 1) }
                }
            }
            walk("", 0)
            // Anything unreachable (a parent cycle from conflicting edits) shows at the top level.
            for t in live.sorted(by: Self.order) where !seen.contains(t.id) && !isHiddenByAncestor(t) && !archived(t) && !(hideDone && t.done) {
                rows.append(t); d[t.id] = 0; seen.insert(t.id)
            }
        }
        ordered = rows
        depth = d
        revision &+= 1
        onRebuilt?(live)
        if let s = selection, !rows.contains(where: { $0.id == s }) { selection = nil }
    }

    /// True when an ancestor is collapsed or hidden, so the row is legitimately not shown.
    private func isHiddenByAncestor(_ t: Todo) -> Bool {
        var p = parentID(t), hops = 0
        while !p.isEmpty, hops < 64, let pt = byID[p] {
            if collapsed.contains(p) || (hideDone && pt.done) { return true }
            p = parentID(pt); hops += 1
        }
        return false
    }

    func todo(_ id: String?) -> Todo? { id.flatMap { byID[$0] } }
    func children(_ id: String) -> [Todo] { kids[id] ?? [] }
    func hasChildren(_ id: String) -> Bool { !(kids[id] ?? []).isEmpty }

    var selectedIndex: Int? { selection.flatMap { s in ordered.firstIndex { $0.id == s } } }

    private func descendants(_ id: String) -> [Todo] {
        var out: [Todo] = [], stack = [id], seen: Set<String> = [id]
        while let p = stack.popLast() {
            for c in kids[p] ?? [] where seen.insert(c.id).inserted { out.append(c); stack.append(c.id) }
        }
        return out
    }

    /// Sort value that places an item right after `anchor` among its siblings.
    private func sortAfter(_ anchor: Todo) -> Double {
        let sibs = kids[parentID(anchor)] ?? []
        guard let i = sibs.firstIndex(where: { $0.id == anchor.id }) else { return anchor.sort + 1 }
        return i + 1 < sibs.count ? (anchor.sort + sibs[i + 1].sort) / 2 : anchor.sort + 1
    }

    // MARK: mutations (all instant)

    private func commit(_ ts: [Todo]) {
        guard !ts.isEmpty else { return }
        for t in ts { byID[t.id] = t }
        rebuild()
        let repo = repo
        // Blank lines are real rows (spacers): saved and synced, skipped by counts and agents.
        let persist = ts
        q.async { [weak self] in
            try? repo.saveLocal(persist)
            let v = repo.dataVersion()
            DispatchQueue.main.async { self?.lastVersion = v; self?.onLocalChange?() }
        }
    }

    /// Adds at the top of the list, or as the next sibling of `anchor`.
    @discardableResult
    func add(_ title: String, kind: Kind = .mine, after anchor: String? = nil) -> Todo? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var parent = ""
        var sort = ((kids[""] ?? []).first?.sort ?? 0) - 1
        if let a = anchor.flatMap({ byID[$0] }), !a.deleted {
            parent = parentID(a)
            sort = sortAfter(a)
        }
        let t = Todo(kind: kind, parent: parent, title: title, sort: sort, origin: device)
        commit([t])
        return t
    }

    func setKind(_ id: String, _ kind: Kind) {
        guard var t = byID[id], t.kind != kind, !t.isSection else { return }
        t.kind = kind
        commit([t.touched(by: device)])
    }

    func toggle(_ id: String) {
        guard var t = byID[id] else { return }
        if t.isSection { setCollapsed(id, !collapsed.contains(id)); return }
        t.setDone(!t.done)
        var changes = [t.touched(by: device)]
        // Repeating: this one goes to history, the next occurrence takes its place.
        if t.done && !t.repeatRule.isEmpty && !undoneRepeat.contains(id) {
            let from = t.remindAt > 0 ? Date(timeIntervalSince1970: Double(t.remindAt) / 1000) : Date()
            let nextDate = When.next(after: Date(), rule: t.repeatRule, from: from)
            var n = Todo(kind: t.kind, parent: t.parent, title: t.title, notes: t.notes, sort: sortAfter(t), origin: device,
                         remindAt: Int64(nextDate.timeIntervalSince1970 * 1000), repeatRule: t.repeatRule)
            n.sort = t.sort + 0.000_001
            changes.append(n)
            successor[id] = n.id
        } else if !t.done, let next = successor[id], var n = byID[next], !n.done {
            // Un-checking right away takes back the generated next occurrence.
            n.deleted = true
            changes.append(n.touched(by: device))
            successor[id] = nil
        }
        commit(changes)
    }

    /// Renames, and rewrites [[old title]] links elsewhere so they keep pointing here.
    func rename(_ id: String, _ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var t = byID[id], !title.isEmpty, title != t.title else { return }
        let old = t.displayTitle
        t.title = title
        var changed = [t.touched(by: device)]
        let new = t.displayTitle
        if Links.key(old) != Links.key(new) || old != new {
            let oldKey = Links.key(old)
            for o in byID.values where !o.deleted && o.id != id {
                let hits = (Links.names(in: o.title) + Links.names(in: o.notes)).contains { Links.key($0) == oldKey }
                guard hits else { continue }
                var c = o
                c.title = Links.rename(in: c.title, from: old, to: new)
                c.notes = Links.rename(in: c.notes, from: old, to: new)
                changed.append(c.touched(by: device))
            }
        }
        commit(changed)
    }

    /// The todo a [[name]] refers to: exact title match, open items first.
    func resolve(_ name: String) -> Todo? {
        let key = Links.key(name)
        return byID.values
            .filter { !$0.deleted && Links.key($0.displayTitle) == key }
            .min { a, b in a.done != b.done ? !a.done : a.createdAt < b.createdAt }
    }

    /// Todos whose title or notes link to this one.
    func backlinks(_ id: String) -> [Todo] {
        guard let t = byID[id] else { return [] }
        let key = Links.key(t.displayTitle)
        return byID.values
            .filter { !$0.deleted && $0.id != id && (Links.names(in: $0.title) + Links.names(in: $0.notes)).contains { Links.key($0) == key } }
            .sorted(by: Self.order)
    }

    /// Todos matching a [[ autocomplete query.
    func suggestions(_ q: String, limit: Int = 6) -> [Todo] {
        let key = Links.key(q)
        let pool = byID.values.filter { !$0.deleted && !$0.isSection }
        let hits = key.isEmpty ? pool : pool.filter { $0.title.lowercased().contains(key) }
        return Array(hits.sorted { a, b in
            let ap = a.title.lowercased().hasPrefix(key), bp = b.title.lowercased().hasPrefix(key)
            if ap != bp { return ap }
            if a.done != b.done { return !a.done }
            return a.updatedAt > b.updatedAt
        }.prefix(limit))
    }

    /// Makes a todo visible: leave logbook/filters that hide it, expand its ancestors.
    func reveal(_ id: String) {
        guard let t = byID[id] else { return }
        var p = parentID(t), hops = 0
        var changed = false
        while !p.isEmpty, hops < 64 {
            if collapsed.contains(p) { collapsed.remove(p); changed = true }
            p = byID[p].map { parentID($0) } ?? ""; hops += 1
        }
        if filter != nil && filter != t.kind { filter = nil }
        if t.done && hideDone { hideDone = false }
        let inLogbook = t.done && t.completedAt < dayStart
        if logbook != inLogbook { logbook = inLogbook } else if changed { rebuild() }
    }

    /// Sets or clears (at: 0) a reminder.
    func setReminder(_ id: String, at: Int64, rule: String) {
        guard var t = byID[id], !t.isSection, t.remindAt != at || t.repeatRule != rule else { return }
        t.remindAt = at
        t.repeatRule = at == 0 ? "" : rule
        commit([t.touched(by: device)])
    }

    /// All live todos, for schedulers.
    var allLive: [Todo] { byID.values.filter { !$0.deleted } }

    func setNotes(_ id: String, _ notes: String) {
        guard var t = byID[id], notes != t.notes else { return }
        t.notes = notes
        commit([t.touched(by: device)])
    }

    /// Deletes the item and everything under it; one undo brings the whole subtree back.
    func delete(_ id: String) {
        guard let t = byID[id], let i = ordered.firstIndex(where: { $0.id == id }) else { return }
        let group = [t] + descendants(id)
        pushUndo(group)
        let gone = Set(group.map(\.id))
        let neighbor = ordered[(i + 1)...].first { !gone.contains($0.id) }?.id ?? ordered[..<i].last?.id
        commit(group.map { var c = $0; c.deleted = true; return c.touched(by: device) })
        selection = neighbor
    }

    private func pushUndo(_ group: [Todo]) {
        if openGroup != nil {
            for t in group where groupIDs.insert(t.id).inserted { openGroup!.append(t) }
            return
        }
        undoStack.append(group)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    /// Restores the snapshots taken before a change (deletes come back, inserts go away, moves return).
    func undo() {
        guard let group = undoStack.popLast() else { return }
        commit(group.map { $0.touched(by: device) })
        selection = group.first(where: { !$0.deleted })?.id ?? selection
    }

    /// One-time repair for an early list-buffer bug: ↩ at the start of a line copied the todo to a
    /// new line and deleted the original (blanked), taking its notes and agent runs with it.
    /// Brings each original back under the copy's title and removes the copy.
    private func repairSplitLoss() {
        let key = "repair-split-v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let cutoff = Clock.now() - 48 * 3600 * 1000
        var changes: [Todo] = []
        var used = Set<String>()
        let live = byID.values.filter { !$0.deleted && !Self.isBlank($0.title) }
        for d in byID.values where d.deleted && Self.isBlank(d.title) && d.updatedAt > cutoff && d.updatedAt - d.createdAt > 60_000 {
            let copies = live.filter { !used.contains($0.id) && $0.notes.isEmpty && abs($0.createdAt - d.updatedAt) < 5_000 }
            guard let c = copies.min(by: { abs($0.createdAt - d.updatedAt) < abs($1.createdAt - d.updatedAt) }) else { continue }
            used.insert(c.id)
            var r = d
            r.title = c.title; r.deleted = false; r.parent = c.parent; r.sort = c.sort
            var gone = c; gone.deleted = true
            changes.append(r.touched(by: device)); changes.append(gone.touched(by: device))
        }
        guard !changes.isEmpty else { return }
        for t in changes { byID[t.id] = t }
        let repo = repo
        q.async { try? repo.saveLocal(changes) }
    }

    // MARK: buffer editing (the list is one text buffer; each line is a todo)

    static func isBlank(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == "#"
    }

    /// Live title edit from the buffer: no trimming, blanks allowed, no link rewriting.
    func setTitle(_ id: String, _ title: String) {
        guard var t = byID[id], t.title != title else { return }
        if openGroup != nil { pushUndo([t]) }   // a joined line changes its neighbor's title too
        t.title = title
        commit([t.touched(by: device)])
    }

    /// After a line was edited: keep [[old title]] links elsewhere pointing at it.
    func rewriteLinks(_ id: String, from oldTitle: String) {
        guard let t = byID[id], !Self.isBlank(oldTitle) else { return }
        let old = oldTitle.hasPrefix("# ") ? String(oldTitle.dropFirst(2)) : oldTitle
        let new = t.displayTitle
        guard Links.key(old) != Links.key(new), !Links.key(new).isEmpty else { return }
        let oldKey = Links.key(old)
        var changed: [Todo] = []
        for o in byID.values where !o.deleted && o.id != id {
            guard (Links.names(in: o.title) + Links.names(in: o.notes)).contains(where: { Links.key($0) == oldKey }) else { continue }
            var c = o
            c.title = Links.rename(in: c.title, from: old, to: new)
            c.notes = Links.rename(in: c.notes, from: old, to: new)
            changed.append(c.touched(by: device))
        }
        commit(changed)
    }

    /// A new line right after `prev` in the buffer: its first child when prev is an open parent,
    /// otherwise its next sibling. nil puts it at the very top.
    @discardableResult
    func insertLine(after prev: String?, title: String = "", firstChildIfOpen: Bool = true, intoSection: Bool = false,
                    undoable: Bool = true) -> Todo {
        var parent = "", sort: Double
        if let p = prev.flatMap({ byID[$0] }), !p.deleted {
            // A new line under a section heading belongs to that section, even an empty or folded one.
            if intoSection && p.isSection && filter == nil && !logbook {
                if collapsed.contains(p.id) { setCollapsed(p.id, false) }
                parent = p.id; sort = (kids[p.id]?.first?.sort ?? 1) - 1
            } else if firstChildIfOpen && filter == nil && !logbook && !collapsed.contains(p.id), let first = kids[p.id]?.first {
                parent = p.id; sort = first.sort - 1
            } else {
                parent = parentID(p); sort = sortAfter(p)
            }
        } else {
            sort = ((kids[""] ?? []).first?.sort ?? 0) - 1
        }
        let t = Todo(kind: filter ?? .mine, parent: parent, title: title, sort: sort, origin: device)
        if undoable { var gone = t; gone.deleted = true; pushUndo([gone]) }
        commit([t])
        return t
    }

    /// A new line just above `id`, as its sibling.
    @discardableResult
    func insertLine(before id: String) -> Todo? {
        guard let tg = byID[id] else { return nil }
        let p = parentID(tg)
        let sibs = kids[p] ?? []
        let i = sibs.firstIndex(where: { $0.id == id }) ?? 0
        let sort = i > 0 ? (sibs[i - 1].sort + tg.sort) / 2 : tg.sort - 1
        let t = Todo(kind: filter ?? tg.kind, parent: p, title: "", sort: sort, origin: device)
        var gone = t; gone.deleted = true; pushUndo([gone])
        commit([t])
        return t
    }

    /// Last child of `parent` (pasting an indented list).
    @discardableResult
    func appendChild(_ parent: String, title: String) -> Todo? {
        guard byID[parent] != nil else { return nil }
        let t = Todo(kind: filter ?? .mine, parent: parent, title: title, sort: ((kids[parent] ?? []).last?.sort ?? 0) + 1, origin: device)
        commit([t])
        collapsed.remove(parent)
        return t
    }

    func setDone(_ id: String, _ on: Bool) {
        guard var t = byID[id], t.done != on, !t.isSection else { return }
        t.setDone(on)
        commit([t.touched(by: device)])
    }

    /// A line removed from the buffer. Its visible children stay (they move into its place, or
    /// into `mergeInto` when its text was joined onto that line); a folded line takes its subtree with it.
    func removeLine(_ id: String, mergeInto target: String? = nil, undoable: Bool = true) {
        guard let t = byID[id], !t.deleted else { return }
        let children = kids[id] ?? []
        var snapshot = [t]
        var changes: [Todo] = []
        if !children.isEmpty && (!collapsed.contains(id) || target != nil) {
            snapshot += children
            if let target, byID[target] != nil, target != id, !isInside(target, id) {
                var s = (kids[target] ?? []).last?.sort ?? 0
                for c in children { var m = c; m.parent = target; s += 1; m.sort = s; changes.append(m.touched(by: device)) }
                collapsed.remove(target)
            } else {
                let p = parentID(t)
                let sibs = kids[p] ?? []
                let i = sibs.firstIndex(where: { $0.id == id }) ?? 0
                let next = i + 1 < sibs.count ? sibs[i + 1].sort : t.sort + 1
                let step = (next - t.sort) / Double(children.count + 1)
                for (k, c) in children.enumerated() {
                    var m = c; m.parent = p; m.sort = t.sort + step * Double(k + 1); changes.append(m.touched(by: device))
                }
            }
        } else if !children.isEmpty {
            let sub = descendants(id)
            snapshot += sub
            changes += sub.map { var c = $0; c.deleted = true; return c.touched(by: device) }
        }
        if undoable { pushUndo(snapshot) }
        var d = t; d.deleted = true
        changes.append(d.touched(by: device))
        commit(changes)
    }

    /// Removes completed items whose whole subtree is completed.
    func clearCompleted() {
        func allDone(_ id: String) -> Bool { (byID[id]?.done ?? true) && (kids[id] ?? []).allSatisfy { allDone($0.id) } }
        var group: [Todo] = []
        var taken = Set<String>()
        for t in byID.values where !t.deleted && t.done && !taken.contains(t.id) && allDone(t.id) {
            for x in [t] + descendants(t.id) where taken.insert(x.id).inserted { group.append(x) }
        }
        guard !group.isEmpty else { return }
        pushUndo(group)
        commit(group.map { var c = $0; c.deleted = true; return c.touched(by: device) })
    }

    /// Moves the item (with its subtree) up (-1) or down (+1) among its siblings.
    func move(_ id: String, _ dir: Int) {
        guard var t = byID[id] else { return }
        let sibs = kids[parentID(t)] ?? []
        guard let i = sibs.firstIndex(where: { $0.id == id }) else { return }
        let j = i + dir
        guard j >= 0, j < sibs.count else { return }
        let beyond = j + dir
        let a = sibs[j].sort
        let b: Double = (beyond >= 0 && beyond < sibs.count) ? sibs[beyond].sort : a + Double(dir) * 2
        t.sort = (a + b) / 2
        if let old = byID[id] { pushUndo([old]) }; commit([t.touched(by: device)])
    }

    /// Drag and drop: put `id` just before or after `target` as its sibling.
    func place(_ id: String, relativeTo target: String, after: Bool, asSibling: Bool = false) {
        guard id != target, var t = byID[id], let tg = byID[target] else { return }
        if descendants(id).contains(where: { $0.id == target }) { return }   // not into its own subtree
        // Dropping below an expanded parent means "first child", which is where the line appears.
        if after && !asSibling && filter == nil && hasChildren(target) && !collapsed.contains(target), let first = kids[target]?.first {
            t.parent = target
            t.sort = first.id == id ? first.sort : first.sort - 1
            if let old = byID[id] { pushUndo([old]) }; commit([t.touched(by: device)]); selection = id; return
        }
        let p = parentID(tg)
        let sibs = (kids[p] ?? []).filter { $0.id != id }
        guard let i = sibs.firstIndex(where: { $0.id == target }) else { return }
        if after { t.sort = i + 1 < sibs.count ? (tg.sort + sibs[i + 1].sort) / 2 : tg.sort + 1 }
        else { t.sort = i > 0 ? (sibs[i - 1].sort + tg.sort) / 2 : tg.sort - 1 }
        t.parent = p
        if let old = byID[id] { pushUndo([old]) }; commit([t.touched(by: device)])
        selection = id
    }

    /// True when `id` sits somewhere under `ancestor`.
    func isInside(_ id: String, _ ancestor: String) -> Bool {
        var p = byID[id].map(parentID) ?? ""
        var hops = 0
        while !p.isEmpty, hops < 64 {
            if p == ancestor { return true }
            p = byID[p].map(parentID) ?? ""; hops += 1
        }
        return false
    }

    /// The ancestor of `id` (or `id` itself) at the given depth.
    func ancestor(of id: String, atDepth d: Int) -> String? {
        var cur = id
        while let level = depth[cur], level > d, let t = byID[cur] { cur = parentID(t) }
        return depth[cur] == d ? cur : nil
    }

    /// Drag and drop into the empty space under the list: last top-level item.
    func moveToEnd(_ id: String) {
        guard var t = byID[id] else { return }
        t.parent = ""
        t.sort = ((kids[""] ?? []).filter { $0.id != id }.last?.sort ?? 0) + 1
        if let old = byID[id] { pushUndo([old]) }; commit([t.touched(by: device)])
        selection = id
    }

    /// Drag and drop onto the right side of a row: nest as its last child.
    func nest(_ id: String, under target: String) {
        guard id != target, var t = byID[id], byID[target] != nil else { return }
        if descendants(id).contains(where: { $0.id == target }) { return }
        t.parent = target
        t.sort = ((kids[target] ?? []).filter { $0.id != id }.last?.sort ?? 0) + 1
        collapsed.remove(target)
        if let old = byID[id] { pushUndo([old]) }; commit([t.touched(by: device)])
        selection = id
    }

    /// Makes the item a child of the sibling above it (tab).
    func indent(_ id: String) {
        guard var t = byID[id], filter == nil else { return }
        let sibs = kids[parentID(t)] ?? []
        guard let i = sibs.firstIndex(where: { $0.id == id }), i > 0 else { return }
        let newParent = sibs[i - 1]
        t.parent = newParent.id
        t.sort = ((kids[newParent.id] ?? []).last?.sort ?? 0) + 1
        collapsed.remove(newParent.id)
        if let old = byID[id] { pushUndo([old]) }; commit([t.touched(by: device)])
    }

    /// Moves the item out one level, right after its old parent (shift-tab).
    func outdent(_ id: String) {
        guard var t = byID[id], filter == nil else { return }
        let p = parentID(t)
        guard !p.isEmpty, let parent = byID[p] else { return }
        t.parent = parentID(parent)
        t.sort = sortAfter(parent)
        if let old = byID[id] { pushUndo([old]) }; commit([t.touched(by: device)])
    }

    func setCollapsed(_ id: String, _ on: Bool) {
        guard hasChildren(id) else { return }
        if on { collapsed.insert(id) } else { collapsed.remove(id) }
        rebuild()
    }

    /// ←: collapse, or jump to the parent.
    func left() {
        guard let id = selection, let t = byID[id] else { return }
        if hasChildren(id) && !collapsed.contains(id) { setCollapsed(id, true) }
        else if !parentID(t).isEmpty, filter == nil { selection = parentID(t) }
    }

    /// →: expand, or step into the first child.
    func right() {
        guard let id = selection, hasChildren(id) else { return }
        if collapsed.contains(id) { setCollapsed(id, false) }
        else if filter == nil, let first = ordered.first(where: { parentID($0) == id }) { selection = first.id }
    }

    func select(_ dir: Int) {
        guard !ordered.isEmpty else { selection = nil; return }
        guard let i = selectedIndex else { selection = ordered[dir > 0 ? 0 : ordered.count - 1].id; return }
        selection = ordered[max(0, min(ordered.count - 1, i + dir))].id
    }

    // MARK: external writes (circle-mcp, other processes)

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        pollTimer?.tolerance = 0.05
    }

    private func poll() {
        let today = Self.startOfToday()
        if today != dayStart { dayStart = today; rebuild() }   // midnight: yesterday's done items move to the logbook
        let repo = repo, known = lastVersion
        q.async { [weak self] in
            let v = repo.dataVersion()
            guard v != known, let rows = try? repo.all() else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastVersion = v
                self.merge(rows)
                self.onLocalChange?() // an agent wrote: push it to the cloud
            }
        }
    }

    func merge(_ rows: [Todo]) {
        var changed = false
        for r in rows {
            if let cur = byID[r.id], !r.wins(over: cur) { continue }
            byID[r.id] = r
            changed = true
        }
        if changed { rebuild() }
    }

    // MARK: sync plumbing (called by SyncClient)

    /// First sync into an encrypted room: re-upload every todo (sealed) and read the room from the start.
    /// Opens another vault in place: same window, same Store, different database.
    func switchVault(_ id: String) {
        guard id != vault, Vaults.isValidID(id), id != Vaults.index, let next = try? TodoRepo(vault: id) else { return }
        pollTimer?.invalidate()
        q.sync {}                        // let queued writes to the old vault finish
        repo = next
        vault = id
        byID = [:]; undoStack = []; successor = [:]; undoneRepeat = []
        for t in (try? next.all()) ?? [] { byID[t.id] = t }
        lastVersion = next.dataVersion()
        filter = nil; logbook = false
        rebuild()
        selection = ordered.first?.id
        startPolling()
        try? id.write(to: Paths.currentVaultFile, atomically: true, encoding: .utf8)
    }

    func prepareForEncryptedSync() {
        let repo = repo
        let key = "encrypted-upload:" + (SyncConfig.load()?.user ?? "")
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        q.sync { try? repo.markAllDirty() }
    }

    func pendingRows(_ done: @escaping ([Todo]) -> Void) {
        let repo = repo
        q.async { let rows = (try? repo.dirty()) ?? []; DispatchQueue.main.async { done(rows) } }
    }

    func cursor(_ done: @escaping (Int64) -> Void) {
        let repo = repo
        q.async { let c = Int64((try? repo.meta("cursor")) ?? "0") ?? 0; DispatchQueue.main.async { done(c) } }
    }

    func applyRemote(_ rows: [Todo], cursor: Int64?) {
        let repo = repo
        q.async { [weak self] in
            let applied = (try? repo.applyRemote(rows)) ?? []
            if let c = cursor {
                let cur = Int64((try? repo.meta("cursor")) ?? "0") ?? 0
                if c > cur { try? repo.setMeta("cursor", String(c)) }
            }
            let v = repo.dataVersion()
            DispatchQueue.main.async {
                self?.lastVersion = v
                if !applied.isEmpty { self?.merge(applied) }
            }
        }
    }

    // MARK: runs

    func saveRun(_ r: AgentRun) {
        let repo = repo
        let snapshot = (r.id, r.todoID, r.agent, r.model, r.cwd, r.status.rawValue, r.output, r.startedAt, r.endedAt)
        q.async {
            try? repo.saveRun(id: snapshot.0, todoID: snapshot.1, agent: snapshot.2, model: snapshot.3, cwd: snapshot.4,
                              status: snapshot.5, output: snapshot.6, startedAt: snapshot.7, endedAt: snapshot.8)
        }
    }

    func lastRun(_ todoID: String, _ done: @escaping (TodoRepo.RunRecord?) -> Void) {
        let repo = repo
        q.async { let r = try? repo.lastRun(todoID: todoID); DispatchQueue.main.async { done(r) } }
    }
}

enum SyncState: Equatable {
    case local, connecting, synced, offline
    var label: String {
        switch self {
        case .local: return "local"
        case .connecting: return "connecting"
        case .synced: return "synced"
        case .offline: return "offline"
        }
    }
}


extension Store: SyncTarget {
    var vaultID: String { vault }
    func setSyncState(_ s: SyncState) { syncState = s }
}
