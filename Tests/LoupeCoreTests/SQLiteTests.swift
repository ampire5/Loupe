import Testing
import Foundation
@testable import LoupeCore

@Suite struct SQLiteTests {
    /// A database path in a fresh temp directory of its own.
    private func tempPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.db").path
    }

    @Test func roundTripsValues() throws {
        let db = try SQLiteConnection(path: tempPath(), pragmas: [])
        try db.execute("CREATE TABLE t(i INTEGER, d REAL, s TEXT, b BLOB, e BLOB, n)")
        let blob = Data([0, 1, 2, 255, 0])
        let date = Date(timeIntervalSinceReferenceDate: 781_234_567.123_456_7)
        let id = try db.run("INSERT INTO t VALUES(?, ?, ?, ?, ?, ?)",
                            [.int(-42), .double(date.timeIntervalSinceReferenceDate), .text("фото é"),
                             .blob(blob), .blob(Data()), .null])
        #expect(id == 1)
        var rows = 0
        try db.query("SELECT i, d, s, b, e, n FROM t", []) { r in
            rows += 1
            #expect(r.int(0) == -42)
            #expect(Date(timeIntervalSinceReferenceDate: r.double(1)) == date)   // bit-exact
            #expect(r.text(2) == "фото é")
            #expect(r.blob(3) == blob)
            #expect(!r.isNull(4))                                                 // empty, not NULL
            #expect(r.blob(4) == Data())
            #expect(r.isNull(5))
            #expect(!r.isNull(0))
        }
        #expect(rows == 1)
    }

    @Test func queryBindsArgumentsAndReusesTheStatement() throws {
        let db = try SQLiteConnection(path: tempPath(), pragmas: [])
        try db.execute("CREATE TABLE t(k TEXT PRIMARY KEY, v INTEGER)")
        for (k, v) in [("a", 1), ("b", 2), ("c", 3)] {
            _ = try db.run("INSERT INTO t VALUES(?, ?)", [.text(k), .int(Int64(v))])
        }
        for (k, v) in [("b", 2), ("c", 3), ("a", 1)] {
            var got: [Int64] = []
            try db.query("SELECT v FROM t WHERE k = ?", [.text(k)]) { got.append($0.int(0)) }
            #expect(got == [Int64(v)])
        }
    }

    @Test func transactionRollsBackOnThrow() throws {
        struct Boom: Error {}
        let db = try SQLiteConnection(path: tempPath(), pragmas: ["journal_mode=WAL"])
        try db.execute("CREATE TABLE t(v INTEGER)")
        try db.transaction { _ = try db.run("INSERT INTO t VALUES(1)", []) }
        #expect(throws: Boom.self) {
            try db.transaction {
                _ = try db.run("INSERT INTO t VALUES(2)", [])
                throw Boom()
            }
        }
        var values: [Int64] = []
        try db.query("SELECT v FROM t", []) { values.append($0.int(0)) }
        #expect(values == [1])
    }

    @Test func errorsCarryTheSQLiteCode() throws {
        let db = try SQLiteConnection(path: tempPath(), pragmas: [])
        #expect(throws: SQLiteError.self) { try db.execute("SELECT * FROM missing") }
        do {
            _ = try db.run("SELECT * FROM missing", [])
            Issue.record("expected an error")
        } catch let error as SQLiteError {
            #expect(error.code == 1)                     // SQLITE_ERROR
            #expect(error.message.contains("missing"))
        }
    }

    @Test func pragmasApplied() throws {
        let db = try SQLiteConnection(path: tempPath(),
                                      pragmas: ["page_size=16384", "auto_vacuum=INCREMENTAL", "journal_mode=WAL"])
        try db.execute("CREATE TABLE t(v INTEGER)")
        var mode = ""
        try db.query("PRAGMA journal_mode", []) { mode = $0.text(0) }
        #expect(mode == "wal")
        var pageSize: Int64 = 0
        try db.query("PRAGMA page_size", []) { pageSize = $0.int(0) }
        #expect(pageSize == 16384)
        var autoVacuum: Int64 = 0
        try db.query("PRAGMA auto_vacuum", []) { autoVacuum = $0.int(0) }
        #expect(autoVacuum == 2)                                // INCREMENTAL
    }

    @Test func fileChangedAfterDelete() throws {
        let path = try tempPath()
        let db = try SQLiteConnection(path: path, pragmas: ["journal_mode=WAL"])
        try db.execute("CREATE TABLE t(v INTEGER)")
        #expect(!db.fileChanged)
        try FileManager.default.removeItem(atPath: path)
        #expect(db.fileChanged)
    }

    @Test func fileChangedWhenReplacedByAnotherFile() throws {
        let path = try tempPath()
        let db = try SQLiteConnection(path: path, pragmas: [])
        try db.execute("CREATE TABLE t(v INTEGER)")
        try FileManager.default.removeItem(atPath: path)
        let other = try SQLiteConnection(path: path, pragmas: [])     // a new file at the same path
        try other.execute("CREATE TABLE u(v INTEGER)")
        #expect(db.fileChanged)
        #expect(!other.fileChanged)
    }
}
