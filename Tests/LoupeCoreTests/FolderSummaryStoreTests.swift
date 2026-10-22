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
        let db = try ThumbnailDatabase(directory: tempDir(), thumbSize: 512, now: Clock().now, summaryCapacity: 3)
        for name in ["A", "B", "C"] { try db.putSummaries([(folder(name), summary(1))]) }
        _ = try db.summary(at: folder("A"))   // a read counts as use: B is now the oldest
        try db.putSummaries([(folder("D"), summary(2))])
        #expect(try db.summary(at: folder("B")) == nil)
        for name in ["A", "C", "D"] { #expect(try db.summary(at: folder(name)) != nil) }
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
            let read = clock.measure {
                for i in 0..<lookups {
                    _ = try? db.summary(at: ThumbnailLocation(volume: "uuid:ABCD-1234",
                                                              folder: path((i * 7919) % filled), name: "_"))
                }
            }
            let batch50 = (0..<50).map {
                (ThumbnailLocation(volume: "uuid:ABCD-1234", folder: path(($0 * 131) % filled), name: "_"), summary($0))
            }
            let write = clock.measure { try? db.putSummaries(batch50) }
            lines += ("\(filled) rows: lookup \(read / lookups), 50-row batch \(write), "
                  + "catalog +\((size() - baseline) / 1024) KiB (\((size() - baseline) * 10_000 / filled / 1024) KiB per 10 000)\n")
            try lines.write(to: report, atomically: true, encoding: .utf8)
        }
    }
}
