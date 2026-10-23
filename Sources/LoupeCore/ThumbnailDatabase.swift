import Foundation
import SQLite3

/// The thumbnail disk cache (spec §3.2): `Catalog.db` knows volumes, folders and files (stamp, `ImageInfo`,
/// last access), `Thumbs.db` holds only the JPEG blobs by file id. Metadata apart from the blobs keeps the
/// catalog small and lets `Thumbs.db` be wiped without losing it. Not thread-safe: `ThumbnailStore` owns
/// one and calls it serially.
///
/// The invariant across the two files: a blob in `Thumbs.db` is only ever there for the stamp its file row
/// has now. Deleting thumbnails (stamp changed, file gone) commits in `Thumbs.db` before the catalog
/// changes; storing one writes the catalog's `ImageInfo` first and the blob after. A crash between the two
/// therefore leaves a missing thumbnail (made again), never one that no longer matches its file.
public final class ThumbnailDatabase {
    /// 2 (M3b): thumbnails are turned by EXIF orientation and the catalog stores it. A database of another format is
    /// not migrated: both files start anew (`openBoth`).
    public static let formatVersion = 2

    /// Rows `folder_summaries` keeps; beyond it the least recently used go (`putSummaries`).
    /// Measured (FolderSummaryStoreTests.measureCapacity, `LOUPE_SUMMARY_BENCH`, debug build, Intel Core i7-10700K,
    /// 8 physical cores, SSD, rows with ~55 character paths and a 12-byte histogram, WAL included in the size; two
    /// runs): a lookup, a read only (its `last_used` restamp is batched, `summaryStampWindow`), takes 0.018-0.020 ms
    /// at 10 000, 50 000 and 100 000 rows (flat: a primary-key probe); a 50-row batch with its eviction 2.7-3.9 ms at
    /// any size; the catalog grows about 2.3 MB per 10 000 rows (3 MB at 10 000, 12 MB at 50 000, 22 MB at 100 000).
    /// 20 000 folders is far more than anyone browses and costs about 5 MB, small next to the file rows of the
    /// folders it describes.
    public static let summaryCapacity = 20_000

    /// A read restamps a row's `last_used` only when the stored stamp is older than this: eviction by least recent use
    /// needs only a coarse clock (days), and a read must not cost a commit per folder card on the store's actor.
    public static let summaryStampWindow: TimeInterval = 24 * 3600
    /// Stale stamps collected from reads before they are written in a transaction of their own (otherwise they ride
    /// with the next `putSummaries`).
    private static let pendingStampLimit = 64

    /// What `reopenIfDeleted` had to recreate.
    public enum Reopened: Equatable, Sendable {
        /// Both files were still in place; nothing happened.
        case nothing
        /// Only `Thumbs.db` was made anew: every stored thumbnail is gone, but file ids stay valid.
        case thumbnails
        /// `Catalog.db` was made anew (or replaced): every file id obtained before is void, and a new
        /// catalog numbers its files from 1 again. The caller must drop its name → id maps and any pending
        /// `put` batch, and `sync` its folders again.
        case catalog
    }

    private let directory: URL
    private let thumbSize: Int
    private let now: () -> Date
    private let summaryCapacity: Int
    private let summaryStampWindow: TimeInterval
    /// Rows read after their `last_used` went stale, waiting to be restamped with the next write (bounded by
    /// `pendingStampLimit`).
    private var pendingStamps: [SummaryKey: Double] = [:]
    private struct SummaryKey: Hashable { let volume: String; let path: String }
    private var catalog: SQLiteConnection
    private var thumbs: SQLiteConnection
    private var catalogID: String

    /// Opens or creates both databases in `directory` (created too if missing). `Thumbs.db` made for
    /// another catalog, thumbnail size or format is emptied; a corrupt file is set aside and made anew.
    /// `now` stamps `last_access` (tests pass a clock).
    public init(directory: URL, thumbSize: Int, now: @escaping () -> Date = Date.init,
                summaryCapacity: Int = ThumbnailDatabase.summaryCapacity,
                summaryStampWindow: TimeInterval = ThumbnailDatabase.summaryStampWindow) throws {
        self.directory = directory
        self.thumbSize = thumbSize
        self.now = now
        self.summaryCapacity = summaryCapacity
        self.summaryStampWindow = summaryStampWindow
        (catalog, thumbs, catalogID) = try Self.openBoth(directory: directory, thumbSize: thumbSize)
    }

    /// Records an opened folder's listing and returns name → file id. A file whose size or mtime changed
    /// keeps its id but loses its thumbnail and `ImageInfo`; files no longer listed leave both databases, but for
    /// those named in `keeping` (listed without a stamp: the subtree walk's photos whose stat failed), and none when
    /// `removingOthers` is false (a part of the folder's files: the walk's photos stamped so far).
    /// `folder.name` is not used.
    public func sync(folder: ThumbnailLocation, files: [(name: String, stamp: FileStamp)],
                     removingOthers: Bool = true, keeping: Set<String> = []) throws -> [String: Int64] {
        let time = SQLiteValue.double(now().timeIntervalSinceReferenceDate)
        var ids: [String: Int64] = [:]
        try catalog.transaction {
            try catalog.run("INSERT INTO volumes(key) VALUES(?) ON CONFLICT(key) DO NOTHING", [.text(folder.volume)])
            var volumeID: Int64 = 0
            try catalog.query("SELECT id FROM volumes WHERE key = ?", [.text(folder.volume)]) { volumeID = $0.int(0) }
            var folderID: Int64 = 0
            try catalog.query("""
                INSERT INTO folders(volume, path, last_access) VALUES(?, ?, ?)
                ON CONFLICT(volume, path) DO UPDATE SET last_access = excluded.last_access RETURNING id
                """, [.int(volumeID), .text(folder.folder), time]) { folderID = $0.int(0) }

            var stored: [String: (id: Int64, stamp: FileStamp)] = [:]
            try catalog.query("SELECT id, name, size, mtime FROM files WHERE folder = ?", [.int(folderID)]) { r in
                stored[r.text(1)] = (r.int(0), FileStamp(modified: Date(timeIntervalSinceReferenceDate: r.double(3)),
                                                         size: Int(r.int(2))))
            }
            var changed: [(id: Int64, stamp: FileStamp)] = []
            var added: [(name: String, stamp: FileStamp)] = []
            for file in files where ids[file.name] == nil {
                if let row = stored.removeValue(forKey: file.name) {
                    ids[file.name] = row.id
                    if row.stamp != file.stamp { changed.append((row.id, file.stamp)) }
                } else {
                    added.append(file)
                }
            }
            let orphans = removingOthers ? stored.filter { !keeping.contains($0.key) }.map(\.value.id) : []
            try deleteThumbs(changed.map(\.id) + orphans)

            for file in changed {
                try catalog.run("""
                    UPDATE files SET size = ?, mtime = ?, width = NULL, height = NULL, uti = NULL,
                    progressive = NULL, file_size = NULL, color_space = NULL, orientation = NULL WHERE id = ?
                    """, [.int(Int64(file.stamp.size)), .double(file.stamp.modified.timeIntervalSinceReferenceDate),
                          .int(file.id)])
            }
            if !orphans.isEmpty {
                try catalog.run("DELETE FROM files WHERE id IN (SELECT value FROM json_each(?))", [Self.idList(orphans)])
            }
            for file in added {
                ids[file.name] = try catalog.run(
                    "INSERT INTO files(folder, name, size, mtime, last_access) VALUES(?, ?, ?, ?, ?)",
                    [.int(folderID), .text(file.name), .int(Int64(file.stamp.size)),
                     .double(file.stamp.modified.timeIntervalSinceReferenceDate), time])
            }
        }
        return ids
    }

    /// The file row at `location` and the stamp it was cataloged with; nil when the catalog has none. Read only.
    public func file(at location: ThumbnailLocation) throws -> (id: Int64, stamp: FileStamp)? {
        var found: (id: Int64, stamp: FileStamp)?
        try catalog.query("""
            SELECT f.id, f.size, f.mtime FROM files f JOIN folders d ON f.folder = d.id JOIN volumes v ON d.volume = v.id
            WHERE v.key = ? AND d.path = ? AND f.name = ?
            """, [.text(location.volume), .text(location.folder), .text(location.name)]) { r in
            found = (r.int(0), FileStamp(modified: Date(timeIntervalSinceReferenceDate: r.double(2)), size: Int(r.int(1))))
        }
        return found
    }

    /// How many files the catalog has in the folder of `location` (its `name` is ignored); nil for a folder it never saw.
    /// Read only.
    public func fileCount(in location: ThumbnailLocation) throws -> Int? {
        var count: Int?
        try catalog.query("""
            SELECT COUNT(f.id) FROM folders d JOIN volumes v ON d.volume = v.id LEFT JOIN files f ON f.folder = d.id
            WHERE v.key = ? AND d.path = ? GROUP BY d.id
            """, [.text(location.volume), .text(location.folder)]) { count = Int($0.int(0)) }
        return count
    }

    /// Up to `limit` names in the folder of `location` that have a thumbnail, by name. Read only.
    public func namesWithThumbnails(in location: ThumbnailLocation, limit: Int) throws -> [String] {
        var ids: [(Int64, String)] = []
        try catalog.query("""
            SELECT f.id, f.name FROM files f JOIN folders d ON f.folder = d.id JOIN volumes v ON d.volume = v.id
            WHERE v.key = ? AND d.path = ? ORDER BY f.name
            """, [.text(location.volume), .text(location.folder)]) { ids.append(($0.int(0), $0.text(1))) }
        guard !ids.isEmpty else { return [] }
        let made = try hasThumbnail(ids.map(\.0))
        return Array(ids.filter { made.contains($0.0) }.map(\.1).prefix(limit))
    }

    /// Catalogs the one file at `location` (Home's covers: its folder is not open, so not `sync`ed) and returns its
    /// id. Unlike `sync` it never drops the folder's other files; a row whose stamp differs loses its thumbnail and
    /// `ImageInfo`, as there.
    public func addFile(_ location: ThumbnailLocation, stamp: FileStamp) throws -> Int64 {
        let time = SQLiteValue.double(now().timeIntervalSinceReferenceDate)
        var id: Int64 = 0
        try catalog.transaction {
            try catalog.run("INSERT INTO volumes(key) VALUES(?) ON CONFLICT(key) DO NOTHING", [.text(location.volume)])
            var volumeID: Int64 = 0
            try catalog.query("SELECT id FROM volumes WHERE key = ?", [.text(location.volume)]) { volumeID = $0.int(0) }
            var folderID: Int64 = 0
            try catalog.query("""
                INSERT INTO folders(volume, path, last_access) VALUES(?, ?, ?)
                ON CONFLICT(volume, path) DO UPDATE SET last_access = excluded.last_access RETURNING id
                """, [.int(volumeID), .text(location.folder), time]) { folderID = $0.int(0) }
            var row: (id: Int64, stamp: FileStamp)?
            try catalog.query("SELECT id, size, mtime FROM files WHERE folder = ? AND name = ?",
                              [.int(folderID), .text(location.name)]) { r in
                row = (r.int(0), FileStamp(modified: Date(timeIntervalSinceReferenceDate: r.double(2)), size: Int(r.int(1))))
            }
            if let row {
                id = row.id
                guard row.stamp != stamp else { return }
                try deleteThumbs([row.id])
                try catalog.run("""
                    UPDATE files SET size = ?, mtime = ?, width = NULL, height = NULL, uti = NULL,
                    progressive = NULL, file_size = NULL, color_space = NULL, orientation = NULL WHERE id = ?
                    """, [.int(Int64(stamp.size)), .double(stamp.modified.timeIntervalSinceReferenceDate), .int(row.id)])
            } else {
                id = try catalog.run("INSERT INTO files(folder, name, size, mtime, last_access) VALUES(?, ?, ?, ?, ?)",
                                     [.int(folderID), .text(location.name), .int(Int64(stamp.size)),
                                      .double(stamp.modified.timeIntervalSinceReferenceDate), time])
            }
        }
        return id
    }

    /// The stored thumbnail and the `ImageInfo` it was made with, or nil when either is missing.
    public func thumbnail(_ id: Int64) throws -> (jpeg: Data, info: ImageInfo)? {
        var info: ImageInfo?
        try catalog.query("""
            SELECT width, height, uti, progressive, file_size, color_space, orientation FROM files
            WHERE id = ? AND width IS NOT NULL
            """, [.int(id)]) { r in
            info = ImageInfo(pixelSize: PixelSize(width: Int(r.int(0)), height: Int(r.int(1))),
                             typeIdentifier: r.text(2), isProgressive: r.int(3) != 0, fileSize: Int(r.int(4)),
                             colorSpaceName: r.isNull(5) ? nil : r.text(5),
                             orientation: ImageOrientation(rawValue: Int(r.int(6))) ?? .up)
        }
        guard let info else { return nil }
        var jpeg: Data?
        try thumbs.query("SELECT jpeg FROM thumbs WHERE file_id = ?", [.int(id)]) { jpeg = $0.blob(0) }
        return jpeg.map { ($0, info) }
    }

    /// The source's size as shown (`ImageInfo.displaySize`: the thumbnail's aspect, or the stored one when
    /// `applyingOrientation` is false) of each of `ids` whose `ImageInfo` is known (a thumbnail was made of the file's
    /// current stamp; it stays when the size limit evicts the thumbnail itself).
    public func displaySizes(_ ids: [Int64], applyingOrientation: Bool = true) throws -> [Int64: PixelSize] {
        guard !ids.isEmpty else { return [:] }
        var sizes: [Int64: PixelSize] = [:]
        try catalog.query("""
            SELECT id, width, height, orientation FROM files
            WHERE id IN (SELECT value FROM json_each(?)) AND width IS NOT NULL
            """, [Self.idList(ids)]) { r in
            let stored = PixelSize(width: Int(r.int(1)), height: Int(r.int(2)))
            let orientation = ImageOrientation(rawValue: Int(r.int(3))) ?? .up
            sizes[r.int(0)] = (applyingOrientation ? orientation : .up).orientedSize(stored)
        }
        return sizes
    }

    /// Which of `ids` have a stored thumbnail.
    public func hasThumbnail(_ ids: [Int64]) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        var found: Set<Int64> = []
        try thumbs.query("SELECT file_id FROM thumbs WHERE file_id IN (SELECT value FROM json_each(?))",
                         [Self.idList(ids)]) { found.insert($0.int(0)) }
        return found
    }

    /// Stores a batch of thumbnails with the stamp of the file they were made from and its `ImageInfo`.
    /// Making one counts as an access, so a thumbnail just paid for is not the first the limit evicts. An
    /// item is skipped when its file row is gone (the file left its folder while the thumbnail was being
    /// made) or the row's size / mtime no longer equal `stamp` (the file changed meanwhile, and `sync`
    /// already dropped what was there): storing it would show the old picture for the new file.
    public func put(_ items: [(id: Int64, stamp: FileStamp, jpeg: Data, info: ImageInfo)]) throws {
        guard !items.isEmpty else { return }
        let time = SQLiteValue.double(now().timeIntervalSinceReferenceDate)
        var current: [(id: Int64, jpeg: Data)] = []
        // The catalog first here: a crash before the blobs land leaves info without a thumbnail, which is
        // simply a thumbnail to make.
        try catalog.transaction {
            for item in items {
                let info = item.info
                try catalog.query("""
                    UPDATE files SET width = ?, height = ?, uti = ?, progressive = ?, file_size = ?, color_space = ?,
                    orientation = ?, last_access = ? WHERE id = ? AND size = ? AND mtime = ? RETURNING id
                    """, [.int(Int64(info.pixelSize.width)), .int(Int64(info.pixelSize.height)),
                          .text(info.typeIdentifier), .int(info.isProgressive ? 1 : 0), .int(Int64(info.fileSize)),
                          info.colorSpaceName.map { .text($0) } ?? .null, .int(Int64(info.orientation.rawValue)),
                          time, .int(item.id),
                          .int(Int64(item.stamp.size)), .double(item.stamp.modified.timeIntervalSinceReferenceDate)]) { _ in
                    current.append((item.id, item.jpeg))
                }
            }
        }
        guard !current.isEmpty else { return }
        try thumbs.transaction {
            for item in current {
                try thumbs.run("INSERT OR REPLACE INTO thumbs(file_id, jpeg) VALUES(?, ?)",
                               [.int(item.id), .blob(item.jpeg)])
            }
        }
    }

    /// Marks the files whose thumbnails were shown as just accessed.
    public func touch(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try catalog.run("UPDATE files SET last_access = ? WHERE id IN (SELECT value FROM json_each(?))",
                        [.double(now().timeIntervalSinceReferenceDate), Self.idList(ids)])
    }

    /// Over `bytes` of thumbnails, deletes the least recently accessed down to 90 % of it (catalog rows
    /// stay) and returns the space to the file system. Returns the blob bytes freed. Scans every blob's
    /// length, so the caller decides how often that is worth it.
    public func enforceLimit(_ bytes: Int) throws -> Int {
        var sizes: [Int64: Int] = [:]
        var total = 0
        try thumbs.query("SELECT file_id, length(jpeg) FROM thumbs", []) { r in
            sizes[r.int(0)] = Int(r.int(1))
            total += Int(r.int(1))
        }
        guard total > bytes else { return 0 }
        let target = bytes - bytes / 10
        var byAge: [Int64] = []
        try catalog.query("SELECT id FROM files ORDER BY last_access, id", []) { r in
            if sizes[r.int(0)] != nil { byAge.append(r.int(0)) }
        }
        // Blobs whose file row is gone cannot be shown at all: they go before anything else.
        let listed = Set(byAge)
        let candidates = sizes.keys.filter { !listed.contains($0) } + byAge
        var victims: [Int64] = []
        var freed = 0
        for id in candidates {
            if total - freed <= target { break }
            victims.append(id)
            freed += sizes[id] ?? 0
        }
        try deleteThumbs(victims)
        try thumbs.execute("PRAGMA incremental_vacuum")
        return freed
    }

    /// The bytes of all stored thumbnails: one pass over the blob lengths, which sit in the record headers,
    /// so no blob is read. The store asks once at open and keeps its own count after that.
    public func storedBytes() throws -> Int {
        var total = 0
        try thumbs.query("SELECT COALESCE(SUM(length(jpeg)), 0) FROM thumbs", []) { total = Int($0.int(0)) }
        return total
    }

    /// Empties `Thumbs.db` ("Clear Thumbnail Cache"); the catalog stays.
    public func clearThumbnails() throws {
        try Self.clear(thumbs)
    }

    /// Deletes the files that `isPresent` says are gone, from both databases. Nil means the file cannot be
    /// checked (its volume is not mounted) and keeps it: an unmounted share is not deleted photos.
    public func cleanUpOrphans(isPresent: (ThumbnailLocation) -> Bool?) throws {
        // Asked with no statement running: `isPresent` may take its time on a slow share.
        let gone = try catalogedFiles().filter { isPresent($0.location) == false }.map(\.id)
        try deleteFiles(gone)
    }

    /// Every catalogued file with where it lives: the first half of a clean-up, for a caller that checks
    /// presence elsewhere (off its actor) and then calls `deleteFiles`.
    public func catalogedFiles() throws -> [(id: Int64, location: ThumbnailLocation)] {
        var rows: [(id: Int64, location: ThumbnailLocation)] = []
        try catalog.query("""
            SELECT files.id, volumes.key, folders.path, files.name FROM files
            JOIN folders ON folders.id = files.folder JOIN volumes ON volumes.id = folders.volume
            """, []) { r in
            rows.append((r.int(0), ThumbnailLocation(volume: r.text(1), folder: r.text(2), name: r.text(3))))
        }
        return rows
    }

    // MARK: - Folder summaries

    /// The stored summary of the folder `location.folder` on `location.volume` (`name` is not used): a plain read, no
    /// write. A row whose `last_used` is older than `summaryStampWindow` is queued for restamping, written with the
    /// next `putSummaries` or when `pendingStampLimit` are waiting. Whether the summary is still fresh is the caller's
    /// to say (`folderModified` against the listing).
    public func summary(at location: ThumbnailLocation) throws -> FolderSummary? {
        var found: FolderSummary?
        var lastUsed = 0.0
        try catalog.query("""
            SELECT folder_mtime, photos, folders, bytes, first, last, histogram, dates_known, last_used
            FROM folder_summaries WHERE volume = ? AND path = ?
            """, [.text(location.volume), .text(location.folder)]) { r in
            func date(_ column: Int) -> Date? {
                r.isNull(column) ? nil : Date(timeIntervalSinceReferenceDate: r.double(column))
            }
            found = FolderSummary(photos: Int(r.int(1)), folders: Int(r.int(2)), bytes: r.isNull(3) ? nil : r.int(3),
                                  first: date(4), last: date(5), histogram: [UInt8](r.blob(6)),
                                  folderModified: date(0), datesKnown: r.int(7) != 0)
            lastUsed = r.double(8)
        }
        let time = now().timeIntervalSinceReferenceDate
        if found != nil, time - lastUsed > summaryStampWindow {
            pendingStamps[SummaryKey(volume: location.volume, path: location.folder)] = time
            if pendingStamps.count >= Self.pendingStampLimit { try catalog.transaction { try flushStamps() } }
        }
        return found
    }

    /// Writes the queued stamps (inside a transaction); a stamp never moves a row back in time.
    private func flushStamps() throws {
        guard !pendingStamps.isEmpty else { return }
        for (key, time) in pendingStamps {
            try catalog.run("UPDATE folder_summaries SET last_used = ? WHERE volume = ? AND path = ? AND last_used < ?",
                            [.double(time), .text(key.volume), .text(key.path), .double(time)])
        }
        pendingStamps.removeAll()
    }

    /// Reads waiting for a restamp (tests).
    var pendingStampCount: Int { pendingStamps.count }

    /// A row's `last_used` (tests).
    func summaryLastUsed(at location: ThumbnailLocation) throws -> Double? {
        var value: Double?
        try catalog.query("SELECT last_used FROM folder_summaries WHERE volume = ? AND path = ?",
                          [.text(location.volume), .text(location.folder)]) { value = $0.double(0) }
        return value
    }

    /// Stores summaries (a folder's again replaces its row) in one transaction, then drops the least recently used
    /// rows beyond `summaryCapacity`, in the same transaction: one commit and one eviction per batch, not per row.
    /// Stamps queued by reads go in the same transaction, before the eviction. In a batch larger than the cap the
    /// earlier rows of the batch are the ones dropped.
    public func putSummaries(_ items: [(location: ThumbnailLocation, summary: FolderSummary)]) throws {
        guard !items.isEmpty else { return }
        let time = SQLiteValue.double(now().timeIntervalSinceReferenceDate)
        try catalog.transaction {
            try flushStamps()
            for (location, summary) in items {
                func date(_ value: Date?) -> SQLiteValue {
                    value.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null
                }
                try catalog.run("""
                    INSERT INTO folder_summaries(volume, path, folder_mtime, photos, folders, bytes, first, last,
                                                 histogram, dates_known, last_used)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(volume, path) DO UPDATE SET folder_mtime = excluded.folder_mtime,
                        photos = excluded.photos, folders = excluded.folders, bytes = excluded.bytes,
                        first = excluded.first, last = excluded.last, histogram = excluded.histogram,
                        dates_known = excluded.dates_known, last_used = excluded.last_used
                    """, [.text(location.volume), .text(location.folder), date(summary.folderModified),
                           .int(Int64(summary.photos)), .int(Int64(summary.folders)),
                           summary.bytes.map { .int($0) } ?? .null, date(summary.first), date(summary.last),
                           .blob(Data(summary.histogram)), .int(summary.datesKnown ? 1 : 0), time])
            }
            // The newest rows of a batch share one `last_used`: the later rowid wins the tie.
            try catalog.run("""
                DELETE FROM folder_summaries WHERE rowid IN (
                    SELECT rowid FROM folder_summaries ORDER BY last_used DESC, rowid DESC LIMIT -1 OFFSET ?)
                """, [.int(Int64(max(0, summaryCapacity)))])
        }
    }

    /// Drops the stored summary of the folder `location.folder` on `location.volume` ("Refresh cover").
    public func deleteSummary(at location: ThumbnailLocation) throws {
        try catalog.run("DELETE FROM folder_summaries WHERE volume = ? AND path = ?",
                        [.text(location.volume), .text(location.folder)])
    }

    /// The photo counts of the stored summaries of the direct subfolders of `location.folder` (R8), by path: one range
    /// of the primary key (`volume`, then `path` from `folder/` up to `folder0`, '0' being the byte after '/'), the
    /// deeper ones left out in the query (SQLite's `substr` counts code points, hence `unicodeScalars`: macOS writes
    /// names decomposed), zips (their own summaries, not subfolders) after it. A plain read. Bounded by the table
    /// (`summaryCapacity`): in a table of 20 000 rows, a folder of 4 096 subfolders with a summary each reads in 4.5 ms,
    /// one of 100 in 0.13 ms (debug build, best of 20; 8-core i7-10700K, SSD; `measureChildSummaries`).
    public func childSummaries(of location: ThumbnailLocation) throws -> [String: Int] {
        let prefix = location.folder.hasSuffix("/") ? location.folder : location.folder + "/"
        let end = String(prefix.dropLast()) + "0"
        var found: [String: Int] = [:]
        try catalog.query("""
            SELECT path, photos FROM folder_summaries
            WHERE volume = ? AND path >= ? AND path < ? AND path != ? AND instr(substr(path, ?), '/') = 0
            """, [.text(location.volume), .text(prefix), .text(end), .text(prefix),
                  .int(Int64(prefix.unicodeScalars.count + 1))]) { r in
            let path = r.text(0)
            guard !path.lowercased().hasSuffix(".zip") else { return }
            found[path] = Int(r.int(1))
        }
        return found
    }

    /// A folder renamed (`from` to `to`, folder paths on `volume`): its summary and those of every folder under it
    /// move with it, its folder date unchanged (a rename changes the parent's, not the folder's), so the card under
    /// the new name finds it fresh. Rows at `to` or under it are stale (nothing was there) and go first.
    public func moveSummaries(volume: String, from: String, to: String) throws {
        guard from != to, !from.isEmpty, from != "/" else { return }
        // Under a folder: from "folder/" up to "folder0" ("0" follows "/"), as `childSummaries`.
        func under(_ path: String) -> [SQLiteValue] { [.text(path), .text(path + "/"), .text(path + "0")] }
        try catalog.transaction {
            try flushStamps()
            try catalog.run("DELETE FROM folder_summaries WHERE volume = ? AND (path = ? OR (path >= ? AND path < ?))",
                            [.text(volume)] + under(to))
            // substr counts code points from 1, as `childSummaries`' (names are often decomposed on macOS).
            try catalog.run("""
                UPDATE folder_summaries SET path = ? || substr(path, ?)
                WHERE volume = ? AND (path = ? OR (path >= ? AND path < ?))
                """, [.text(to), .int(Int64(from.unicodeScalars.count + 1)), .text(volume)] + under(from))
        }
    }

    /// Rows in `folder_summaries`.
    public func summaryCount() throws -> Int {
        var count = 0
        try catalog.query("SELECT COUNT(*) FROM folder_summaries", []) { count = Int($0.int(0)) }
        return count
    }

    /// Removes these files from both databases (thumbnails first, see the invariant above) and returns the
    /// space to the file system.
    public func deleteFiles(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try catalog.transaction {
            try deleteThumbs(ids)
            try catalog.run("DELETE FROM files WHERE id IN (SELECT value FROM json_each(?))", [Self.idList(ids)])
        }
        try thumbs.execute("PRAGMA incremental_vacuum")
    }

    /// Closes both connections; any later call throws. For a caller about to delete the files.
    public func close() {
        catalog.close()
        thumbs.close()
    }

    /// Deletes both databases with their `-wal` / `-shm` from `directory`, and the damaged ones `setAside`
    /// kept (`thumb-cache-size=0`: no traces on disk, neither thumbnails nor the folder and file names of the
    /// catalog). Close every connection to them first. A later open makes new, empty ones.
    public static func removeFiles(in directory: URL) {
        let fm = FileManager.default
        let names = ["Catalog.db", "Thumbs.db"]
        for name in names {
            let path = directory.appendingPathComponent(name).path
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: path + suffix) }
        }
        let present = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in present where names.contains(where: { name.hasPrefix($0 + ".broken-") }) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// When either file was deleted or replaced under the open connections (the user emptied
    /// `Caches/Loupe`), closes both and opens them again, creating what is missing; a new `Catalog.db` gets
    /// a new `catalog_id` and so empties `Thumbs.db`. Returns what was recreated: after `.catalog` no
    /// earlier file id may be used again (see `Reopened`).
    public func reopenIfDeleted() throws -> Reopened {
        let catalogChanged = catalog.fileChanged
        guard catalogChanged || thumbs.fileChanged else { return .nothing }
        catalog.close()
        thumbs.close()
        let oldID = catalogID
        (catalog, thumbs, catalogID) = try Self.openBoth(directory: directory, thumbSize: thumbSize)
        // The id also changes when the catalog is reopened only alongside `Thumbs.db` and turns out corrupt.
        return catalogChanged || catalogID != oldID ? .catalog : .thumbnails
    }

    /// After a call threw `SQLITE_CORRUPT` / `SQLITE_NOTADB` while running (open only catches what the
    /// first statements touch): sets the damaged file aside and opens both anew. The error does not say
    /// which file it came from, so the small catalog is checked (`quick_check`, milliseconds) and set aside
    /// only when it fails; `Thumbs.db`, by far the likelier one, always goes. Returns `.catalog` when the
    /// catalog was replaced (every file id is void), `.thumbnails` otherwise.
    public func replaceDamaged() throws -> Reopened {
        var catalogOK = false
        try? catalog.query("PRAGMA quick_check(1)", []) { catalogOK = $0.text(0) == "ok" }
        catalog.close()
        thumbs.close()
        try Self.setAside(directory.appendingPathComponent("Thumbs.db"), reason: "a query failed")
        if !catalogOK { try Self.setAside(directory.appendingPathComponent("Catalog.db"), reason: "a query failed") }
        let oldID = catalogID
        (catalog, thumbs, catalogID) = try Self.openBoth(directory: directory, thumbSize: thumbSize)
        return catalogID != oldID ? .catalog : .thumbnails
    }

    /// Whether `error` means the file itself is damaged (and should be set aside), not just a failed call.
    public static func isDamage(_ error: Error) -> Bool {
        guard let error = error as? SQLiteError else { return false }
        return [SQLITE_CORRUPT, SQLITE_NOTADB].contains(error.code & 0xFF)
    }

    // MARK: - Opening

    private static let sharedPragmas = ["auto_vacuum=INCREMENTAL", "journal_mode=WAL", "synchronous=NORMAL",
                                        "checkpoint_fullfsync=OFF", "busy_timeout=2000"]
    private static let catalogPragmas = sharedPragmas + ["mmap_size=268435456", "cache_size=-65536"]
    /// `page_size` before anything else: it only applies while the file is still empty.
    private static let thumbsPragmas = ["page_size=16384"] + sharedPragmas

    private static let metaSchema = "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);"
    /// File ids are AUTOINCREMENT so, within one catalog, a deleted file's id is never handed to another
    /// one: a stray blob left under an old id cannot pass for a different photo's thumbnail. The counter
    /// lives in the catalog itself, so a recreated `Catalog.db` starts over at 1; that is why a new catalog
    /// empties `Thumbs.db` and `reopenIfDeleted` reports `.catalog`.
    private static let catalogSchema = metaSchema + """
        CREATE TABLE IF NOT EXISTS volumes(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE);
        CREATE TABLE IF NOT EXISTS folders(id INTEGER PRIMARY KEY, volume INTEGER NOT NULL, path TEXT NOT NULL,
            last_access REAL NOT NULL);
        CREATE UNIQUE INDEX IF NOT EXISTS folders_volume_path ON folders(volume, path);
        CREATE INDEX IF NOT EXISTS folders_last_access ON folders(last_access);
        CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY AUTOINCREMENT, folder INTEGER NOT NULL,
            name TEXT NOT NULL, size INTEGER NOT NULL, mtime REAL NOT NULL,
            width INTEGER, height INTEGER, uti TEXT, progressive INTEGER, file_size INTEGER, color_space TEXT,
            orientation INTEGER, last_access REAL NOT NULL);
        CREATE UNIQUE INDEX IF NOT EXISTS files_folder_name ON files(folder, name);
        CREATE INDEX IF NOT EXISTS files_last_access ON files(last_access);
        """
    /// Folder cards' facts (`FolderSummary`), keyed by the volume's text key and the folder's path (not by the
    /// `volumes` / `folders` ids: a summary outlives the folder's file rows, which a clean-up deletes). Created with
    /// `IF NOT EXISTS` on every open and kept out of `catalogSchema`'s format check: adding it changes no
    /// `format_version`, so an existing catalog keeps its rows. Dates are `timeIntervalSinceReferenceDate` (REAL, as
    /// elsewhere), NULL when unknown; `histogram` is 12 bytes, empty when there is none.
    private static let summarySchema = """
        CREATE TABLE IF NOT EXISTS folder_summaries(volume TEXT NOT NULL, path TEXT NOT NULL, folder_mtime REAL,
            photos INTEGER NOT NULL, folders INTEGER NOT NULL, bytes INTEGER, first REAL, last REAL,
            histogram BLOB NOT NULL, dates_known INTEGER NOT NULL, last_used REAL NOT NULL,
            PRIMARY KEY(volume, path));
        CREATE INDEX IF NOT EXISTS folder_summaries_last_used ON folder_summaries(last_used);
        """
    private static let thumbsSchema = metaSchema
        + "CREATE TABLE IF NOT EXISTS thumbs(file_id INTEGER PRIMARY KEY, jpeg BLOB NOT NULL);"

    private static func openBoth(directory: URL, thumbSize: Int)
        throws -> (catalog: SQLiteConnection, thumbs: SQLiteConnection, catalogID: String) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var catalogID = ""
        let catalog = try open(directory.appendingPathComponent("Catalog.db"), pragmas: catalogPragmas) { db in
            try db.execute(metaSchema)
            // A catalog of another format starts anew (its rows lack what this one stores): a new catalog id, so
            // `Thumbs.db` is emptied below, and every file id handed out before is void.
            if let format = try readMeta(db)["format_version"], format != String(formatVersion) {
                try db.execute("""
                    DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS folders; DROP TABLE IF EXISTS volumes;
                    DELETE FROM meta;
                    """)
            }
            try db.execute(catalogSchema)
            try db.execute(summarySchema)
            // A catalog without an id is a new one (or the remains of one): it gets a new id.
            catalogID = try readMeta(db)["catalog_id"] ?? UUID().uuidString
            try writeMeta(db, catalogID: catalogID, thumbSize: thumbSize)
        }
        let thumbs = try open(directory.appendingPathComponent("Thumbs.db"), pragmas: thumbsPragmas) { db in
            try db.execute(thumbsSchema)
            let meta = try readMeta(db)
            if meta["catalog_id"] != catalogID || meta["format_version"] != String(formatVersion)
                || meta["thumb_size"] != String(thumbSize) {
                try clear(db)
                try writeMeta(db, catalogID: catalogID, thumbSize: thumbSize)
            }
        }
        return (catalog, thumbs, catalogID)
    }

    /// Opens one database and runs `prepare` on it. A corrupt file (`SQLITE_CORRUPT`, `SQLITE_NOTADB`) is
    /// set aside (`setAside`) and the database made anew. A `-wal` / `-shm` left without its database is
    /// removed first: replayed into a new file it would bring back pages of the old one.
    private static func open(_ url: URL, pragmas: [String],
                             prepare: (SQLiteConnection) throws -> Void) throws -> SQLiteConnection {
        let fm = FileManager.default
        func removeSidecars() {
            for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
        }
        func attempt() throws -> SQLiteConnection {
            if !fm.fileExists(atPath: url.path) { removeSidecars() }
            let db = try SQLiteConnection(path: url.path, pragmas: pragmas)
            do { try prepare(db) } catch { db.close(); throw error }
            return db
        }
        do {
            return try attempt()
        } catch let error as SQLiteError where isDamage(error) {
            try setAside(url, reason: error.message)
            return try attempt()
        }
    }

    /// Renames a damaged database to `<name>.broken-<unix time>` (kept for a look, but only the latest:
    /// older ones go) and removes its `-wal` / `-shm`, so the next open starts a new file.
    static func setAside(_ url: URL, reason: String) throws {
        let fm = FileManager.default
        let broken = url.lastPathComponent + ".broken-\(Int(Date().timeIntervalSince1970))"
        let dir = url.deletingLastPathComponent()
        try? fm.removeItem(at: dir.appendingPathComponent(broken))
        if fm.fileExists(atPath: url.path) { try fm.moveItem(at: url, to: dir.appendingPathComponent(broken)) }
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
        FileHandle.standardError.write(Data(
            "loupe: \(url.path) is damaged (\(reason)); set aside as \(broken), starting anew\n".utf8))
        let older = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in older where name.hasPrefix(url.lastPathComponent + ".broken-") && name != broken {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private static func readMeta(_ db: SQLiteConnection) throws -> [String: String] {
        var meta: [String: String] = [:]
        try db.query("SELECT key, value FROM meta", []) { meta[$0.text(0)] = $0.text(1) }
        return meta
    }

    private static func writeMeta(_ db: SQLiteConnection, catalogID: String, thumbSize: Int) throws {
        let wanted = ["catalog_id": catalogID, "format_version": String(formatVersion), "thumb_size": String(thumbSize)]
        guard try readMeta(db) != wanted else { return }
        try db.transaction {
            for (key, value) in wanted {
                try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           [.text(key), .text(value)])
            }
        }
    }

    private static func clear(_ thumbs: SQLiteConnection) throws {
        try thumbs.transaction { try thumbs.execute("DELETE FROM thumbs") }
        try thumbs.execute("PRAGMA incremental_vacuum")
    }

    // MARK: - Helpers

    private func deleteThumbs(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try thumbs.transaction {
            try thumbs.run("DELETE FROM thumbs WHERE file_id IN (SELECT value FROM json_each(?))", [Self.idList(ids)])
        }
    }

    /// Ids as a JSON array for `json_each`: one cached statement for any number of them.
    private static func idList(_ ids: [Int64]) -> SQLiteValue {
        .text("[" + ids.map(String.init).joined(separator: ",") + "]")
    }
}
