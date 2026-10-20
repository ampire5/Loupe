import Foundation
import SQLite3

/// A failed SQLite call: the result code (`SQLITE_CORRUPT`, `SQLITE_NOTADB`, …) and SQLite's own message.
public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "SQLite error \(code): \(message)" }
}

/// A value bound to a `?` parameter.
public enum SQLiteValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

/// The current row of a query, valid only inside the `row` closure. Columns are numbered from 0.
public struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    public func int(_ column: Int) -> Int64 { sqlite3_column_int64(statement, Int32(column)) }
    public func double(_ column: Int) -> Double { sqlite3_column_double(statement, Int32(column)) }

    public func text(_ column: Int) -> String {
        guard let chars = sqlite3_column_text(statement, Int32(column)) else { return "" }
        return String(cString: chars)
    }

    public func blob(_ column: Int) -> Data {
        // The pointer comes first: asking for the byte count before it could convert a text value under it.
        guard let bytes = sqlite3_column_blob(statement, Int32(column)) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, Int32(column))))
    }

    public func isNull(_ column: Int) -> Bool { sqlite3_column_type(statement, Int32(column)) == SQLITE_NULL }
}

/// One connection to one database file over the system SQLite. Not thread-safe: its owner (an actor)
/// calls it serially. Statements are prepared once per SQL text and reused, so callers pass fixed SQL
/// with `?` parameters, never values spliced into the text.
public final class SQLiteConnection {
    public let path: String
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    /// The file as it was right after opening; a different one at `path` means it was deleted or replaced
    /// while open, and everything written through this connection goes to an unlinked file.
    private let device: dev_t
    private let inode: ino_t

    /// SQLite's "copy the bytes now" destructor, which Swift does not import.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (creating if needed) the database at `path` and applies `pragmas` in order, each as
    /// `PRAGMA <pragma>` (`"journal_mode=WAL"`). Pragmas that fix the file layout (`page_size`,
    /// `auto_vacuum`) only take effect on a new file and must come before `journal_mode=WAL`, which writes
    /// the header. The file's header is read before returning, so a file that is not a database fails here
    /// (`SQLITE_NOTADB`) rather than at the first query.
    public init(path: String, pragmas: [String]) throws {
        self.path = path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: rc, message: message)
        }
        db = handle
        do {
            for pragma in pragmas { try Self.exec(handle, "PRAGMA " + pragma) }
            try Self.exec(handle, "SELECT count(*) FROM sqlite_master")
        } catch {
            sqlite3_close_v2(handle)
            db = nil
            throw error
        }
        // The pragmas and the header read have created the file if it was missing.
        var st = stat()
        guard stat(path, &st) == 0 else {
            sqlite3_close_v2(handle)
            db = nil
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "no file at \(path) after opening")
        }
        device = st.st_dev
        inode = st.st_ino
    }

    deinit { close() }

    /// Finalizes the statements and closes the connection; any later call throws `SQLITE_MISUSE`.
    public func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    /// True when `path` no longer exists or names a different file than the one opened.
    public var fileChanged: Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return true }
        return st.st_dev != device || st.st_ino != inode
    }

    /// Runs `sql`, which may hold several statements and no parameters (schema, pragmas, BEGIN/COMMIT).
    public func execute(_ sql: String) throws {
        try Self.exec(try handle(), sql)
    }

    /// Runs a query and calls `row` for each result row.
    public func query(_ sql: String, _ args: [SQLiteValue], row: (SQLiteRow) throws -> Void) throws {
        let statement = try prepared(sql, args)
        defer { sqlite3_reset(statement) }
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw lastError(rc) }
            try row(SQLiteRow(statement: statement))
        }
    }

    /// Runs a statement that returns no rows (rows it does return are skipped); returns the last
    /// inserted rowid.
    @discardableResult
    public func run(_ sql: String, _ args: [SQLiteValue]) throws -> Int64 {
        try query(sql, args) { _ in }
        return sqlite3_last_insert_rowid(try handle())
    }

    /// Runs `body` in one write transaction (`BEGIN IMMEDIATE`, so a second process makes it wait at the
    /// start via `busy_timeout` instead of failing at commit); a throw rolls everything back.
    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func handle() throws -> OpaquePointer {
        guard let db else { throw SQLiteError(code: SQLITE_MISUSE, message: "connection to \(path) is closed") }
        return db
    }

    private func prepared(_ sql: String, _ args: [SQLiteValue]) throws -> OpaquePointer {
        let db = try handle()
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var made: OpaquePointer?
            let rc = sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &made, nil)
            guard rc == SQLITE_OK, let made else { throw lastError(rc) }
            statements[sql] = made
            statement = made
        }
        sqlite3_clear_bindings(statement)
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch arg {
            case .int(let v): rc = sqlite3_bind_int64(statement, index, v)
            case .double(let v): rc = sqlite3_bind_double(statement, index, v)
            case .text(let v): rc = sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .blob(let v):
                // An empty Data has no base address, and a null pointer would bind NULL instead of an empty blob.
                rc = v.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            case .null: rc = sqlite3_bind_null(statement, index)
            }
            guard rc == SQLITE_OK else { throw lastError(rc) }
        }
        return statement
    }

    private func lastError(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "connection closed")
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard rc == SQLITE_OK else {
            throw SQLiteError(code: rc, message: message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db)))
        }
    }
}
