import Foundation
import Observation
import CircleCore

/// Source of truth for the UI. Every mutation lands in memory first and
/// renders on the same frame; SQLite and sync happen afterwards off-main.
@MainActor @Observable
final class Store {
    /// Visible rows, depth-first through the tree.
    private(set) var ordered: [Todo] = []
    /// Indent level per visible row.
    private(set) var depth: [String: Int] = [:]
    /// (done, total) direct children per parent, for the progress badge.
    private(set) var progress: [String: (done: Int, total: Int)] = [:]
    var selection: String?
    var hideDone = UserDefaults.standard.bool(forKey: "hideDone") {
        didSet { UserDefaults.standard.set(hideDone, forKey: "hideDone"); rebuild() }
    }
    var syncState: SyncState = .local
    /// Show only one shape (⌥1 ⌥2 ⌥3). nil shows everything. Filtered views are flat.
    var filter: Kind? { didSet { rebuild() } }
    /// Open items per shape, for the status line.
    private(set) var openCounts: [Kind: Int] = [:]
    /// Collapsed parents (local to this Mac).
    private(set) var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") }
    }

    @ObservationIgnored private var byID: [String: Todo] = [:]
    /// Live (non-deleted) children per parent id ("" = root), sorted.
    @ObservationIgnored private var kids: [String: [Todo]] = [:]
    @ObservationIgnored private let repo: TodoRepo
    @ObservationIgnored private let q = DispatchQueue(label: "circle.db", qos: .userInitiated)
    @ObservationIgnored private var lastVersion: Int64 = 0
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var undoStack: [[Todo]] = []
    @ObservationIgnored var onLocalChange: (() -> Void)?
    @ObservationIgnored let device: String

    init() {
        let repo: TodoRepo
        do { repo = try TodoRepo() } catch { fatalError("Circle: cannot open database: \(error)") }
        self.repo = repo
        self.device = repo.device
        // Synchronous initial load so the first frame already has data.
        for t in (try? repo.all()) ?? [] { byID[t.id] = t }
        lastVersion = repo.dataVersion()
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
            if !t.done { counts[t.kind, default: 0] += 1 }
            k[parentID(t), default: []].append(t)
        }
        for key in k.keys { k[key]!.sort(by: Self.order) }
        kids = k
        openCounts = counts
        var prog: [String: (done: Int, total: Int)] = [:]
        for (p, cs) in k where !p.isEmpty { prog[p] = (cs.filter(\.done).count, cs.count) }
        progress = prog

        var rows: [Todo] = []
        var d: [String: Int] = [:]
        if let f = filter {
            rows = live.filter { $0.kind == f && !(hideDone && $0.done) }.sorted(by: Self.order)
        } else {
            var seen = Set<String>()
            func walk(_ p: String, _ level: Int) {
                for t in k[p] ?? [] where !seen.contains(t.id) {
                    seen.insert(t.id)
                    if hideDone && t.done { continue }
                    rows.append(t); d[t.id] = level
                    if !collapsed.contains(t.id) { walk(t.id, level + 1) }
                }
            }
            walk("", 0)
            // Anything unreachable (a parent cycle from conflicting edits) shows at the top level.
            for t in live.sorted(by: Self.order) where !seen.contains(t.id) && !isHiddenByAncestor(t) && !(hideDone && t.done) {
                rows.append(t); d[t.id] = 0; seen.insert(t.id)
            }
        }
        ordered = rows
        depth = d
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
        q.async { [weak self] in
            try? repo.saveLocal(ts)
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
        guard var t = byID[id], t.kind != kind else { return }
        t.kind = kind
        commit([t.touched(by: device)])
    }

    func toggle(_ id: String) {
        guard var t = byID[id] else { return }
        t.done.toggle()
        commit([t.touched(by: device)])
    }

    func rename(_ id: String, _ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var t = byID[id], !title.isEmpty, title != t.title else { return }
        t.title = title
        commit([t.touched(by: device)])
    }

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
        undoStack.append(group)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func undo() {
        guard let group = undoStack.popLast() else { return }
        commit(group.map { var c = $0; c.deleted = false; return c.touched(by: device) })
        selection = group.first?.id
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
        commit([t.touched(by: device)])
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
        commit([t.touched(by: device)])
    }

    /// Moves the item out one level, right after its old parent (shift-tab).
    func outdent(_ id: String) {
        guard var t = byID[id], filter == nil else { return }
        let p = parentID(t)
        guard !p.isEmpty, let parent = byID[p] else { return }
        t.parent = parentID(parent)
        t.sort = sortAfter(parent)
        commit([t.touched(by: device)])
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
