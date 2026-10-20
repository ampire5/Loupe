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
    @Test func previousRunStaysLastWhileThisRunSaves() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let first = store(try StateDatabase(directory: dir))
        first.beginRun()
        first.saveLast(snapshot("/old.jpg"))
        first.flush()
        let second = store(try StateDatabase(directory: dir))
        second.beginRun()
        #expect(second.last() == snapshot("/old.jpg"))
        second.saveLast(snapshot("/new.jpg"))
        second.flush()
        #expect(second.last() == snapshot("/old.jpg"))
        #expect(second.all().filter(\.isLast).count == 1)
        let third = store(try StateDatabase(directory: dir))
        third.beginRun()
        #expect(third.last() == snapshot("/new.jpg"))
    }

    /// A run that opened nothing but Home keeps the session before it.
    @Test func emptyRunKeepsTheOneBefore() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let first = store(try StateDatabase(directory: dir))
        first.beginRun()
        first.saveLast(snapshot("/old.jpg"))
        first.flush()
        store(try StateDatabase(directory: dir)).beginRun()   // a run that saved nothing
        let third = store(try StateDatabase(directory: dir))
        third.beginRun()
        #expect(third.last() == snapshot("/old.jpg"))
    }

    @Test func lastSessionKeptOverHomeOnly() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        s.saveLast(snapshot("/a.jpg"))
        s.saveLast(homeOnly)
        s.flush()
        #expect(nextRun(db).last() == snapshot("/a.jpg"))
    }

    /// Spec §2.6: windows showing only Home are not kept in Last Session.
    @Test func homeOnlyWindowsLeftOut() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        let mixed = SessionSnapshot(windows: homeOnly.windows + snapshot("/a.jpg").windows)
        s.saveLast(mixed)
        s.flush()
        #expect(nextRun(db).last() == snapshot("/a.jpg"))
    }

    /// Review Focus 3: a quit inside the debounce keeps Last Session.
    @Test func lastFlushOnQuit() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        s.saveLast(snapshot("/a.jpg"))
        s.flush()
        #expect(nextRun(db).last() == snapshot("/a.jpg"))
    }

    @Test func orderRenameReplaceDelete() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        let s = store(db)
        s.save(snapshot("/1.jpg"), name: "One")
        s.save(snapshot("/2.jpg"), name: "Two")
        s.saveLast(snapshot("/last.jpg"))
        s.flush()
        var all = nextRun(db).all()
        #expect(all.map(\.name) == ["Last Session", "Two", "One"])
        #expect(all.first?.isLast == true)
        let one = try #require(all.first { $0.name == "One" })
        #expect(!s.rename(one.id, to: "Two"))
        #expect(s.rename(one.id, to: "Uno"))
        s.replace(one.id, with: snapshot("/9.jpg"))
        s.save(snapshot("/2b.jpg"), name: "Two")     // same name: replaces
        all = store(db).all()
        #expect(all.map(\.name) == ["Last Session", "Two", "Uno"])
        #expect(all.first { $0.name == "Uno" }?.snapshot == snapshot("/9.jpg"))
        #expect(all.first { $0.name == "Two" }?.snapshot == snapshot("/2b.jpg"))
        s.delete(one.id)
        #expect(store(db).all().map(\.name) == ["Last Session", "Two"])
    }

    @Test func badJSONRowIsSkipped() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try StateDatabase(directory: dir)
        try db.perform { try $0.run("INSERT INTO sessions(name, saved, is_last, json) VALUES('Bad', 1, 0, ?)", [.blob(Data("{".utf8))]) }
        store(db).save(snapshot("/1.jpg"), name: "Good")
        #expect(store(db).all().map(\.name) == ["Good"])
    }
}
