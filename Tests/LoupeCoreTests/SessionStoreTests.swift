import Foundation
import Testing
@testable import LoupeCore

@Suite struct SessionStoreTests {
    private let fm = FileManager.default
    private func tempDir() -> URL { fm.temporaryDirectory.appendingPathComponent("loupe-sessions-\(UUID().uuidString)") }

    private final class Clock: @unchecked Sendable {
        private var t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func next() -> Date { t = t.addingTimeInterval(1); return t }
    }

    private func store(_ db: StateDatabase?) -> SessionStore {
        let clock = Clock()
        return SessionStore(database: db, debounce: .seconds(60), now: { clock.next() })
    }

    private func snapshot(_ path: String) -> SessionSnapshot {
        SessionSnapshot(windows: [.init(frame: .zero, screen: nil, fullScreen: false, selected: 0,
                                        tabs: [.file(path: path, view: nil)])])
    }

    /// The next launch on the same database: this run's Last Session is the one shown then.
    private func nextRun(_ db: StateDatabase) -> SessionStore {
        let s = store(db)
        s.beginRun()
        return s
    }

    private let homeOnly = SessionSnapshot(windows: [.init(frame: .zero, screen: nil, fullScreen: false, selected: 0,
                                                            tabs: [.home(.recent)])])

    /// Last Session is the previous run's: what this run opens does not replace it until the next launch.
    @Test func previousRunStaysLastWhileThisRunSaves() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let first = store(try StateDatabase(directory: dir))
        first.beginRun()
        first.saveLast(snapshot("/old.jpg"))
        await first.flush()
        let second = store(try StateDatabase(directory: dir))
        second.beginRun()
        #expect(await second.last() == snapshot("/old.jpg"))
        second.saveLast(snapshot("/new.jpg"))
        await second.flush()
        #expect(await second.last() == snapshot("/old.jpg"))
        #expect(await second.all().filter(\.isLast).count == 1)
        let third = store(try StateDatabase(directory: dir))
        third.beginRun()
        #expect(await third.last() == snapshot("/new.jpg"))
    }

    /// A run that opened nothing but Home keeps the session before it.
    @Test func emptyRunKeepsTheOneBefore() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let first = store(try StateDatabase(directory: dir))
        first.beginRun()
        first.saveLast(snapshot("/old.jpg"))
        await first.flush()
        store(try StateDatabase(directory: dir)).beginRun()   // a run that saved nothing
        let third = store(try StateDatabase(directory: dir))
        third.beginRun()
        #expect(await third.last() == snapshot("/old.jpg"))
    }

    @Test func lastSessionKeptOverHomeOnly() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        s.saveLast(snapshot("/a.jpg"))
        s.saveLast(homeOnly)
        await s.flush()
        #expect(await nextRun(db).last() == snapshot("/a.jpg"))
    }

    /// Spec §2.6: windows showing only Home are not kept in Last Session.
    @Test func homeOnlyWindowsLeftOut() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        let mixed = SessionSnapshot(windows: homeOnly.windows + snapshot("/a.jpg").windows)
        s.saveLast(mixed)
        await s.flush()
        #expect(await nextRun(db).last() == snapshot("/a.jpg"))
    }

    /// Review Focus 3: a quit inside the debounce keeps Last Session.
    @Test func lastFlushOnQuit() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        s.saveLast(snapshot("/a.jpg"))
        await s.flush()
        #expect(await nextRun(db).last() == snapshot("/a.jpg"))
    }

    @Test func orderRenameReplaceDelete() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        #expect(await s.save(snapshot("/1.jpg"), name: "One") == .saved)
        #expect(await s.save(snapshot("/2.jpg"), name: "Two") == .saved)
        s.saveLast(snapshot("/last.jpg"))
        await s.flush()
        var all = await nextRun(db).all()
        #expect(all.map(\.name) == ["Last Session", "Two", "One"])
        #expect(all.first?.isLast == true)
        let one = try #require(all.first { $0.name == "One" })
        #expect(await s.rename(one, to: "Two") == .nameTaken)
        #expect(await s.rename(one, to: "Uno") == .saved)
        let renamed = try #require(await s.all().first { $0.id == one.id })
        #expect(await s.replace(renamed, with: snapshot("/9.jpg")) == .saved)
        let attempt = await s.save(snapshot("/2b.jpg"), name: "Two")
        guard case .confirmationRequired(let confirmation) = attempt else {
            Issue.record("Expected a replacement prompt, got \(attempt)")
            return
        }
        #expect(await s.save(snapshot("/2b.jpg"), name: "Two", replacing: confirmation) == .saved)
        all = await store(db).all()
        #expect(all.map(\.name) == ["Last Session", "Two", "Uno"])
        #expect(all.first { $0.name == "Uno" }?.snapshot == snapshot("/9.jpg"))
        #expect(all.first { $0.name == "Two" }?.snapshot == snapshot("/2b.jpg"))
        let updated = try #require(all.first { $0.id == one.id })
        #expect(await s.delete(updated) == .saved)
        #expect(await store(db).all().map(\.name) == ["Last Session", "Two"])
    }

    @Test func renameAfterDeletionDoesNotReportSuccess() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let firstWindow = store(db)
        let secondWindow = store(db)
        #expect(await firstWindow.save(snapshot("/one.jpg"), name: "One") == .saved)
        let shown = try #require(await firstWindow.all().first)
        #expect(await secondWindow.delete(shown) == .saved)
        #expect(await firstWindow.rename(shown, to: "Renamed") == .missing)
        #expect(await firstWindow.all().isEmpty)
    }

    @Test func renameWithoutDatabaseDoesNotReportSuccess() async {
        let session = SavedSession(id: 1, name: "One", saved: .distantPast, isLast: false, snapshot: homeOnly)
        #expect(await store(nil).rename(session, to: "Renamed") == .unavailable)
    }

    @Test func rejectedRenameDoesNotReportSuccess() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        #expect(await s.save(snapshot("/one.jpg"), name: "One") == .saved)
        let shown = try #require(await s.all().first)
        try db.perform {
            try $0.execute("CREATE TRIGGER reject_rename BEFORE UPDATE ON sessions BEGIN SELECT RAISE(ABORT, 'test'); END")
        }
        #expect(await s.rename(shown, to: "Renamed") == .writeFailed)
        #expect(await s.all().map(\.name) == ["One"])
    }

    @Test func badJSONRowIsSkipped() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        _ = try db.perform { try $0.run("INSERT INTO sessions(name, saved, is_last, json) VALUES('Bad', 1, 0, ?)", [.blob(Data("{".utf8))]) }
        #expect(await store(db).save(snapshot("/1.jpg"), name: "Good") == .saved)
        #expect(await store(db).all().map(\.name) == ["Good"])
    }

    @Test func existingSchema2SessionsKeepTheirRecordsAndCanBeRenamed() async throws {
        let dir = tempDir()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent(StateDatabase.fileName).path
        let old = try SQLiteConnection(path: path, pragmas: [])
        try old.execute("""
            CREATE TABLE sessions(id INTEGER PRIMARY KEY, name TEXT NOT NULL, saved REAL NOT NULL,
                is_last INTEGER NOT NULL DEFAULT 0, json BLOB NOT NULL);
            CREATE UNIQUE INDEX sessions_name ON sessions(name) WHERE is_last = 0;
            PRAGMA user_version = 2;
            """)
        let previous = snapshot("/previous.jpg")
        let named = snapshot("/named.jpg")
        try old.run("INSERT INTO sessions(name, saved, is_last, json) VALUES('Last Session', 1, 1, ?)", [.blob(previous.encoded())])
        try old.run("INSERT INTO sessions(name, saved, json) VALUES('Earlier', 2, ?)", [.blob(named.encoded())])
        old.close()

        let current = store(try StateDatabase(directory: dir))
        #expect(await current.last() == previous)
        let existing = try #require(await current.all().first { $0.name == "Earlier" })
        #expect(existing.snapshot == named)
        #expect(await current.rename(existing, to: "Renamed") == .saved)
        #expect(await current.all().map(\.name) == ["Last Session", "Renamed"])
    }

    @Test func staleSaveAsConfirmationCannotReplaceAnEditedOrRecreatedSession() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let firstWindow = store(db)
        let secondWindow = store(db)
        #expect(await firstWindow.save(snapshot("/original.jpg"), name: "One") == .saved)
        let original = try #require(await firstWindow.all().first)
        let desired = snapshot("/desired.jpg")
        guard case .confirmationRequired(let first) = await firstWindow.save(desired, name: "One") else {
            Issue.record("Expected the first replacement prompt")
            return
        }

        #expect(await secondWindow.replace(original, with: snapshot("/edited.jpg")) == .saved)
        guard case .confirmationRequired(let edited) = await firstWindow.save(desired, name: "One", replacing: first) else {
            Issue.record("Expected fresh confirmation after the edit")
            return
        }
        let current = try #require(await secondWindow.all().first)
        #expect(current.snapshot == snapshot("/edited.jpg"))
        #expect(await secondWindow.delete(current) == .saved)
        #expect(await secondWindow.save(snapshot("/recreated.jpg"), name: "One") == .saved)
        guard case .confirmationRequired(let recreated) = await firstWindow.save(desired, name: "One", replacing: edited) else {
            Issue.record("Expected fresh confirmation after the name was reused")
            return
        }
        #expect(await firstWindow.rename(original, to: "Stale") == .changed)
        #expect(await firstWindow.all().first?.snapshot == snapshot("/recreated.jpg"))
        #expect(await firstWindow.save(desired, name: "One", replacing: recreated) == .saved)
        let reopened = store(try StateDatabase(directory: dir))
        #expect(await reopened.all().map(\.snapshot) == [desired])
    }

    @Test func readsOfPreviousRunLeavePendingCurrentRunAlone() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let previous = store(db)
        previous.saveLast(snapshot("/previous.jpg"))
        await previous.flush()
        let current = nextRun(db)
        current.saveLast(snapshot("/current.jpg"))

        #expect(await current.last() == snapshot("/previous.jpg"))
        #expect(await current.all().map(\.snapshot) == [snapshot("/previous.jpg")])
        var currentRowCount = 0
        try db.perform { db in
            try db.query("SELECT COUNT(*) FROM sessions WHERE is_last = 2", []) { currentRowCount = Int($0.int(0)) }
        }
        #expect(currentRowCount == 0)

        await current.flush()
        let reopened = nextRun(try StateDatabase(directory: dir))
        #expect(await reopened.last() == snapshot("/current.jpg"))
    }
}
