import Testing
import Foundation
import SQLite3
@testable import LoupeCore

@Suite struct FolderSummaryStoreTests {
    final class Clock {
        private var seconds = 800_000_000.0
        func now() -> Date {
            seconds += 1
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
    }

    private let fm = FileManager.default

    private func tempDir() -> URL {
        fm.temporaryDirectory.appendingPathComponent("loupe-summarydb-\(UUID().uuidString)")
    }

    private func folder(_ name: String, volume: String = "uuid:ABCD-1234") -> ThumbnailLocation {
        ThumbnailLocation(volume: volume, folder: "/" + name, name: "_")
    }

    private func summary(_ n: Int) -> FolderSummary {
        FolderSummary(photos: n, folders: n % 3, bytes: Int64(n) * 1_000_000_007,
                      first: Date(timeIntervalSinceReferenceDate: 700_000_000.123_456_7),
                      last: Date(timeIntervalSinceReferenceDate: 710_000_000.5),
                      histogram: (0..<12).map { UInt8($0 + n % 5) },
                      folderModified: Date(timeIntervalSinceReferenceDate: 705_000_000.25), datesKnown: true)
    }

    @Test func summaryRoundTrips() throws {
        let db = try ThumbnailDatabase(directory: tempDir(), thumbSize: 512)
        let full = summary(7)
        let share = FolderSummary(photos: 3, folders: 1)   // names only: no size, no dates, no histogram
        try db.putSummaries([(folder("A"), full), (folder("B"), share)])
        #expect(try db.summary(at: folder("A")) == full)
        #expect(try db.summary(at: folder("B")) == share)
        #expect(try db.summary(at: folder("C")) == nil)
        #expect(try db.summary(at: folder("A", volume: "net:srv/x")) == nil)
        // Another write of the same folder replaces the row.
        try db.putSummaries([(folder("A"), summary(9))])
        #expect(try db.summary(at: folder("A")) == summary(9))
    }

    @Test func oldCatalogGainsTheTable() throws {
        let dir = tempDir()
        let clock = Clock()
        do {
            let db = try ThumbnailDatabase(directory: dir, thumbSize: 512, now: clock.now)
            let loc = ThumbnailLocation(volume: "uuid:ABCD-1234", folder: "/Album", name: "a.jpg")
            _ = try db.addFile(loc, stamp: FileStamp(modified: Date(timeIntervalSinceReferenceDate: 1), size: 10))
            db.close()
        }
        // The catalog as an earlier build left it: no summaries table.
        var raw: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("Catalog.db").path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "DROP TABLE folder_summaries", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let db = try ThumbnailDatabase(directory: dir, thumbSize: 512, now: clock.now)
        let loc = ThumbnailLocation(volume: "uuid:ABCD-1234", folder: "/Album", name: "a.jpg")
        #expect(try db.file(at: loc) != nil)
        #expect(try db.summary(at: folder("Album")) == nil)
        try db.putSummaries([(folder("Album"), summary(1))])
        #expect(try db.summary(at: folder("Album")) == summary(1))
        #expect(ThumbnailDatabase.formatVersion == 2)
        db.close()

        var check: OpaquePointer?
        sqlite3_open(dir.appendingPathComponent("Catalog.db").path, &check)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(check, "SELECT value FROM meta WHERE key = 'format_version'", -1, &statement, nil)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(statement, 0)) == "2")
        sqlite3_finalize(statement)
        sqlite3_close(check)
    }

    @Test func evictsLeastUsed() throws {
        let db = try ThumbnailDatabase(directory: tempDir(), thumbSize: 512, now: Clock().now, summaryCapacity: 3,
                                    summaryStampWindow: 0)
        for name in ["A", "B", "C"] { try db.putSummaries([(folder(name), summary(1))]) }
        _ = try db.summary(at: folder("A"))   // a read counts as use: B is now the oldest
        try db.putSummaries([(folder("D"), summary(2))])
        #expect(try db.summary(at: folder("B")) == nil)
        for name in ["A", "C", "D"] { #expect(try db.summary(at: folder(name)) != nil) }
    }

    @Test func readingDoesNotWrite() throws {
        final class Ticker { var t = 800_000_000.0; func now() -> Date { Date(timeIntervalSinceReferenceDate: t) } }
        let ticker = Ticker()
        let db = try ThumbnailDatabase(directory: tempDir(), thumbSize: 512, now: ticker.now, summaryStampWindow: 100)
        try db.putSummaries([(folder("A"), summary(1))])
        let stamped = try #require(try db.summaryLastUsed(at: folder("A")))
        ticker.t += 50   // inside the window: no write, nothing queued
        _ = try db.summary(at: folder("A"))
        _ = try db.summary(at: folder("A"))
        #expect(db.pendingStampCount == 0)
        #expect(try db.summaryLastUsed(at: folder("A")) == stamped)
        ticker.t += 200   // beyond it: queued, still no write by the read itself
        _ = try db.summary(at: folder("A"))
        _ = try db.summary(at: folder("A"))
        #expect(db.pendingStampCount == 1)
        #expect(try db.summaryLastUsed(at: folder("A")) == stamped)
        try db.putSummaries([(folder("B"), summary(2))])   // the next write restamps it
        #expect(db.pendingStampCount == 0)
        #expect(try db.summaryLastUsed(at: folder("A")) == stamped + 250)
    }

    @Test func staleStampsFlushAtTheBound() throws {
        final class Ticker { var t = 800_000_000.0; func now() -> Date { Date(timeIntervalSinceReferenceDate: t) } }
        let ticker = Ticker()
        let db = try ThumbnailDatabase(directory: tempDir(), thumbSize: 512, now: ticker.now, summaryStampWindow: 10)
        try db.putSummaries((0..<70).map { (folder("F\($0)"), summary($0)) })
        ticker.t += 100
        for n in 0..<70 { _ = try db.summary(at: folder("F\(n)")) }
        #expect(db.pendingStampCount == 6)   // 64 were written when the bound was reached
        #expect(try db.summaryLastUsed(at: folder("F0")) == 800_000_100)
    }

    @Test func batchWritesOnce() throws {
        let db = try ThumbnailDatabase(directory: tempDir(), thumbSize: 512, now: Clock().now, summaryCapacity: 3)
        try db.putSummaries([(folder("Old"), summary(1))])
        // One batch larger than the cap: evicted after the whole batch, so exactly the cap remains and none of the
        // batch's own rows is lost half way (the latest rows of the batch stay, the earlier and the old one go).
        try db.putSummaries((0..<5).map { (folder("N\($0)"), summary($0)) })
        #expect(try db.summaryCount() == 3)
        #expect(try db.summary(at: folder("Old")) == nil)
        #expect(try db.summary(at: folder("N0")) == nil)
        #expect(try db.summary(at: folder("N1")) == nil)
        for n in 2..<5 { #expect(try db.summary(at: folder("N\(n)")) == summary(n)) }
        try db.putSummaries([])   // nothing to do, nothing thrown
    }

    /// R8: the stored summaries of a folder's direct subfolders, one indexed range of the primary key: not the folder
    /// itself, not deeper ones, not a sibling sharing the name's start, not another volume's, not a zip's.
    @Test func childSummariesDirectOnly() throws {
        let db = try ThumbnailDatabase(directory: tempDir(), thumbSize: 512)
        func at(_ path: String, volume: String = "uuid:ABCD-1234") -> ThumbnailLocation {
            ThumbnailLocation(volume: volume, folder: path, name: "_")
        }
        func photos(_ n: Int) -> FolderSummary { FolderSummary(photos: n, folders: 0) }
        try db.putSummaries([(at("/A"), photos(1)), (at("/A/x"), photos(10)), (at("/A/y"), photos(20)),
                             (at("/A/x/deep"), photos(100)), (at("/A2"), photos(1000)), (at("/A2/z"), photos(2000)),
                             (at("/A/c.zip"), photos(5)), (at("/A/d.ZIP"), photos(6)),
                             (at("/A/w", volume: "net:srv/x"), photos(3000)), (at("/B"), photos(7))])
        #expect(try db.childSummaries(of: at("/A")) == ["/A/x": 10, "/A/y": 20])
        #expect(try db.childSummaries(of: at("/A/x")) == ["/A/x/deep": 100])
        #expect(try db.childSummaries(of: at("/A/y")).isEmpty)
        #expect(try db.childSummaries(of: at("/")) == ["/A": 1, "/A2": 1000, "/B": 7])
        // A decomposed name (as macOS often writes them): SQLite counts its code points, not its characters.
        try db.putSummaries([(at("/Cafe\u{301}/x"), photos(4)), (at("/Cafe\u{301}/x/y"), photos(8))])
        #expect(try db.childSummaries(of: at("/Cafe\u{301}")) == ["/Cafe\u{301}/x": 4])
    }

    /// The measurement behind `childSummaries`' note: `LOUPE_SUMMARY_BENCH=<report file> scripts/test.sh --filter
    /// measureChildSummaries`. A table of 20 000 rows (`summaryCapacity`), one folder with 4 096 subfolders in it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_SUMMARY_BENCH"] != nil))
    func measureChildSummaries() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try ThumbnailDatabase(directory: dir, thumbSize: 512)
        let wide = (0..<4096).map { (folder("Wide/Sub \($0) with a longish folder name"), summary($0)) }
        let rest = (0..<(ThumbnailDatabase.summaryCapacity - 4096)).map {
            (folder("Photos/\($0 / 100)/Trip \($0 % 100)"), summary($0))
        }
        for batch in stride(from: 0, to: rest.count, by: 1000) {
            try db.putSummaries(Array(rest[batch..<min(rest.count, batch + 1000)]))
        }
        try db.putSummaries(wide)
        let clock = ContinuousClock()
        var best = Duration.seconds(1000), small = Duration.seconds(1000)
        for _ in 0..<20 {
            var count = 0
            best = min(best, try clock.measure { count = try db.childSummaries(of: folder("Wide")).count })
            #expect(count == 4096)
            small = min(small, try clock.measure { _ = try db.childSummaries(of: folder("Photos/7")) })
        }
        let report = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOUPE_SUMMARY_BENCH"] ?? "/dev/null")
        try "childSummaries: 4096 subfolders \(best), 100 subfolders \(small) (best of 20, 20 000 rows)\n"
            .write(to: report, atomically: true, encoding: .utf8)
    }

    /// The store's: the catalog's rows and the summaries waiting for its next batch, the newer one per folder.
    @Test func storeChildSummariesSeeTheBatch() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let store = ThumbnailStore(directory: dir, reader: ThumbReader(), thumbSize: 32, limitBytes: 1 << 30,
                                   idleDelay: .zero, commitDelay: .seconds(3600))
        func at(_ path: String) -> ThumbnailLocation { ThumbnailLocation(volume: "test", folder: path, name: "_") }
        await store.putFolderSummaries([(at("/A/x"), FolderSummary(photos: 10, folders: 0)),
                                        (at("/A/y"), FolderSummary(photos: 20, folders: 0))])
        await store.queueSummary(FolderSummary(photos: 25, folders: 0), at: at("/A/y"))
        await store.queueSummary(FolderSummary(photos: 30, folders: 0), at: at("/A/z"))
        await store.queueSummary(FolderSummary(photos: 99, folders: 0), at: at("/A/z/deep"))
        #expect(await store.childSummaries(of: at("/A")) == ChildSummaries(count: 3, photos: 65))
        #expect(await store.childSummaries(of: at("/B")) == ChildSummaries(count: 0, photos: 0))
    }

    /// The measurement behind `ThumbnailDatabase.summaryCapacity`: `LOUPE_SUMMARY_BENCH=<report file> scripts/test.sh
    /// --filter measureCapacity` (the test runner hides prints). Writes lookup time, a 50-row batch's time and the catalog's growth for several row counts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_SUMMARY_BENCH"] != nil))
    func measureCapacity() throws {
        let dir = tempDir()
        let db = try ThumbnailDatabase(directory: dir, thumbSize: 512, summaryCapacity: .max)
        func size() -> Int {
            ["Catalog.db", "Catalog.db-wal"].reduce(0) {
                $0 + ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent($1).path)[.size] as? Int) ?? 0)
            }
        }
        func path(_ n: Int) -> String { "/Photos/\(n / 100)/Trip \(n % 100) with a longish folder name" }
        let report = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOUPE_SUMMARY_BENCH"] ?? "/dev/null")
        var lines = ""
        let baseline = size()
        var filled = 0
        for target in [10_000, 50_000, 100_000] {
            while filled < target {
                let batch = (filled..<min(target, filled + 1000)).map {
                    (ThumbnailLocation(volume: "uuid:ABCD-1234", folder: path($0), name: "_"), summary($0))
                }
                try db.putSummaries(batch)
                filled += batch.count
            }
            let clock = ContinuousClock()
            let lookups = 2000
            let read = try clock.measure {
                for i in 0..<lookups {
                    _ = try db.summary(at: ThumbnailLocation(volume: "uuid:ABCD-1234",
                                                              folder: path((i * 7919) % filled), name: "_"))
                }
            }
            let batch50 = (0..<50).map {
                (ThumbnailLocation(volume: "uuid:ABCD-1234", folder: path(($0 * 131) % filled), name: "_"), summary($0))
            }
            let write = try clock.measure { try db.putSummaries(batch50) }
            lines += ("\(filled) rows: lookup \(read / lookups), 50-row batch \(write), "
                  + "catalog +\((size() - baseline) / 1024) KiB (\((size() - baseline) * 10_000 / filled / 1024) KiB per 10 000)\n")
            try lines.write(to: report, atomically: true, encoding: .utf8)
        }
    }

    /// Plan Review Focus 4: a renamed folder keeps its summary, and its subfolders theirs; a sibling whose name only
    /// starts the same stays, as does another volume's folder of that path; a stale row at the new path is replaced.
    @Test func renameMovesTheFolderAndItsDescendants() throws {
        let db = try ThumbnailDatabase(directory: tempDir(), thumbSize: 512)
        try db.putSummaries([(folder("P/old"), summary(1)), (folder("P/old/sub"), summary(2)),
                             (folder("P/old/sub/deep"), summary(3)), (folder("P/older"), summary(4)),
                             (folder("P/new"), summary(9)), (folder("P/old", volume: "net:other"), summary(5))])
        try db.moveSummaries(volume: "uuid:ABCD-1234", from: "/P/old", to: "/P/new")
        #expect(try db.summary(at: folder("P/new")) == summary(1))
        #expect(try db.summary(at: folder("P/new/sub")) == summary(2))
        #expect(try db.summary(at: folder("P/new/sub/deep")) == summary(3))
        #expect(try db.summary(at: folder("P/old")) == nil && db.summary(at: folder("P/old/sub")) == nil)
        #expect(try db.summary(at: folder("P/older")) == summary(4))
        #expect(try db.summary(at: folder("P/old", volume: "net:other")) == summary(5))
        #expect(try db.summaryCount() == 5)
    }

    /// The store moves them when the browser renames a folder (`PathMoving`), those waiting for its batch too; where
    /// the catalog keeps the folder is asked of the new path.
    @Test func storeMovesSummariesOnRename() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let store = ThumbnailStore(directory: dir, reader: ThumbReader(), thumbSize: 32, limitBytes: 1 << 30,
                                   locate: { url in
                                       ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path,
                                                         name: url.lastPathComponent)
                                   }, idleDelay: .zero, commitDelay: .seconds(3600))
        func at(_ path: String) -> ThumbnailLocation { ThumbnailLocation(volume: "test", folder: path, name: "_") }
        await store.putFolderSummaries([(at("/p/trip"), summary(1)), (at("/p/trip/day 1"), summary(2))])
        await store.queueSummary(summary(3), at: at("/p/trip/day 2"))
        await store.moveSummaries(from: URL(fileURLWithPath: "/p/trip"), to: URL(fileURLWithPath: "/p/Trip 2019"))
        #expect(await store.folderSummary(at: at("/p/Trip 2019")) == summary(1))
        #expect(await store.folderSummary(at: at("/p/Trip 2019/day 1")) == summary(2))
        #expect(await store.folderSummary(at: at("/p/Trip 2019/day 2")) == summary(3))
        #expect(await store.folderSummary(at: at("/p/trip")) == nil)
        #expect(await store.folderSummary(at: at("/p/trip/day 2")) == nil)
    }
}
