import Foundation
import SQLite3

/// A value bindable into a prepared SQLite statement.
public enum SQLiteValue: Sendable {
    case text(String)
    case int(Int64)
    case real(Double)
    case null
    case blob(Data)
}

/// A single result row from a `SQLiteDB.query` callback. Columns are read by
/// zero-based index; each accessor returns `nil` for a SQL NULL.
public struct SQLiteRow {
    private let statement: OpaquePointer

    init(statement: OpaquePointer) {
        self.statement = statement
    }

    public func string(_ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    public func int64(_ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    public func double(_ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    public func blob(_ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

/// Thin wrapper over the raw SQLite3 C API. Every failure is surfaced as
/// `AstroError.databaseError` carrying sqlite's own error message.
public final class SQLiteDB {
    private var handle: OpaquePointer?

    /// Opens (creating if needed) the database at `path`. Pass `":memory:"`
    /// for an ephemeral in-memory database. WAL mode is enabled for
    /// file-backed databases (skipped for `:memory:`, where it is a no-op
    /// SQLite would otherwise silently ignore anyway).
    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed (\(rc))"
            if let db { sqlite3_close(db) }
            throw AstroError.databaseError(message)
        }
        self.handle = db

        if path != ":memory:" {
            try exec("PRAGMA journal_mode=WAL;")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Executes one or more semicolon-separated statements with no bound
    /// parameters and no result rows (DDL, pragmas, etc).
    public func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(errorMessage)
            throw AstroError.databaseError(message)
        }
    }

    /// Runs a single statement with bound parameters, discarding any result
    /// rows. Use for INSERT/UPDATE/DELETE.
    public func run(_ sql: String, bind: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindValues(bind, to: statement)

        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw AstroError.databaseError(lastErrorMessage())
        }
    }

    /// Runs a single SELECT statement with bound parameters, invoking `row`
    /// once per result row.
    public func query(_ sql: String, bind: [SQLiteValue] = [], row: (SQLiteRow) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindValues(bind, to: statement)

        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                guard let statement else { break }
                try row(SQLiteRow(statement: statement))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw AstroError.databaseError(lastErrorMessage())
            }
        }
    }

    /// The rowid of the most recent successful INSERT on this connection.
    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw AstroError.databaseError(lastErrorMessage())
        }
        return statement
    }

    private func bindValues(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        // SQLITE_TRANSIENT: tells sqlite to copy the bound bytes, since the
        // Swift values backing them are not guaranteed to outlive the call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .text(let text):
                rc = sqlite3_bind_text(statement, index, text, -1, transient)
            case .int(let number):
                rc = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                rc = sqlite3_bind_double(statement, index, number)
            case .null:
                rc = sqlite3_bind_null(statement, index)
            case .blob(let data):
                rc = data.withUnsafeBytes { buffer -> Int32 in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), transient)
                }
            }
            guard rc == SQLITE_OK else {
                throw AstroError.databaseError(lastErrorMessage())
            }
        }
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}
