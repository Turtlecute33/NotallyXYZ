import Foundation
import SQLite3

public enum SQLiteError: Error {
    case open(String)
    case prepare(String)
    case step(String)
}

enum SQLValue {
    case int(Int64)
    case text(String)
    case blob(Data)
    case null
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal wrapper around the system SQLite. Used from the main actor only.
final class SQLite {
    private var db: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError.open(msg)
        }
        // secure_delete overwrites deleted content; WAL keeps writes cheap.
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON;")
    }

    deinit { sqlite3_close(db) }

    private var message: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteError.step(message) }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLiteError.prepare(message) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError.step(message) }
    }

    var changes: Int { Int(sqlite3_changes(db)) }

    func query(_ sql: String, _ args: [SQLValue] = [], _ row: (Row) throws -> Void) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError.step(message) }
            try row(Row(stmt: stmt))
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    struct Row {
        let stmt: OpaquePointer?
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func text(_ i: Int32) -> String? {
            sqlite3_column_text(stmt, i).map { String(cString: $0) }
        }
        func blob(_ i: Int32) -> Data? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: p, count: n)
        }
    }
}
