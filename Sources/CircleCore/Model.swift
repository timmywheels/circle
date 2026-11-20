import Foundation

/// Who a todo is waiting on. Rendered as a shape; filled in when done.
public enum Kind: String, Codable, CaseIterable, Sendable {
    case mine = "todo"     // ○ ●  yours to do
    case agent             // △ ▲  handed to an agent
    case waiting = "wait"  // □ ■  waiting on something else

    public func glyph(done: Bool) -> String {
        switch self {
        case .mine: return done ? "●" : "○"
        case .agent: return done ? "▲" : "△"
        case .waiting: return done ? "■" : "□"
        }
    }
    public var next: Kind {
        let all = Kind.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

public struct Todo: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var kind: Kind
    /// Parent todo id, or "" for a top-level item.
    public var parent: String
    /// When it was filled in (ms), 0 while open.
    public var doneAt: Int64
    public var title: String
    public var notes: String
    public var done: Bool
    public var sort: Double
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deleted: Bool
    public var origin: String

    enum CodingKeys: String, CodingKey {
        case id, kind, parent, title, notes, done, sort, deleted, origin
        case createdAt = "created_at"
        case doneAt = "done_at"
        case updatedAt = "updated_at"
    }

    public init(id: String = Todo.newID(), kind: Kind = .mine, parent: String = "", title: String, notes: String = "", done: Bool = false,
                sort: Double, createdAt: Int64 = Clock.now(), updatedAt: Int64? = nil,
                deleted: Bool = false, origin: String, doneAt: Int64 = 0) {
        self.id = id; self.kind = kind; self.parent = parent; self.title = title; self.notes = notes; self.done = done
        self.sort = sort; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.deleted = deleted; self.origin = origin; self.doneAt = doneAt
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .mine   // older rows / unknown kinds
        parent = (try? c.decode(String.self, forKey: .parent)) ?? ""
        title = try c.decode(String.self, forKey: .title)
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        done = try c.decode(Bool.self, forKey: .done)
        sort = try c.decode(Double.self, forKey: .sort)
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
        updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        origin = try c.decode(String.self, forKey: .origin)
        doneAt = (try? c.decode(Int64.self, forKey: .doneAt)) ?? 0
    }

    public var glyph: String { kind.glyph(done: done) }

    /// Completion time, falling back to the last edit for rows made before done_at existed.
    public var completedAt: Int64 { doneAt > 0 ? doneAt : updatedAt }

    /// Fills in or reopens, stamping the completion time.
    public mutating func setDone(_ on: Bool) {
        done = on
        doneAt = on ? Clock.now() : 0
    }

    /// Last-writer-wins ordering. Ties broken by origin so every replica agrees.
    public func wins(over o: Todo) -> Bool {
        updatedAt != o.updatedAt ? updatedAt > o.updatedAt : origin > o.origin
    }

    /// Returns a copy stamped as a new local edit.
    public func touched(by origin: String) -> Todo {
        var t = self
        t.updatedAt = Clock.now()
        t.origin = origin
        return t
    }

    public static func newID() -> String {
        // Time-ordered, short, URL safe: 8 hex ms + 8 hex random.
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        return String(format: "%011llx%08x", ms, UInt32.random(in: 0...UInt32.max))
    }
}

public enum Clock {
    private static var last: Int64 = 0
    private static let lock = NSLock()
    /// Monotonic millisecond clock (never returns the same value twice in-process).
    public static func now() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let n = Int64(Date().timeIntervalSince1970 * 1000)
        last = max(n, last + 1)
        return last
    }
}

public enum Paths {
    public static let support: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Circle", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // One-time carry-over from the app's working name.
        let old = base.appendingPathComponent("Blink", isDirectory: true)
        if !fm.fileExists(atPath: dir.appendingPathComponent("circle.sqlite").path),
           fm.fileExists(atPath: old.appendingPathComponent("blink.sqlite").path) {
            for (from, to) in [("blink.sqlite", "circle.sqlite"), ("blink.sqlite-wal", "circle.sqlite-wal"),
                               ("blink.sqlite-shm", "circle.sqlite-shm"), ("sync.json", "sync.json")] {
                try? fm.copyItem(at: old.appendingPathComponent(from), to: dir.appendingPathComponent(to))
            }
        }
        return dir
    }()
    public static var database: URL { support.appendingPathComponent("circle.sqlite") }
    public static var syncConfig: URL { support.appendingPathComponent("sync.json") }
}

public struct SyncConfig: Codable {
    public var url: String
    public var token: String

    public static func load() -> SyncConfig? {
        guard let d = try? Data(contentsOf: Paths.syncConfig) else { return nil }
        return try? JSONDecoder().decode(SyncConfig.self, from: d)
    }

    public var socketURL: URL? {
        guard var c = URLComponents(string: url) else { return nil }
        c.scheme = (c.scheme == "http") ? "ws" : "wss"
        c.path = "/sync"
        return c.url
    }
}

public extension Todo {
    /// A title starting with "# " makes the row a section header.
    var isSection: Bool { title.hasPrefix("# ") }
    var displayTitle: String { isSection ? String(title.dropFirst(2)) : title }
}

/// [[wikilinks]] between todos, by title (case-insensitive).
public enum Links {
    private static let re = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n]{1,200})\]\]"#)

    public static func names(in text: String) -> [String] {
        guard text.contains("[[") else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Replaces [[old]] (any case) with [[new]].
    public static func rename(in text: String, from old: String, to new: String) -> String {
        guard text.contains("[[") else { return text }
        let pattern = "\\[\\[\\s*" + NSRegularExpression.escapedPattern(for: old) + "\\s*\\]\\]"
        guard let r = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let ns = text as NSString
        return r.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                          withTemplate: NSRegularExpression.escapedTemplate(for: "[[" + new + "]]"))
    }
}
