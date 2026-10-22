import Foundation

/// The photo last viewed in each folder, so jumping back to a folder lands where the user left it, and how it was
/// being looked at then (`SavedView`, set when the viewer leaves it), so it reopens at that zoom and spot.
/// Keyed by standardized folder path, least recently recorded dropped beyond `capacity`, kept in `Loupe.db`
/// (`folder_positions`) across launches. Recording is cheap and synchronous; the database is written on a
/// background queue, one transaction per batch, at most once per `debounce` and by `flush()` (the app calls it
/// on quit).
public final class FolderPositions: @unchecked Sendable {
    public static let defaultCapacity = 1000

    private struct Entry { var file: String; var view: SavedView?; var tick: Int; var visit: FolderVisit? = nil }

    private let database: StateDatabase?
    private let capacity: Int
    private let debounce: Duration
    private let queue = DispatchQueue(label: "loupe.folder-positions", qos: .utility)
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var tick = 0
    /// Folders changed since the last write (their entry, or none when dropped, is what gets written).
    private var dirty: Set<String> = []
    private var writeScheduled = false
    /// How many times the database was written (for tests: debouncing coalesces).
    private var writeCount = 0
    private let failureLog = WriteFailureLog()

    /// Loads the newest `capacity` positions from `database` (none when it is unreadable); nil keeps everything
    /// in memory.
    public init(database: StateDatabase?, capacity: Int = defaultCapacity, debounce: Duration = .seconds(2)) {
        self.database = database
        self.capacity = max(1, capacity)
        self.debounce = debounce
        try? database?.perform { db in
            try db.query("SELECT path, file, view, touched, idx, count, visited FROM folder_positions ORDER BY touched DESC LIMIT ?",
                         [.int(Int64(self.capacity))]) { r in
                let view = r.isNull(2) ? nil : SavedView(text: r.text(2))
                let visit = r.isNull(4) || r.isNull(5) || r.isNull(6) ? nil
                    : FolderVisit(index: Int(r.int(4)), count: Int(r.int(5)),
                                  visited: Date(timeIntervalSinceReferenceDate: r.double(6)))
                entries[r.text(0)] = Entry(file: r.text(1), view: view, tick: Int(r.int(3)), visit: visit)
                tick = max(tick, Int(r.int(3)))
            }
        }
    }

    var writes: Int { lock.withLock { writeCount } }

    public var count: Int { lock.withLock { entries.count } }

    /// `file` (a file name) is now the current photo of `folder`. The view saved for it stays if it was the
    /// folder's photo already; another file starts with none, or with the folder's view when `keepingView`
    /// (`folder-view-memory=folder`: the view survives photos that never get shown; `record(…view:)` overwrites it
    /// with the real one).
    public func record(folder: URL, file: String, keepingView: Bool = false) {
        record(folder: folder, file: file, view: keepingView ? view(in: folder) : view(in: folder, file: file))
    }

    /// `file` is the current photo of `folder`, looked at as `view` (nil: no saved view).
    public func record(folder: URL, file: String, view: SavedView?) {
        let key = folder.standardizedFileURL.path
        let schedule = lock.withLock { () -> Bool in
            // Already the latest.
            if let e = entries[key], e.file == file, e.view == view, e.tick == tick { return false }
            tick += 1
            entries[key] = Entry(file: file, view: view, tick: tick, visit: entries[key]?.visit)
            dirty.insert(key)
            if entries.count > capacity, let oldest = entries.min(by: { $0.value.tick < $1.value.tick }) {
                entries[oldest.key] = nil
                dirty.insert(oldest.key)
            }
            guard database != nil, !writeScheduled else { return false }
            writeScheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + debounce.seconds) { [self] in
            lock.withLock { writeScheduled = false }
            write()
        }
    }

    /// The folder was on screen at photo `index` of `count` at `date`. Kept with the folder's position (one row, one
    /// debounced write with it), so calling it on every photo change costs memory only; a folder with no position
    /// yet (`record` not called) remembers nothing.
    public func recordVisit(folder: URL, index: Int, count: Int, at date: Date = Date()) {
        let key = folder.standardizedFileURL.path
        let schedule = lock.withLock { () -> Bool in
            guard entries[key] != nil else { return false }
            entries[key]?.visit = FolderVisit(index: index, count: count, visited: date)
            dirty.insert(key)
            guard database != nil, !writeScheduled else { return false }
            writeScheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + debounce.seconds) { [self] in
            lock.withLock { writeScheduled = false }
            write()
        }
    }

    /// The last visit to `folder`; nil when none was recorded.
    public func visit(in folder: URL) -> FolderVisit? {
        lock.withLock { entries[folder.standardizedFileURL.path]?.visit }
    }

    /// The file name remembered for `folder`.
    public func fileName(in folder: URL) -> String? {
        lock.withLock { entries[folder.standardizedFileURL.path]?.file }
    }

    /// The view saved for `file` in `folder`; nil when the folder remembers another file or no view.
    public func view(in folder: URL, file: String) -> SavedView? {
        lock.withLock { entries[folder.standardizedFileURL.path].flatMap { $0.file == file ? $0.view : nil } }
    }

    /// The view saved in `folder`, whichever file it was saved with (`folder-view-memory=folder`); nil without one.
    public func view(in folder: URL) -> SavedView? {
        lock.withLock { entries[folder.standardizedFileURL.path]?.view }
    }

    /// The remembered file of `folder` if it is among `files` (so a deleted one gives nil).
    public func recall(in folder: URL, among files: [URL]) -> URL? {
        guard let name = fileName(in: folder) else { return nil }
        return files.first { $0.lastPathComponent == name }
    }

    /// Writes pending changes now and waits for the write; for quitting.
    public func flush() {
        queue.sync { write() }
    }

    /// One transaction for everything changed since the last write: each changed folder's row is replaced or
    /// deleted, then the least recently touched beyond `capacity` go too. A failure keeps the changes pending
    /// for the next change or flush.
    private func write() {
        guard let database else { return }
        let batch: [(path: String, entry: Entry?)] = lock.withLock {
            let paths = dirty
            dirty = []
            return paths.map { ($0, entries[$0]) }
        }
        guard !batch.isEmpty else { return }
        do {
            try database.perform { db in
                try db.transaction {
                    for (path, entry) in batch {
                        if let entry {
                            try db.run("""
                                INSERT INTO folder_positions(path, file, view, touched, idx, count, visited)
                                VALUES(?, ?, ?, ?, ?, ?, ?)
                                ON CONFLICT(path) DO UPDATE SET
                                    file = excluded.file, view = excluded.view, touched = excluded.touched,
                                    idx = excluded.idx, count = excluded.count, visited = excluded.visited
                                """, [.text(path), .text(entry.file), entry.view.map { .text($0.text) } ?? .null,
                                      .int(Int64(entry.tick)),
                                      entry.visit.map { .int(Int64($0.index)) } ?? .null,
                                      entry.visit.map { .int(Int64($0.count)) } ?? .null,
                                      entry.visit.map { .double($0.visited.timeIntervalSinceReferenceDate) } ?? .null])
                        } else {
                            try db.run("DELETE FROM folder_positions WHERE path = ?", [.text(path)])
                        }
                    }
                    try db.run("""
                        DELETE FROM folder_positions WHERE path IN
                        (SELECT path FROM folder_positions ORDER BY touched DESC LIMIT -1 OFFSET ?)
                        """, [.int(Int64(capacity))])
                }
            }
            lock.withLock { writeCount += 1 }
            failureLog.succeeded()
        } catch {
            failureLog.failed(error)
            lock.withLock { dirty.formUnion(batch.map(\.path)) }
        }
    }
}

extension FolderPositions: PathMoving {
    /// A rename in the file browser: the folders at or under `from` move, and a folder's photo that was renamed keeps
    /// its place under the new name.
    public func movePaths(from: URL, to: URL) {
        let move = PathMove(from: from, to: to)
        let schedule = lock.withLock { () -> Bool in
            for (key, entry) in entries {
                if let new = move.moved(key) {
                    entries[key] = nil
                    entries[new] = entry
                    dirty.formUnion([key, new])
                } else if let name = move.renamedFile(entry.file, in: key) {
                    entries[key]?.file = name
                    dirty.insert(key)
                }
            }
            guard !dirty.isEmpty, database != nil, !writeScheduled else { return false }
            writeScheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + debounce.seconds) { [self] in
            lock.withLock { writeScheduled = false }
            write()
        }
    }
}
