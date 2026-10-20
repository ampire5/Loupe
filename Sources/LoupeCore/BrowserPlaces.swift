import Foundation

/// The file browser's own state in Loupe.db (file browser spec §4.2): the folders pinned to Places, in the order they
/// were pinned, and the folder it last showed (`browser-last-folder`). Changes are rare (a click each), so each one is
/// written at once; without a database everything stays in memory.
public final class BrowserPlaces: PathMoving, @unchecked Sendable {
    public static let lastFolderKey = "browser-last-folder"

    private let database: StateDatabase?
    private let lock = NSLock()
    private let failureLog = WriteFailureLog()
    private var pinned: [String] = []
    private var last: String?

    public init(database: StateDatabase?) {
        self.database = database
        try? database?.perform { db in
            try db.query("SELECT path FROM browser_pins ORDER BY pinned, rowid", []) { pinned.append($0.text(0)) }
            try db.query("SELECT value FROM browser_state WHERE key = ?", [.text(Self.lastFolderKey)]) { last = $0.text(0) }
        }
    }

    public func pins() -> [URL] {
        lock.withLock { pinned.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    }

    public func isPinned(_ folder: URL) -> Bool {
        lock.withLock { pinned.contains(folder.standardizedFileURL.path) }
    }

    public func pin(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard lock.withLock({ () -> Bool in
            guard !pinned.contains(path) else { return false }
            pinned.append(path)
            return true
        }) else { return }
        write { try $0.run("INSERT OR REPLACE INTO browser_pins(path, pinned) VALUES(?, ?)",
                           [.text(path), .double(Date().timeIntervalSinceReferenceDate)]) }
    }

    public func unpin(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        lock.withLock { pinned.removeAll { $0 == path } }
        write { try $0.run("DELETE FROM browser_pins WHERE path = ?", [.text(path)]) }
    }

    public var lastFolder: URL? {
        get { lock.withLock { last.map { URL(fileURLWithPath: $0, isDirectory: true) } } }
        set {
            let path = newValue?.standardizedFileURL.path
            lock.withLock { last = path }
            write { db in
                if let path {
                    try db.run("INSERT OR REPLACE INTO browser_state(key, value) VALUES(?, ?)",
                               [.text(Self.lastFolderKey), .text(path)])
                } else {
                    try db.run("DELETE FROM browser_state WHERE key = ?", [.text(Self.lastFolderKey)])
                }
            }
        }
    }

    /// A folder renamed: the pins and the last folder at or under `from` follow it to `to`.
    public func movePaths(from: URL, to: URL) {
        let move = PathMove(from: from, to: to)
        let moved = move.moved
        let (changes, lastMoved) = lock.withLock { () -> ([(String, String)], String?) in
            var changes: [(String, String)] = []
            pinned = pinned.map { path in
                guard let to = moved(path) else { return path }
                changes.append((path, to))
                return to
            }
            let lastMoved = last.flatMap(moved)
            if let lastMoved { last = lastMoved }
            return (changes, lastMoved)
        }
        write { db in
            for (from, to) in changes {
                try db.run("UPDATE browser_pins SET path = ? WHERE path = ?", [.text(to), .text(from)])
            }
            if let lastMoved {
                try db.run("INSERT OR REPLACE INTO browser_state(key, value) VALUES(?, ?)",
                           [.text(Self.lastFolderKey), .text(lastMoved)])
            }
        }
    }

    /// The free space of each volume (Places' cards: `1.2 TB free`), each asked on a thread of its own and given
    /// `timeout`: a share that does not answer is left out, never waited for.
    public static func freeSpace(of volumes: [URL], timeout: Duration,
                                 query: @escaping @Sendable (URL) -> Int64? = BrowserPlaces.available) async -> [URL: Int64] {
        await withTaskGroup(of: (URL, Int64?).self) { group in
            for volume in volumes {
                group.addTask { (volume, await HomeGrid.value(within: timeout) { query(volume) } ?? nil) }
            }
            var out: [URL: Int64] = [:]
            for await (volume, space) in group { if let space { out[volume] = space } }
            return out
        }
    }

    /// The space a volume has for what the user puts there.
    @Sendable public static func available(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                       .volumeAvailableCapacityKey])
        return available(important: values?.volumeAvailableCapacityForImportantUsage, plain: values?.volumeAvailableCapacity)
    }

    /// The "important usage" figure where the system gives one; external disks and shares give 0 there, so the plain
    /// capacity; 0 from both is no answer.
    static func available(important: Int64?, plain: Int?) -> Int64? {
        if let important, important > 0 { return important }
        if let plain, plain > 0 { return Int64(plain) }
        return nil
    }

    private func write(_ body: (SQLiteConnection) throws -> Void) {
        guard let database else { return }
        do {
            try database.perform { try body($0) }
            failureLog.succeeded()
        } catch {
            failureLog.failed(error)
        }
    }
}
