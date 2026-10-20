import Foundation

/// Settings (key → text value, as in `loupe.conf`) that apply to a folder and everything below it, so a
/// folder of scans can scale differently from a folder of phone shots. A folder's effective values are its
/// own, then per key the nearest ancestor's. Keyed by standardized folder path, least recently changed folder
/// dropped beyond `capacity`, kept in `Loupe.db` (`folder_settings`) across launches. Changing is cheap and
/// synchronous; the database is written on a background queue, one transaction per batch, at most once per
/// `debounce` and by `flush()` (the app calls it on quit). Nothing is ever written into the photo folders
/// themselves.
public final class FolderSettings: @unchecked Sendable {
    public static let defaultCapacity = 1000

    private struct Entry { var values: [String: String]; var tick: Int }

    private let database: StateDatabase?
    private let capacity: Int
    private let debounce: Duration
    private let queue = DispatchQueue(label: "loupe.folder-settings", qos: .utility)
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var tick = 0
    /// Folders changed since the last write (their entry, or none when forgotten, is what gets written).
    private var dirty: Set<String> = []
    private var writeScheduled = false
    /// How many times the database was written (for tests: debouncing coalesces).
    private var writeCount = 0
    private let failureLog = WriteFailureLog()

    /// Called, on the caller's thread and outside the lock, by every `set` / `clear` that changed something.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }
    private var changeHandler: (@Sendable () -> Void)?

    /// Loads the newest `capacity` folders from `database` (none when it is unreadable); nil keeps everything in
    /// memory.
    public init(database: StateDatabase?, capacity: Int = defaultCapacity, debounce: Duration = .seconds(2)) {
        self.database = database
        self.capacity = max(1, capacity)
        self.debounce = debounce
        try? database?.perform { db in
            // A folder's recency is its newest row's.
            try db.query("SELECT path, key, value, touched FROM folder_settings", []) { r in
                var entry = entries[r.text(0)] ?? Entry(values: [:], tick: 0)
                entry.values[r.text(1)] = r.text(2)
                entry.tick = max(entry.tick, Int(r.int(3)))
                entries[r.text(0)] = entry
                tick = max(tick, entry.tick)
            }
        }
        for (path, _) in entries.sorted(by: { $0.value.tick > $1.value.tick }).dropFirst(self.capacity) {
            entries[path] = nil
        }
    }

    var writes: Int { lock.withLock { writeCount } }

    /// How many folders have settings of their own.
    public var count: Int { lock.withLock { entries.count } }

    /// What applies in `folder`: its own values, and per key the nearest ancestor's where it has none.
    public func values(for folder: URL) -> [String: String] {
        merged(Self.chain(of: folder)[...])
    }

    /// The records along `chain` (nearest first), the nearer one winning per key.
    private func merged(_ chain: ArraySlice<String>) -> [String: String] {
        lock.withLock {
            var merged: [String: String] = [:]
            for path in chain {
                guard let own = entries[path]?.values else { continue }
                merged.merge(own) { nearer, _ in nearer }
            }
            return merged
        }
    }

    /// What `folder` would have without its own record: per key the nearest ancestor's, within the same bounds as
    /// `values(for:)` (a volume's root under `/Volumes` has no ancestors).
    public func inheritedValues(for folder: URL) -> [String: String] {
        merged(Self.chain(of: folder).dropFirst())
    }

    /// Only what `folder` itself records, nothing inherited.
    public func ownValues(for folder: URL) -> [String: String] {
        lock.withLock { entries[folder.standardizedFileURL.path]?.values ?? [:] }
    }

    /// Records `value` for `key` in `folder` (nil removes it). A folder left with no values is forgotten.
    public func set(_ key: String, _ value: String?, for folder: URL) {
        change(folder) { $0[key] = value }
    }

    /// Removes `keys` from `folder`.
    public func clear(_ keys: [String], for folder: URL) {
        change(folder) { values in for key in keys { values[key] = nil } }
    }

    /// Writes pending changes now and waits for the write; for quitting.
    public func flush() {
        queue.sync { write() }
    }

    /// `folder` itself, then each parent up to the root; under `/Volumes/<name>` up to that volume only.
    static func chain(of folder: URL) -> [String] {
        let components = folder.standardizedFileURL.pathComponents      // ["/", "Volumes", "share", …]
        let floor = components.count > 2 && components[1] == "Volumes" ? 3 : 1
        var chain: [String] = []
        var depth = components.count
        while depth >= floor {
            chain.append(depth == 1 ? "/" : "/" + components[1..<depth].joined(separator: "/"))
            depth -= 1
        }
        return chain
    }

    private func change(_ folder: URL, _ edit: (inout [String: String]) -> Void) {
        let key = folder.standardizedFileURL.path
        let (handler, schedule) = lock.withLock { () -> ((@Sendable () -> Void)?, Bool) in
            let before = entries[key]?.values ?? [:]
            var after = before
            edit(&after)
            guard after != before else { return (nil, false) }
            dirty.insert(key)
            if after.isEmpty {
                entries[key] = nil
            } else {
                tick += 1
                entries[key] = Entry(values: after, tick: tick)
                if entries.count > capacity, let oldest = entries.min(by: { $0.value.tick < $1.value.tick }) {
                    entries[oldest.key] = nil
                    dirty.insert(oldest.key)
                }
            }
            guard database != nil, !writeScheduled else { return (changeHandler, false) }
            writeScheduled = true
            return (changeHandler, true)
        }
        if schedule {
            queue.asyncAfter(deadline: .now() + debounce.seconds) { [self] in
                lock.withLock { writeScheduled = false }
                write()
            }
        }
        handler?()
    }

    /// One transaction for everything changed since the last write: each changed folder's rows are replaced (or
    /// deleted), then the least recently touched folders beyond `capacity` go too. A failure keeps the changes
    /// pending for the next change or flush.
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
                        try db.run("DELETE FROM folder_settings WHERE path = ?", [.text(path)])
                        guard let entry else { continue }
                        for (key, value) in entry.values {
                            try db.run("INSERT INTO folder_settings(path, key, value, touched) VALUES(?, ?, ?, ?)",
                                       [.text(path), .text(key), .text(value), .int(Int64(entry.tick))])
                        }
                    }
                    try db.run("""
                        DELETE FROM folder_settings WHERE path IN
                        (SELECT path FROM folder_settings GROUP BY path ORDER BY MAX(touched) DESC LIMIT -1 OFFSET ?)
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

extension FolderSettings: PathMoving {
    /// A rename in the file browser: the settings of the folders at or under `from` move with them.
    public func movePaths(from: URL, to: URL) {
        let move = PathMove(from: from, to: to)
        let (changed, handler, schedule) = lock.withLock { () -> (Bool, (@Sendable () -> Void)?, Bool) in
            var changed = false
            for (key, entry) in entries {
                guard let new = move.moved(key) else { continue }
                entries[key] = nil
                entries[new] = entry
                dirty.formUnion([key, new])
                changed = true
            }
            guard changed, database != nil, !writeScheduled else { return (changed, changeHandler, false) }
            writeScheduled = true
            return (true, changeHandler, true)
        }
        if schedule {
            queue.asyncAfter(deadline: .now() + debounce.seconds) { [self] in
                lock.withLock { writeScheduled = false }
                write()
            }
        }
        if changed { handler?() }
    }
}
