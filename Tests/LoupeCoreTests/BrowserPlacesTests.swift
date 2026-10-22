import Testing
import Foundation
@testable import LoupeCore

@Suite struct BrowserPlacesTests {
    private let fm = FileManager.default
    private func tempDir() -> URL { fm.temporaryDirectory.appendingPathComponent("loupe-places-\(UUID().uuidString)") }
    private func dir(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// A v2 Loupe.db (Home's tables, made by a Loupe without the browser) gets the browser's tables and stays v2,
    /// so that Loupe can still open it.
    @Test func schema2FileUpgradesKeepingRows() throws {
        let home = tempDir()
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let old = try SQLiteConnection(path: home.appendingPathComponent("Loupe.db").path, pragmas: [])
        try old.execute("""
            CREATE TABLE recent(path TEXT PRIMARY KEY, kind TEXT NOT NULL, gallery_id TEXT, gallery_list BLOB,
                gallery_index INTEGER, gallery_count INTEGER, title TEXT, file TEXT, idx INTEGER, count INTEGER,
                opened REAL NOT NULL, hidden INTEGER NOT NULL DEFAULT 0);
            INSERT INTO recent(path, kind, opened) VALUES('/p', 'folder', 1);
            PRAGMA user_version = 2;
            """)
        old.close()
        let db = try StateDatabase(directory: home)
        var rows = 0
        try db.perform { try $0.query("SELECT COUNT(*) FROM recent", []) { rows = Int($0.int(0)) } }
        #expect(rows == 1)
        var version: Int64 = 0
        try db.perform { try $0.query("PRAGMA user_version", []) { version = $0.int(0) } }
        #expect(version == 3)
        let places = BrowserPlaces(database: db)
        places.pin(dir("/a"))
        #expect(places.pins() == [dir("/a")])
    }

    @Test func pinsInPinnedOrder() {
        let p = BrowserPlaces(database: nil)
        p.pin(dir("/b")); p.pin(dir("/a")); p.pin(dir("/c"))
        #expect(p.pins().map(\.path) == ["/b", "/a", "/c"])
        p.unpin(dir("/a"))
        #expect(p.pins().map(\.path) == ["/b", "/c"])
        #expect(p.isPinned(dir("/b")))
        #expect(!p.isPinned(dir("/a")))
    }

    @Test func pinTwiceIsOnce() {
        let p = BrowserPlaces(database: nil)
        p.pin(dir("/a")); p.pin(dir("/b")); p.pin(dir("/a"))
        #expect(p.pins().map(\.path) == ["/a", "/b"])
    }

    @Test func lastFolderPersistsAcrossReopen() throws {
        let home = tempDir()
        defer { try? fm.removeItem(at: home) }
        do {
            let p = BrowserPlaces(database: try StateDatabase(directory: home))
            p.lastFolder = dir("/Volumes/T/x")
            p.pin(dir("/Volumes/T"))
        }
        let again = BrowserPlaces(database: try StateDatabase(directory: home))
        #expect(again.lastFolder?.path == "/Volumes/T/x")
        #expect(again.pins().map(\.path) == ["/Volumes/T"])
        again.lastFolder = nil
        #expect(BrowserPlaces(database: try StateDatabase(directory: home)).lastFolder == nil)
    }

    @Test func movePathsRewritesNested() {
        let p = BrowserPlaces(database: nil)
        p.pin(dir("/x/old")); p.pin(dir("/x/old/sub")); p.pin(dir("/x/older"))
        p.lastFolder = dir("/x/old/sub/deep")
        p.movePaths(from: dir("/x/old"), to: dir("/x/new"))
        #expect(p.pins().map(\.path) == ["/x/new", "/x/new/sub", "/x/older"])
        #expect(p.lastFolder?.path == "/x/new/sub/deep")
    }

    @Test func inMemoryWithoutDatabase() {
        let p = BrowserPlaces(database: nil)
        #expect(p.pins().isEmpty)
        #expect(p.lastFolder == nil)
        p.lastFolder = dir("/a")
        #expect(p.lastFolder?.path == "/a")
    }
}
