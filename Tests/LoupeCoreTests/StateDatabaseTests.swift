import Testing
import Foundation
@testable import LoupeCore

@Suite struct StateDatabaseTests {
    private let fm = FileManager.default

    private func tempDir() -> URL {
        fm.temporaryDirectory.appendingPathComponent("loupe-state-\(UUID().uuidString)")
    }

    private func folder(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private func names(_ dir: URL) throws -> Set<String> { Set(try fm.contentsOfDirectory(atPath: dir.path)) }

    @Test func createsTheSchemaAtVersionTwo() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        #expect(db.url.lastPathComponent == "Loupe.db")
        var version: Int64 = 0
        var tables: [String] = []
        try db.perform {
            try $0.query("PRAGMA user_version", []) { version = $0.int(0) }
            try $0.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name", []) { tables.append($0.text(0)) }
        }
        #expect(version == 2)   // the browser's tables and the visit columns are additive: an older Loupe opens it
        #expect(tables == ["browser_pins", "browser_state", "file_views", "folder_positions", "folder_settings", "recent", "sessions"])
        var columns: [String] = []
        try db.perform { try $0.query("SELECT name FROM pragma_table_info('folder_positions')", []) { columns.append($0.text(0)) } }
        #expect(columns == ["path", "file", "view", "touched", "idx", "count", "visited"])
    }

    /// Ruling R9: a version 2 file gains the visit columns and stays at version 2, so an older Loupe still opens it.
    @Test func version2FileGainsTheVisitColumns() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = try SQLiteConnection(path: dir.appendingPathComponent("Loupe.db").path, pragmas: [])
        try old.execute("""
            CREATE TABLE folder_positions(path TEXT PRIMARY KEY, file TEXT NOT NULL, view TEXT, touched INTEGER NOT NULL);
            INSERT INTO folder_positions VALUES('/photos/a', 'a1.jpg', NULL, 1);
            INSERT INTO folder_positions VALUES('/photos/b', 'b2.jpg', NULL, 2);
            PRAGMA user_version = 2;
            """)
        old.close()
        let db = try StateDatabase(directory: dir)
        var version: Int64 = 0
        var columns: [String] = []
        try db.perform {
            try $0.query("PRAGMA user_version", []) { version = $0.int(0) }
            try $0.query("SELECT name FROM pragma_table_info('folder_positions')", []) { columns.append($0.text(0)) }
        }
        #expect(version == 2)
        #expect(columns == ["path", "file", "view", "touched", "idx", "count", "visited"])
        let positions = FolderPositions(database: db)
        #expect(positions.count == 2)
        #expect(positions.fileName(in: folder("/photos/a")) == "a1.jpg")
        #expect(positions.fileName(in: folder("/photos/b")) == "b2.jpg")
        #expect(positions.visit(in: folder("/photos/a")) == nil)
        // Opened again: the columns are there, nothing changes.
        _ = try StateDatabase(directory: dir)
    }

    /// Ruling R9: a file a pre-release build stamped version 3 (the same tables, the visit columns in) is opened with
    /// its rows and visits, and stamped 2 again so older builds open it.
    @Test func version3FileIsAcceptedAndStampedTwo() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = try SQLiteConnection(path: dir.appendingPathComponent("Loupe.db").path, pragmas: [])
        try old.execute("""
            CREATE TABLE folder_positions(path TEXT PRIMARY KEY, file TEXT NOT NULL, view TEXT, touched INTEGER NOT NULL,
                idx INTEGER, count INTEGER, visited REAL);
            INSERT INTO folder_positions VALUES('/photos/a', 'a1.jpg', NULL, 1, 4, 9, 1000000);
            CREATE TABLE folder_settings(path TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
                touched INTEGER NOT NULL, PRIMARY KEY(path, key));
            PRAGMA user_version = 3;
            """)
        old.close()
        let db = try StateDatabase(directory: dir)
        var version: Int64 = 0
        try db.perform { try $0.query("PRAGMA user_version", []) { version = $0.int(0) } }
        #expect(version == 2)
        let positions = FolderPositions(database: db)
        #expect(positions.fileName(in: folder("/photos/a")) == "a1.jpg")
        #expect(positions.visit(in: folder("/photos/a"))
                == FolderVisit(index: 4, count: 9, visited: Date(timeIntervalSinceReferenceDate: 1_000_000)))
    }

    @Test func bothStoresShareOneDatabaseAcrossInstances() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let positions = FolderPositions(database: db)
        let settings = FolderSettings(database: db)
        positions.record(folder: folder("/photos/x"), file: "x.jpg")
        settings.set("downscale", "mitchell", for: folder("/photos/x"))
        positions.flush()
        settings.flush()

        let again = try StateDatabase(directory: dir)
        #expect(FolderPositions(database: again).fileName(in: folder("/photos/x")) == "x.jpg")
        #expect(FolderSettings(database: again).ownValues(for: folder("/photos/x")) == ["downscale": "mitchell"])
    }

    @Test func oldJSONFilesAreIgnoredAndLeftUntouched() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let positions = Data(#"{"version":1,"folders":[{"path":"/photos/a","file":"a1.jpg"}]}"#.utf8)
        let settings = Data("{ not json".utf8)
        try positions.write(to: dir.appendingPathComponent("folder-positions.json"))
        try settings.write(to: dir.appendingPathComponent("folder-settings.json"))
        let db = try StateDatabase(directory: dir)
        #expect(FolderPositions(database: db).count == 0)
        #expect(FolderSettings(database: db).count == 0)
        #expect(try names(dir).filter { $0.hasPrefix("folder-") } == ["folder-positions.json", "folder-settings.json"] as Set)
        #expect(try Data(contentsOf: dir.appendingPathComponent("folder-positions.json")) == positions)
        #expect(try Data(contentsOf: dir.appendingPathComponent("folder-settings.json")) == settings)
    }

    @Test func corruptDatabaseIsSetAsideAndRecreated() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let garbage = Data(repeating: 0x5A, count: 8192)
        try garbage.write(to: dir.appendingPathComponent("Loupe.db"))
        try Data("old".utf8).write(to: dir.appendingPathComponent("Loupe.db.broken-1000"))   // set aside before
        let db = try StateDatabase(directory: dir)
        let positions = FolderPositions(database: db)
        #expect(positions.count == 0)
        positions.record(folder: folder("/photos/a"), file: "a.jpg")
        positions.flush()
        #expect(FolderPositions(database: try StateDatabase(directory: dir)).fileName(in: folder("/photos/a")) == "a.jpg")
        let broken = try names(dir).filter { $0.hasPrefix("Loupe.db.broken-") }
        #expect(broken.count == 1)                                     // only the newest is kept
        #expect(broken.first != "Loupe.db.broken-1000")
        #expect(try Data(contentsOf: dir.appendingPathComponent(try #require(broken.first))) == garbage)
    }

    @Test func aDatabaseFromANewerLoupeIsLeftAloneAndNotOpened() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Loupe.db").path
        let other = try SQLiteConnection(path: path, pragmas: [])
        try other.execute("PRAGMA user_version = 4")
        other.close()
        #expect(throws: SQLiteError.self) { try StateDatabase(directory: dir) }
        #expect(!(try names(dir).contains { $0.hasPrefix("Loupe.db.broken-") }))      // not treated as damaged
    }

    @Test func nothingIsCreatedWithoutAnOpenedDatabase() throws {
        let positions = FolderPositions(database: nil)
        let settings = FolderSettings(database: nil)
        positions.record(folder: folder("/photos/a"), file: "a.jpg")
        settings.set("downscale", "mitchell", for: folder("/photos/a"))
        positions.flush()
        settings.flush()
        #expect(positions.fileName(in: folder("/photos/a")) == "a.jpg")
        #expect(settings.ownValues(for: folder("/photos/a")) == ["downscale": "mitchell"])
        #expect(positions.writes == 0 && settings.writes == 0)
    }
}
