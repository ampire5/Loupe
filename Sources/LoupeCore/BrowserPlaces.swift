import Foundation

/// The file browser's state in Loupe.db: ordered favorites and the last folder (`browser-last-folder`).
/// Favorites use the existing `browser_pins` table. Mutations may write to disk and belong off the main thread.
public final class BrowserPlaces: PathMoving, @unchecked Sendable {
    public static let lastFolderKey = "browser-last-folder"
    public static let favoritesDidChange = Notification.Name("LoupeFolderFavoritesDidChange")
    package static let favoriteAvailabilityDidChange = Notification.Name("LoupeFolderFavoriteAvailabilityDidChange")

    private let database: StateDatabase?
    private let lock = NSLock()
    private let writer = NSLock()
    private let failureLog = WriteFailureLog()
    private struct State: Equatable {
        var pinned: [String] = []
        var last: String?
    }
    private var state = State()

    @MainActor package private(set) var favoriteAvailabilityRevision = 0
    @MainActor private var favoriteAvailability: [String: Bool] = [:]
    @MainActor private var favoriteCheck: (paths: Set<String>, task: Task<Void, Never>)?

    public init(database: StateDatabase?) {
        self.database = database
        try? database?.perform { db in
            try db.query("SELECT path FROM browser_pins ORDER BY pinned, rowid", []) { state.pinned.append($0.text(0)) }
            try db.query("SELECT value FROM browser_state WHERE key = ?", [.text(Self.lastFolderKey)]) { state.last = $0.text(0) }
        }
    }

    public func pins() -> [URL] {
        let paths = lock.withLock { state.pinned }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func isPinned(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return lock.withLock { state.pinned.contains(path) }
    }

    @MainActor package func sidebarFavorites() -> [(url: URL, available: Bool)] {
        pins().map { ($0, favoriteAvailability[$0.path] ?? true) }
    }

    /// Home windows share an in-flight check for the same folders. Order changes can use the cached answer
    /// immediately. Missing or unanswered paths become dimmed when the bounded probe finishes.
    @MainActor package func refreshFavoriteAvailability() {
        let paths = lock.withLock { state.pinned }
        let membership = Set(paths)
        guard favoriteCheck?.paths != membership else { return }
        invalidateFavoriteAvailability()
        favoriteAvailability = favoriteAvailability.filter { membership.contains($0.key) }
        guard !paths.isEmpty else { return }
        let task = Task { [weak self] in
            let checked = await HomeGrid.directoryAvailability(of: paths, timeout: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            favoriteCheck = nil
            guard lock.withLock({ Set(state.pinned) }) == membership else { return }
            let available = Dictionary(uniqueKeysWithValues: paths.map { ($0, checked[$0] == .some(true)) })
            let changed = available.contains { (favoriteAvailability[$0.key] ?? true) != $0.value }
            favoriteAvailability = available
            if changed {
                favoriteAvailabilityRevision += 1
                NotificationCenter.default.post(name: Self.favoriteAvailabilityDidChange, object: self)
            }
        }
        favoriteCheck = (membership, task)
    }

    @MainActor package func invalidateFavoriteAvailability() {
        favoriteCheck?.task.cancel()
        favoriteCheck = nil
    }

    public func pin(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        update { state in
            guard !state.pinned.contains(path) else { return }
            state.pinned.append(path)
        }
    }

    public func unpin(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        update { $0.pinned.removeAll { $0 == path } }
    }

    public func movePin(_ folder: URL, before other: URL?) {
        let path = folder.standardizedFileURL.path
        let anchor = other?.standardizedFileURL.path
        update { state in
            guard path != anchor, let index = state.pinned.firstIndex(of: path) else { return }
            if let anchor, !state.pinned.contains(anchor) { return }
            state.pinned.remove(at: index)
            let destination = anchor.flatMap { state.pinned.firstIndex(of: $0) } ?? state.pinned.endIndex
            state.pinned.insert(path, at: destination)
        }
    }

    public var lastFolder: URL? {
        get { lock.withLock { state.last }.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set {
            let path = newValue?.standardizedFileURL.path
            update { $0.last = path }
        }
    }

    /// A folder renamed: the pins and the last folder at or under `from` follow it to `to`.
    public func movePaths(from: URL, to: URL) {
        let move = PathMove(from: from, to: to)
        update { state in
            let destinations = Set(state.pinned.compactMap(move.moved))
            // A previously missing destination may itself be a favorite. Keep the moved favorite's position.
            state.pinned = state.pinned.compactMap { path in
                move.moved(path) ?? (destinations.contains(path) ? nil : path)
            }
            if let movedLast = state.last.flatMap(move.moved) { state.last = movedLast }
        }
    }

    /// A single snapshot is committed before readers see it. The read lock is held only while copying state.
    private func update(_ change: (inout State) -> Void) {
        let favoritesChanged = writer.withLock {
            let old = lock.withLock { state }
            var next = old
            change(&next)
            guard next != old else { return false }
            do {
                try database?.perform { db in
                    try db.transaction {
                        if next.pinned != old.pinned {
                            let kept = Set(next.pinned)
                            for path in old.pinned where !kept.contains(path) {
                                try db.run("DELETE FROM browser_pins WHERE path = ?", [.text(path)])
                            }
                            for (index, path) in next.pinned.enumerated() {
                                try db.run("""
                                    INSERT INTO browser_pins(path, pinned) VALUES(?, ?)
                                    ON CONFLICT(path) DO UPDATE SET pinned = excluded.pinned
                                    """, [.text(path), .int(Int64(index))])
                            }
                        }
                        if next.last != old.last {
                            if let path = next.last {
                                try db.run("INSERT OR REPLACE INTO browser_state(key, value) VALUES(?, ?)",
                                           [.text(Self.lastFolderKey), .text(path)])
                            } else {
                                try db.run("DELETE FROM browser_state WHERE key = ?", [.text(Self.lastFolderKey)])
                            }
                        }
                    }
                }
                failureLog.succeeded()
                lock.withLock { state = next }
                return next.pinned != old.pinned
            } catch {
                failureLog.failed(error)
                return false
            }
        }
        if favoritesChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: Self.favoritesDidChange, object: self)
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
}
