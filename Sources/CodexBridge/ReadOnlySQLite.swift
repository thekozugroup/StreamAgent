import Foundation
import SQLite3

enum DatabaseFailure: Error {
    case unavailable, unsupported, query(Int32)
}

/// No write/create flags, no migrations, no network, no extensions, no error bodies in diagnostics.
final class ReadOnlySQLite {
    private var handle: OpaquePointer?
    private let deadline: Date
    private var columnCache: [String: Set<String>] = [:]

    init(url: URL, deadline: Date) throws {
        self.deadline = deadline
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK, let opened = db else {
            if let db = db { sqlite3_close(db) }
            throw DatabaseFailure.unavailable
        }
        handle = opened
        guard sqlite3_db_readonly(opened, "main") == 1 else {
            sqlite3_close(opened)
            handle = nil
            throw DatabaseFailure.unavailable
        }
        sqlite3_busy_timeout(opened, 60)
        sqlite3_limit(opened, SQLITE_LIMIT_LENGTH, 8 * 1024 * 1024)
        sqlite3_progress_handler(opened, 1000, { context in
            guard let context = context else { return 1 }
            let db = Unmanaged<ReadOnlySQLite>.fromOpaque(context).takeUnretainedValue()
            return Date() > db.deadline ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        if let handle = handle {
            sqlite3_progress_handler(handle, 0, nil, nil)
            sqlite3_close(handle)
        }
    }

    func rows(_ sql: String, bindings: [String] = [], visit: (SQLiteRow) throws -> Void) throws {
        guard let handle = handle, Date() <= deadline else { throw DatabaseFailure.query(SQLITE_INTERRUPT) }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement = statement else { throw DatabaseFailure.query(prepare) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bindings.enumerated() {
            let code = sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient)
            guard code == SQLITE_OK else { throw DatabaseFailure.query(code) }
        }
        while true {
            guard Date() <= deadline else { throw DatabaseFailure.query(SQLITE_INTERRUPT) }
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw DatabaseFailure.query(code) }
            try visit(SQLiteRow(statement: statement))
        }
    }

    func columns(_ table: String) throws -> Set<String> {
        // All callers use fixed, internal table names.
        guard ["threads", "projects", "project_roots", "thread_turns", "thread_items"].contains(table) else {
            throw DatabaseFailure.unsupported
        }
        if let cached = columnCache[table] { return cached }
        var names = Set<String>()
        try rows("PRAGMA table_info(\"\(table)\")") { row in names.insert(row.string(1)) }
        columnCache[table] = names
        return names
    }
}

struct SQLiteRow {
    let statement: OpaquePointer

    func string(_ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    func number(_ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }
}
