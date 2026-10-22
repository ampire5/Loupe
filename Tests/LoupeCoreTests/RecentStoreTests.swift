import Testing
import Foundation
@testable import LoupeCore

@Suite struct RecentStoreTests {
    private let fm = FileManager.default

    private func tempDir() -> URL { fm.temporaryDirectory.appendingPathComponent("loupe-recent-\(UUID().uuidString)") }
    private func folder(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// A clock that moves one second per call: every `entered` is newer than the one before.
    private final class Clock: @unchecked Sendable {
        private var t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func next() -> Date { t = t.addingTimeInterval(1); return t }
    }

    private func store(_ db: StateDatabase? = nil, debounce: Duration = .seconds(60)) -> RecentStore {
        let clock = Clock()
        return RecentStore(database: db, debounce: debounce, now: { clock.next() })
    }

    private func enter(_ s: RecentStore, _ path: String, gallery: RecentGallery? = nil, clears: Bool = false) {
        s.entered(folder(path), kind: .folder, gallery: gallery, title: nil, clearsGallery: clears)
    }

    /// A v1 Loupe.db (folder_positions only) opens as v2 with its row kept and the two new tables made.
    @Test func schemaTwoAddsTablesKeepsData() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = try SQLiteConnection(path: dir.appendingPathComponent("Loupe.db").path, pragmas: [])
        try old.execute("""
            CREATE TABLE folder_positions(path TEXT PRIMARY KEY, file TEXT NOT NULL, view TEXT, touched INTEGER NOT NULL);
            INSERT INTO folder_positions VALUES('/p', 'a.jpg', NULL, 1);
            PRAGMA user_version = 1;
            """)
        old.close()
        let db = try StateDatabase(directory: dir)
        var rows = 0, tables: [String] = []
        try db.perform {
            try $0.query("SELECT COUNT(*) FROM folder_positions", []) { rows = Int($0.int(0)) }
            try $0.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name", []) { tables.append($0.text(0)) }
        }
        #expect(rows == 1)
        #expect(tables.contains("recent") && tables.contains("sessions"))
    }

    /// One folder's entry by its path, hidden or not (a folder card's progress before it has a visit).
    @Test func entryOfAFolder() {
        let s = store()
        enter(s, "/p/a")
        s.viewed(folder("/p/a"), file: "x.jpg", index: 4, count: 12)
        s.hide("/p/a")
        #expect(s.entry(for: folder("/p/a"))?.index == 4 && s.entry(for: folder("/p/a"))?.count == 12)
        #expect(s.entry(for: folder("/p/b")) == nil)
    }

    @Test func enteredMovesToFront() {
        let s = store()
        enter(s, "/a"); enter(s, "/b"); enter(s, "/a")
        #expect(s.shown(limit: 24).map(\.path) == ["/a", "/b"])
    }

    @Test func hiddenUntilEnteredAgain() {
        let s = store()
        enter(s, "/a"); enter(s, "/b")
        s.hide("/a")
        #expect(s.shown(limit: 24).map(\.path) == ["/b"])
        s.viewed(folder("/a"), file: "x.jpg", index: 3, count: 10)
        #expect(s.shown(limit: 24).map(\.path) == ["/b"])
        enter(s, "/a")
        #expect(s.shown(limit: 24).map(\.path) == ["/a", "/b"])
        #expect(s.shown(limit: 24).first?.file == "x.jpg" && s.shown(limit: 24).first?.index == 3)
    }

    @Test func hideAllHidesEverything() {
        let s = store()
        enter(s, "/a"); enter(s, "/b")
        s.hideAll()
        #expect(s.shown(limit: 24).isEmpty)
    }

    @Test func limitAndCap() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        for i in 0..<205 { enter(s, "/f\(i)") }
        s.flush()
        let again = store(db)
        #expect(again.shown(limit: 200).count == 200)
        #expect(again.shown(limit: 200).first?.path == "/f204")
        #expect(again.shown(limit: 0).isEmpty)
        #expect(again.shown(limit: 3).count == 3)
        var rows = 0
        try db.perform { try $0.query("SELECT COUNT(*) FROM recent", []) { rows = Int($0.int(0)) } }
        #expect(rows == 200)
    }

    @Test func finderOpenClearsGallery() {
        let s = store()
        let g = RecentGallery(id: "g1", list: nil)
        enter(s, "/a", gallery: g)
        enter(s, "/a", gallery: nil, clears: false)
        #expect(s.shown(limit: 24).first?.gallery == g)
        enter(s, "/a", gallery: nil, clears: true)
        #expect(s.shown(limit: 24).first?.gallery == nil)
    }

    /// Review Focus 3: a quit inside the debounce still keeps the change.
    @Test func recentFlushOnQuit() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        enter(s, "/a")
        s.viewed(folder("/a"), file: "b.jpg", index: 1, count: 5)
        s.flush()
        let again = store(db).shown(limit: 24)
        #expect(again.map(\.path) == ["/a"])
        #expect(again.first?.file == "b.jpg" && again.first?.index == 1 && again.first?.count == 5)
    }

    @Test func listContextRoundTrip() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        let list = RecentGalleryList(variables: Data(#"{"filter":{"page":2}}"#.utf8), index: 27, count: 812)
        s.entered(folder("/g"), kind: .archive, gallery: RecentGallery(id: "77", list: list), title: "Tidy", clearsGallery: false)
        s.flush()
        let e = try #require(store(db).shown(limit: 24).first)
        #expect(e.gallery == RecentGallery(id: "77", list: list))
        #expect(e.kind == .archive && e.title == "Tidy" && e.displayTitle == "Tidy")
    }

    @Test func displayTitleFallsBackToName() {
        let s = store()
        enter(s, "/photos/Trip")
        #expect(s.shown(limit: 24).first?.displayTitle == "Trip")
        #expect(s.shown(limit: 24).first?.url == URL(fileURLWithPath: "/photos/Trip"))
    }
}
