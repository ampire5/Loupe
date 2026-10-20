import Testing
import Foundation
import SQLite3
@testable import LoupeCore

@Suite struct ThumbnailDatabaseTests {
    /// A clock that ticks one second per reading, so `last_access` order follows call order.
    final class Clock {
        private var seconds = 800_000_000.0
        func now() -> Date {
            seconds += 1
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
    }

    private let fm = FileManager.default
    private let folderX = ThumbnailLocation(volume: "net://user@server/L$", folder: "/Album", name: "")
    private let folderY = ThumbnailLocation(volume: "uuid:ABCD-1234", folder: "/2024/05", name: "")
    private let folderZ = ThumbnailLocation(volume: "net://user@server/L$", folder: "/Other", name: "")

    private func tempDir() -> URL {
        fm.temporaryDirectory.appendingPathComponent("loupe-thumbdb-\(UUID().uuidString)")
    }

    private func open(_ dir: URL, thumbSize: Int = 512, clock: Clock = Clock()) throws -> ThumbnailDatabase {
        try ThumbnailDatabase(directory: dir, thumbSize: thumbSize, now: clock.now)
    }

    /// Mtimes with a fractional part, as listings give them, so the round trip has to be exact.
    private func stamp(_ n: Int, size: Int? = nil) -> FileStamp {
        FileStamp(modified: Date(timeIntervalSinceReferenceDate: 700_000_000.123_456_7 + Double(n)),
                  size: size ?? 1_000_000 + n)
    }

    /// The stamp `listing` gives a file: fixed by its name, so any listing of it agrees.
    private func stamp(of name: String) -> FileStamp {
        stamp(name.unicodeScalars.reduce(0) { $0 * 31 + Int($1.value) } % 1_000_000)
    }

    private func listing(_ names: [String]) -> [(name: String, stamp: FileStamp)] {
        names.map { (name: $0, stamp: stamp(of: $0)) }
    }

    private func info(_ n: Int, colorSpace: String? = "sRGB IEC61966-2.1") -> ImageInfo {
        ImageInfo(pixelSize: PixelSize(width: 6000 + n, height: 4000 + n), typeIdentifier: "public.jpeg",
                  isProgressive: n % 2 == 1, fileSize: 1_000_000 + n, colorSpaceName: colorSpace)
    }

    private func jpeg(_ n: Int, bytes: Int = 1000) -> Data { Data(repeating: UInt8(n & 0xFF), count: bytes) }

    /// Puts a 1000-byte thumbnail for every name → id, made from the file as `listing` stamps it.
    private func putAll(_ db: ThumbnailDatabase, _ ids: [String: Int64]) throws {
        try db.put(ids.sorted { $0.key < $1.key }.enumerated().map {
            (id: $0.element.value, stamp: stamp(of: $0.element.key), jpeg: jpeg($0.offset), info: info($0.offset))
        })
    }

    private func remove(_ dir: URL, _ names: String...) throws {
        for name in names where fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            try fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    @Test func syncReturnsIDsAndKeepsThem() throws {
        let dir = tempDir()
        let names = ["a.jpg", "b.jpg", "c.jpg"]
        let first: [String: Int64]
        do {
            let db = try open(dir)
            first = try db.sync(folder: folderX, files: listing(names))
            #expect(Set(first.keys) == Set(names))
            #expect(Set(first.values).count == 3)
            #expect(try db.sync(folder: folderX, files: listing(names)) == first)
            let other = try db.sync(folder: folderY, files: listing(names))
            #expect(Set(other.values).isDisjoint(with: first.values))
        }
        let reopened = try open(dir)
        #expect(try reopened.sync(folder: folderX, files: listing(names)) == first)
    }

    @Test func changedStampDropsThumb() throws {
        let db = try open(tempDir())
        let names = ["a.jpg", "b.jpg", "c.jpg"]
        let ids = try db.sync(folder: folderX, files: listing(names))
        try putAll(db, ids)
        var files = listing(names)
        files[0].stamp = stamp(0, size: 5)                                       // size changed
        files[1].stamp = FileStamp(modified: files[1].stamp.modified.addingTimeInterval(1e-6),
                                   size: files[1].stamp.size)                    // mtime changed
        let again = try db.sync(folder: folderX, files: files)
        #expect(again == ids)
        #expect(try db.hasThumbnail(Array(ids.values)) == [ids["c.jpg"]!])
        #expect(try db.thumbnail(ids["a.jpg"]!) == nil)
        #expect(try db.sync(folder: folderX, files: files) == ids)                // the new stamps were stored
        #expect(try db.hasThumbnail(Array(ids.values)) == [ids["c.jpg"]!])
    }

    @Test func orphansDeletedOnSync() throws {
        let db = try open(tempDir())
        let all = listing(["a.jpg", "b.jpg", "c.jpg"])
        let withoutB = all.filter { $0.name != "b.jpg" }                          // same stamps for a and c
        let ids = try db.sync(folder: folderX, files: all)
        try putAll(db, ids)
        let remaining = try db.sync(folder: folderX, files: withoutB)
        #expect(remaining == ids.filter { $0.key != "b.jpg" })
        #expect(try db.hasThumbnail(Array(ids.values)) == [ids["a.jpg"]!, ids["c.jpg"]!])
        let back = try db.sync(folder: folderX, files: all)
        #expect(back["b.jpg"] != ids["b.jpg"])                                    // a new row, ids never reused
        #expect(try db.hasThumbnail([back["b.jpg"]!]).isEmpty)
    }

    @Test func putAndGetThumbnail() throws {
        let db = try open(tempDir())
        let ids = try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"]))
        let a = ids["a.jpg"]!, b = ids["b.jpg"]!
        try db.put([(id: a, stamp: stamp(of: "a.jpg"), jpeg: jpeg(7, bytes: 50_000), info: info(1)),
                    (id: b, stamp: stamp(of: "b.jpg"), jpeg: jpeg(8), info: info(2, colorSpace: nil))])
        let gotA = try #require(try db.thumbnail(a))
        #expect(gotA.jpeg == jpeg(7, bytes: 50_000))
        #expect(gotA.info == info(1))
        let gotB = try #require(try db.thumbnail(b))
        #expect(gotB.info == info(2, colorSpace: nil))
        #expect(try db.thumbnail(a + b + 100) == nil)
        try db.put([(id: a, stamp: stamp(of: "a.jpg"), jpeg: jpeg(9), info: info(3))])                      // replaces
        #expect(try db.thumbnail(a)?.jpeg == jpeg(9))
        #expect(try db.thumbnail(a)?.info == info(3))
        #expect(try db.hasThumbnail([]) == [])
    }

    /// The orientation travels with the header (a seed's transform and its pyramid layout come from it), and the
    /// strip's aspects are the photos' as shown.
    @Test func orientationIsStored() throws {
        let db = try open(tempDir())
        let ids = try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"]))
        let a = ids["a.jpg"]!, b = ids["b.jpg"]!
        let turned = ImageInfo(pixelSize: PixelSize(width: 6000, height: 4000), typeIdentifier: "public.jpeg",
                               isProgressive: false, fileSize: 5, colorSpaceName: nil, orientation: .left)
        try db.put([(id: a, stamp: stamp(of: "a.jpg"), jpeg: jpeg(1), info: turned),
                    (id: b, stamp: stamp(of: "b.jpg"), jpeg: jpeg(2), info: info(2))])
        #expect(try db.thumbnail(a)?.info == turned)
        #expect(try db.thumbnail(b)?.info.orientation == .up)
        #expect(try db.displaySizes([a, b]) == [a: PixelSize(width: 4000, height: 6000), b: PixelSize(width: 6002, height: 4002)])
        // `exif-orientation=no`: the stored sizes, whatever the tag.
        #expect(try db.displaySizes([a, b], applyingOrientation: false)
                == [a: PixelSize(width: 6000, height: 4000), b: PixelSize(width: 6002, height: 4002)])
    }

    /// A database of another format (M2.5's, without orientations) is not migrated: both files start anew, so no
    /// header without its orientation and no thumbnail in stored layout survives.
    @Test func olderFormatStartsAnew() throws {
        let dir = tempDir()
        let ids: [String: Int64]
        do {
            let db = try open(dir)
            ids = try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"]))
            try putAll(db, ids)
        }
        do {
            let catalog = try SQLiteConnection(path: dir.appendingPathComponent("Catalog.db").path, pragmas: [])
            try catalog.execute("UPDATE meta SET value = '1' WHERE key = 'format_version'; ALTER TABLE files DROP COLUMN orientation;")
            catalog.close()
        }
        let db = try open(dir)
        #expect(try db.hasThumbnail(Array(ids.values)).isEmpty)
        #expect(try db.displaySizes(Array(ids.values)).isEmpty)
        let again = try db.sync(folder: folderX, files: listing(["a.jpg"]))
        try putAll(db, again)
        #expect(try db.thumbnail(again["a.jpg"]!)?.info == info(0))
    }

    @Test func putForAFileNoLongerListedIsIgnored() throws {
        let db = try open(tempDir())
        let ids = try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"]))
        _ = try db.sync(folder: folderX, files: listing(["b.jpg"]))
        try putAll(db, ids)
        #expect(try db.hasThumbnail(Array(ids.values)) == [ids["b.jpg"]!])
    }

    @Test func putMadeFromAnOlderVersionIsSkipped() throws {
        let db = try open(tempDir())
        let ids = try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"]))
        try putAll(db, ids)
        var files = listing(["a.jpg", "b.jpg"])
        files[0].stamp = stamp(0, size: 5)                                       // a.jpg was rewritten
        #expect(try db.sync(folder: folderX, files: files) == ids)
        // A thumbnail made from the old a.jpg arrives late, along with a current one for b.jpg.
        try db.put([(id: ids["a.jpg"]!, stamp: stamp(of: "a.jpg"), jpeg: jpeg(1), info: info(1)),
                    (id: ids["b.jpg"]!, stamp: stamp(of: "b.jpg"), jpeg: jpeg(2), info: info(2))])
        #expect(try db.hasThumbnail(Array(ids.values)) == [ids["b.jpg"]!])
        #expect(try db.thumbnail(ids["a.jpg"]!) == nil)
        try db.put([(id: ids["a.jpg"]!, stamp: stamp(0, size: 5), jpeg: jpeg(3), info: info(3))])
        #expect(try db.thumbnail(ids["a.jpg"]!)?.jpeg == jpeg(3))
    }

    @Test func enforceLimitDeletesOldestFirst() throws {
        let clock = Clock()
        let db = try open(tempDir(), clock: clock)
        let names = ["0.jpg", "1.jpg", "2.jpg"]
        let byName = try db.sync(folder: folderX, files: listing(names))
        let ids = names.map { byName[$0]! }
        try putAll(db, byName)
        for i in [2, 0, 1] { try db.touch([ids[i]]) }                             // 2 is now the oldest
        #expect(try db.enforceLimit(3000) == 0)                                   // not over the limit
        #expect(try db.hasThumbnail(ids).count == 3)
        #expect(try db.enforceLimit(2500) == 1000)                                // down to 2250
        #expect(try db.hasThumbnail(ids) == [ids[0], ids[1]])
        try db.touch([ids[0], ids[1]])
        #expect(try db.enforceLimit(0) == 2000)
        #expect(try db.hasThumbnail(ids).isEmpty)
    }

    @Test func deletedAtRuntimeIsRecreated() throws {
        let dir = tempDir()
        let db = try open(dir)
        let names = ["a.jpg", "b.jpg"]
        let ids = try db.sync(folder: folderX, files: listing(names))
        try putAll(db, ids)
        #expect(try db.reopenIfDeleted() == .nothing)

        try remove(dir, "Thumbs.db", "Thumbs.db-wal", "Thumbs.db-shm")
        #expect(try db.reopenIfDeleted() == .thumbnails)
        #expect(try db.reopenIfDeleted() == .nothing)
        #expect(try db.sync(folder: folderX, files: listing(names)) == ids)     // the catalog survived
        #expect(try db.hasThumbnail(Array(ids.values)).isEmpty)
        try putAll(db, ids)
        #expect(try db.hasThumbnail(Array(ids.values)).count == 2)

        try remove(dir, "Catalog.db", "Catalog.db-wal", "Catalog.db-shm")
        #expect(try db.reopenIfDeleted() == .catalog)
        let fresh = try db.sync(folder: folderX, files: listing(names))
        #expect(Set(fresh.keys) == Set(names))
        // A new catalog numbers its files from scratch, so the old thumbnails must not show up under them.
        #expect(try db.hasThumbnail(Array(fresh.values) + Array(ids.values)).isEmpty)
    }

    @Test func mainFileDeletedWithWALLeftIsRecreated() throws {
        let dir = tempDir()
        let ids: [String: Int64]
        do {
            let db = try open(dir)
            ids = try db.sync(folder: folderX, files: listing(["a.jpg"]))
            try putAll(db, ids)
            try remove(dir, "Thumbs.db")                                            // -wal and -shm stay
            #expect(try db.reopenIfDeleted() == .thumbnails)
            #expect(try db.hasThumbnail(Array(ids.values)).isEmpty)
            try db.put([(id: ids["a.jpg"]!, stamp: stamp(of: "a.jpg"), jpeg: jpeg(5), info: info(5))])
        }
        let reopened = try open(dir)
        #expect(try reopened.thumbnail(ids["a.jpg"]!)?.jpeg == jpeg(5))
    }

    @Test func wholeDirectoryDeletedIsRecreated() throws {
        let dir = tempDir()
        let db = try open(dir)
        let ids = try db.sync(folder: folderX, files: listing(["a.jpg"]))
        try putAll(db, ids)
        try fm.removeItem(at: dir)
        #expect(try db.reopenIfDeleted() == .catalog)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("Catalog.db").path))
        let fresh = try db.sync(folder: folderX, files: listing(["a.jpg"]))
        #expect(try db.hasThumbnail(Array(fresh.values)).isEmpty)
        try putAll(db, fresh)
        #expect(try db.hasThumbnail(Array(fresh.values)).count == 1)
    }

    @Test func reopenKeepsThumbs() throws {
        let dir = tempDir()
        let ids: [String: Int64]
        do {
            let db = try open(dir)
            ids = try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"]))
            try putAll(db, ids)
        }
        let db = try open(dir)
        #expect(try db.hasThumbnail(Array(ids.values)).count == 2)
    }

    @Test func foreignCatalogIDClearsThumbs() throws {
        let dirA = tempDir(), dirB = tempDir()
        let names = ["a.jpg", "b.jpg"]
        let idsA: [String: Int64]
        do {
            let db = try open(dirA)
            idsA = try db.sync(folder: folderX, files: listing(names))
            try putAll(db, idsA)
        }
        // Control: the main files alone (no -wal) next to their own catalog still hold the thumbnails.
        let dirC = tempDir()
        try fm.createDirectory(at: dirC, withIntermediateDirectories: true)
        for name in ["Catalog.db", "Thumbs.db"] {
            try fm.copyItem(at: dirA.appendingPathComponent(name), to: dirC.appendingPathComponent(name))
        }
        #expect(try open(dirC).hasThumbnail(Array(idsA.values)).count == 2)

        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
        try fm.copyItem(at: dirA.appendingPathComponent("Thumbs.db"), to: dirB.appendingPathComponent("Thumbs.db"))
        let db = try open(dirB)
        let idsB = try db.sync(folder: folderX, files: listing(names))
        #expect(idsB == idsA)                                    // same numbers, different catalog
        #expect(try db.hasThumbnail(Array(idsB.values)).isEmpty)
    }

    @Test func thumbSizeChangeClearsThumbs() throws {
        let dir = tempDir()
        let ids: [String: Int64]
        do {
            let db = try open(dir, thumbSize: 512)
            ids = try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"]))
            try putAll(db, ids)
        }
        let db = try open(dir, thumbSize: 256)
        #expect(try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"])) == ids)
        #expect(try db.hasThumbnail(Array(ids.values)).isEmpty)
    }

    @Test func cleanUpKeepsUnmountedVolumes() throws {
        let db = try open(tempDir())
        let x = try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"]))
        let y = try db.sync(folder: folderY, files: listing(["c.jpg"]))
        let z = try db.sync(folder: folderZ, files: listing(["d.jpg"]))
        let all = Array(x.values) + Array(y.values) + Array(z.values)
        try putAll(db, x.merging(y) { a, _ in a }.merging(z) { a, _ in a })
        var asked: Set<ThumbnailLocation> = []
        try db.cleanUpOrphans { location in
            asked.insert(location)
            if location.volume == folderY.volume { return nil }       // not mounted
            if location.folder == folderZ.folder { return false }     // gone
            return true
        }
        #expect(asked.contains(ThumbnailLocation(volume: folderX.volume, folder: folderX.folder, name: "a.jpg")))
        #expect(asked.count == 4)
        #expect(try db.hasThumbnail(all) == Set(Array(x.values) + Array(y.values)))
        #expect(try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"])) == x)
        #expect(try db.sync(folder: folderY, files: listing(["c.jpg"])) == y)
        #expect(try db.sync(folder: folderZ, files: listing(["d.jpg"])) != z)    // its row went too
    }

    @Test func clearThumbnailsKeepsCatalog() throws {
        let db = try open(tempDir())
        let ids = try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"]))
        try putAll(db, ids)
        try db.clearThumbnails()
        #expect(try db.hasThumbnail(Array(ids.values)).isEmpty)
        #expect(try db.thumbnail(ids["a.jpg"]!) == nil)
        #expect(try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg"])) == ids)
        try putAll(db, ids)
        #expect(try db.hasThumbnail(Array(ids.values)).count == 2)
    }

    @Test func touchOfUnknownOrNoIDsIsHarmless() throws {
        let db = try open(tempDir())
        try db.touch([])
        try db.touch([12345])
    }

    @Test(arguments: ["Thumbs.db", "Catalog.db"])
    func corruptFileIsSetAsideAndRecreated(name: String) throws {
        let dir = tempDir()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: dir.appendingPathComponent(name))
        try Data("old".utf8).write(to: dir.appendingPathComponent(name + ".broken-1000"))   // set aside before
        let db = try open(dir)
        let ids = try db.sync(folder: folderX, files: listing(["a.jpg"]))
        #expect(try db.hasThumbnail(Array(ids.values)).isEmpty)
        try putAll(db, ids)
        #expect(try db.hasThumbnail(Array(ids.values)).count == 1)
        let broken = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(name + ".broken-") }
        #expect(broken.count == 1)                                               // only the newest is kept
        #expect(broken.first != name + ".broken-1000")
        let setAside = try Data(contentsOf: dir.appendingPathComponent(try #require(broken.first)))
        #expect(setAside == Data(repeating: 0x5A, count: 8192))
    }

    /// "No traces" (`thumb-cache-size=0`) takes the damaged databases set aside too; other files stay.
    @Test func removeFilesTakesSetAsideDatabasesToo() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: dir.appendingPathComponent("Thumbs.db"))
        let db = try open(dir)                                              // sets the damaged Thumbs.db aside
        try putAll(db, try db.sync(folder: folderX, files: listing(["a.jpg"])))
        db.close()
        try Data("old".utf8).write(to: dir.appendingPathComponent("Catalog.db.broken-1000"))
        try Data("mine".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        #expect(try fm.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("Thumbs.db.broken-") })
        ThumbnailDatabase.removeFiles(in: dir)
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["notes.txt"])
    }

    @Test func storedBytesSumsTheBlobs() throws {
        let db = try open(tempDir())
        #expect(try db.storedBytes() == 0)
        let ids = try db.sync(folder: folderX, files: listing(["a.jpg", "b.jpg", "c.jpg"]))
        try putAll(db, ids)                                                      // 1000 bytes each
        #expect(try db.storedBytes() == 3000)
        try db.clearThumbnails()
        #expect(try db.storedBytes() == 0)
    }

    @Test func replaceDamagedKeepsAHealthyCatalog() throws {
        let dir = tempDir()
        let db = try open(dir)
        let ids = try db.sync(folder: folderX, files: listing(["a.jpg"]))
        try putAll(db, ids)
        #expect(try db.replaceDamaged() == .thumbnails)
        #expect(try db.sync(folder: folderX, files: listing(["a.jpg"])) == ids)   // the ids stay valid
        #expect(try db.hasThumbnail(Array(ids.values)).isEmpty)
        let names = try fm.contentsOfDirectory(atPath: dir.path)
        #expect(names.filter { $0.hasPrefix("Thumbs.db.broken-") }.count == 1)
        #expect(!names.contains { $0.hasPrefix("Catalog.db.broken-") })
        try putAll(db, ids)
        #expect(try db.hasThumbnail(Array(ids.values)).count == 1)
    }

    @Test func damageIsOnlyCorruptOrNotADatabase() {
        #expect(ThumbnailDatabase.isDamage(SQLiteError(code: SQLITE_CORRUPT, message: "")))
        #expect(ThumbnailDatabase.isDamage(SQLiteError(code: SQLITE_NOTADB, message: "")))
        #expect(ThumbnailDatabase.isDamage(SQLiteError(code: SQLITE_CORRUPT | (1 << 8), message: "")))   // extended code
        #expect(!ThumbnailDatabase.isDamage(SQLiteError(code: SQLITE_FULL, message: "")))
        #expect(!ThumbnailDatabase.isDamage(CocoaError(.fileWriteOutOfSpace)))
    }
}
