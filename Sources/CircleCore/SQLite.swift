import Foundation
import SQLite3

public struct DBError: Error, CustomStringConvertible {
    public let description: String
    init(_ m: String) { description = m }
}

public enum SQLValue {
    case text(String), int(Int64), real(Double), null
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin SQLite wrapper with a prepared-statement cache. Not thread safe:
/// each owner keeps it on one serial queue.
public final class SQLiteDB {
    let handle: OpaquePointer
    private var cache: [String: OpaquePointer] = [:]

    public init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            throw DBError("could not open \(path)")
        }
        handle = h
        sqlite3_busy_timeout(h, 3000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;")
    }

    deinit {
        for (_, s) in cache { sqlite3_finalize(s) }
        sqlite3_close(handle)
    }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError(m)
        }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer {
        let stmt: OpaquePointer
        if let s = cache[sql] {
            stmt = s
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
        } else {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else {
                throw DBError(String(cString: sqlite3_errmsg(handle)))
            }
            cache[sql] = s
            stmt = s
        }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    /// Runs a write statement, returns number of rows changed.
    @discardableResult
    public func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        let s = try prepare(sql, args)
        defer { sqlite3_reset(s) }
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ args: [SQLValue] = [], _ each: (Row) -> Void) throws {
        let s = try prepare(sql, args)
        defer { sqlite3_reset(s) }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { each(Row(stmt: s)) }
            else if rc == SQLITE_DONE { break }
            else { throw DBError(String(cString: sqlite3_errmsg(handle))) }
        }
    }

    public func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") }
        catch { try? exec("ROLLBACK"); throw error }
    }

    public struct Row {
        let stmt: OpaquePointer
        public func text(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        public func real(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    }
}
