import Foundation

/// All SQL lives here. Shared by the app and the circle-mcp server, which
/// open the same WAL database from separate processes.
/// Each owner confines its instance to one serial queue.
public final class TodoRepo: @unchecked Sendable {
    public let db: SQLiteDB
    public let device: String

    public init(path: String = Paths.database.path) throws {
        db = try SQLiteDB(path: path)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS todos(
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          notes TEXT NOT NULL DEFAULT '',
          done INTEGER NOT NULL DEFAULT 0,
          sort REAL NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          deleted INTEGER NOT NULL DEFAULT 0,
          origin TEXT NOT NULL DEFAULT '',
          dirty INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS todos_dirty ON todos(dirty) WHERE dirty = 1;
        CREATE TABLE IF NOT EXISTS runs(
          id TEXT PRIMARY KEY, todo_id TEXT NOT NULL, agent TEXT NOT NULL, model TEXT NOT NULL,
          cwd TEXT NOT NULL, status TEXT NOT NULL, output TEXT NOT NULL,
          started_at INTEGER NOT NULL, ended_at INTEGER
        );
        CREATE INDEX IF NOT EXISTS runs_todo ON runs(todo_id, started_at);
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
        """)
        // v2: shapes. Add the column to databases created before it existed.
        // v3: nesting.
        var existing = Set<String>()
        try db.query("PRAGMA table_info(todos)") { existing.insert($0.text(1)) }
        if !existing.contains("kind") { try db.exec("ALTER TABLE todos ADD COLUMN kind TEXT NOT NULL DEFAULT 'todo'") }
        if !existing.contains("parent") { try db.exec("ALTER TABLE todos ADD COLUMN parent TEXT NOT NULL DEFAULT ''") }
        if !existing.contains("done_at") { try db.exec("ALTER TABLE todos ADD COLUMN done_at INTEGER NOT NULL DEFAULT 0") }
        if !existing.contains("remind_at") { try db.exec("ALTER TABLE todos ADD COLUMN remind_at INTEGER NOT NULL DEFAULT 0") }
        if !existing.contains("repeat") { try db.exec("ALTER TABLE todos ADD COLUMN \"repeat\" TEXT NOT NULL DEFAULT ''") }
        var dev = ""
        try db.query("SELECT v FROM meta WHERE k='device'") { dev = $0.text(0) }
        if dev.isEmpty {
            dev = String(UUID().uuidString.prefix(8)).lowercased()
            try db.run("INSERT OR IGNORE INTO meta(k,v) VALUES('device',?)", [.text(dev)])
            try db.query("SELECT v FROM meta WHERE k='device'") { dev = $0.text(0) }
        }
        device = dev
    }

    private static let cols = "id,title,notes,done,sort,created_at,updated_at,deleted,origin,kind,parent,done_at,remind_at,\"repeat\""

    private func decode(_ r: SQLiteDB.Row) -> Todo {
        Todo(id: r.text(0), title: r.text(1), notes: r.text(2), done: r.int(3) != 0, sort: r.real(4),
             createdAt: r.int(5), updatedAt: r.int(6), deleted: r.int(7) != 0, origin: r.text(8))
            .with(kind: Kind(rawValue: r.text(9)) ?? .mine, parent: r.text(10), doneAt: r.int(11),
                  remindAt: r.int(12), repeatRule: r.text(13))
    }

    private func args(_ t: Todo, dirty: Bool) -> [SQLValue] {
        [.text(t.id), .text(t.title), .text(t.notes), .int(t.done ? 1 : 0), .real(t.sort),
         .int(t.createdAt), .int(t.updatedAt), .int(t.deleted ? 1 : 0), .text(t.origin), .text(t.kind.rawValue),
         .text(t.parent), .int(t.doneAt), .int(t.remindAt), .text(t.repeatRule), .int(dirty ? 1 : 0)]
    }

    // LWW upsert: only overwrite when the incoming row wins.
    private static func upsert(local: Bool) -> String {
        let cmp = local ? ">=" : ">"
        return """
        INSERT INTO todos(\(cols),dirty) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          kind=excluded.kind, parent=excluded.parent, done_at=excluded.done_at,
          remind_at=excluded.remind_at, "repeat"=excluded."repeat", title=excluded.title, notes=excluded.notes, done=excluded.done, sort=excluded.sort,
          updated_at=excluded.updated_at, deleted=excluded.deleted, origin=excluded.origin,
          dirty=excluded.dirty
        WHERE excluded.updated_at > todos.updated_at
           OR (excluded.updated_at = todos.updated_at AND excluded.origin \(cmp) todos.origin)
        """
    }

    public func all(includeDeleted: Bool = true) throws -> [Todo] {
        var out: [Todo] = []
        let sql = "SELECT \(Self.cols) FROM todos" + (includeDeleted ? "" : " WHERE deleted=0") + " ORDER BY sort"
        try db.query(sql) { out.append(decode($0)) }
        return out
    }

    /// Finds by exact id or unique id prefix (agents like short ids).
    public func find(_ idOrPrefix: String) throws -> Todo? {
        var out: [Todo] = []
        try db.query("SELECT \(Self.cols) FROM todos WHERE deleted=0 AND id LIKE ? LIMIT 2",
                     [.text(idOrPrefix + "%")]) { out.append(decode($0)) }
        return out.count == 1 ? out[0] : out.first { $0.id == idOrPrefix }
    }

    public func minSort() throws -> Double {
        var v = 0.0
        try db.query("SELECT COALESCE(MIN(sort),0) FROM todos WHERE deleted=0") { v = $0.real(0) }
        return v
    }

    public func saveLocal(_ t: Todo) throws {
        try db.run(Self.upsert(local: true), args(t, dirty: true))
    }

    public func saveLocal(_ ts: [Todo]) throws {
        try db.transaction { for t in ts { try saveLocal(t) } }
    }

    /// Applies rows from the server. Returns the ones that changed local state.
    public func applyRemote(_ rows: [Todo]) throws -> [Todo] {
        var applied: [Todo] = []
        try db.transaction {
            for r in rows {
                if try db.run(Self.upsert(local: false), args(r, dirty: false)) > 0 { applied.append(r) }
                // Server has seen a version at least this new: clear the pending flag.
                try db.run("""
                UPDATE todos SET dirty=0 WHERE id=? AND dirty=1 AND
                  (updated_at < ? OR (updated_at = ? AND origin <= ?))
                """, [.text(r.id), .int(r.updatedAt), .int(r.updatedAt), .text(r.origin)])
            }
        }
        return applied
    }

    public func dirty(limit: Int = 500) throws -> [Todo] {
        var out: [Todo] = []
        try db.query("SELECT \(Self.cols) FROM todos WHERE dirty=1 LIMIT ?", [.int(Int64(limit))]) { out.append(decode($0)) }
        return out
    }

    public func meta(_ k: String) throws -> String? {
        var v: String?
        try db.query("SELECT v FROM meta WHERE k=?", [.text(k)]) { v = $0.text(0) }
        return v
    }

    public func setMeta(_ k: String, _ v: String) throws {
        try db.run("INSERT INTO meta(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", [.text(k), .text(v)])
    }

    /// Changes whenever another connection (e.g. circle-mcp) commits.
    public func dataVersion() -> Int64 {
        var v: Int64 = 0
        try? db.query("PRAGMA data_version") { v = $0.int(0) }
        return v
    }

    // MARK: runs

    public func saveRun(id: String, todoID: String, agent: String, model: String, cwd: String,
                        status: String, output: String, startedAt: Int64, endedAt: Int64?) throws {
        try db.run("""
        INSERT INTO runs(id,todo_id,agent,model,cwd,status,output,started_at,ended_at) VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET status=excluded.status, output=excluded.output, ended_at=excluded.ended_at
        """, [.text(id), .text(todoID), .text(agent), .text(model), .text(cwd), .text(status), .text(output),
              .int(startedAt), endedAt.map { .int($0) } ?? .null])
    }

    public struct RunRecord {
        public let id, todoID, agent, model, cwd, status, output: String
        public let startedAt: Int64
    }

    public func lastRun(todoID: String) throws -> RunRecord? {
        var r: RunRecord?
        try db.query("SELECT id,todo_id,agent,model,cwd,status,output,started_at FROM runs WHERE todo_id=? ORDER BY started_at DESC LIMIT 1",
                     [.text(todoID)]) {
            r = RunRecord(id: $0.text(0), todoID: $0.text(1), agent: $0.text(2), model: $0.text(3),
                          cwd: $0.text(4), status: $0.text(5), output: $0.text(6), startedAt: $0.int(7))
        }
        return r
    }
}

extension Todo {
    func with(kind: Kind, parent: String, doneAt: Int64, remindAt: Int64, repeatRule: String) -> Todo {
        var t = self; t.kind = kind; t.parent = parent; t.doneAt = doneAt
        t.remindAt = remindAt; t.repeatRule = repeatRule; return t
    }
}
