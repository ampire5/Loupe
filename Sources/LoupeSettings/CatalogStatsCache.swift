import Foundation
import LoupeCore
import Observation

/// The Catalog card's last count (Settings › Performance), kept by `SettingsPanel` so it outlives page switches and
/// the window's hiding: the card shows it at once and counts again, at `.utility` off the main thread, only when
/// something changed — a clear (`invalidate`) or the catalog's files on disk (their size or date).
@MainActor @Observable final class CatalogStatsCache {
    struct Snapshot: Equatable, Sendable {
        /// Nil: no catalog (thumbnails only in memory).
        var stats: CatalogStats?
        /// Mounted local volumes by UUID (`CatalogStats.mountedLocalNames`).
        var names: [String: String]
    }

    /// The size and date of the catalog's files, to tell whether they changed since the last count.
    struct Stamp: Equatable, Sendable {
        struct File: Equatable, Sendable {
            var size: Int
            var modified: Date?
        }

        var files: [File]
    }

    /// The last count; nil until the first one finished.
    private(set) var snapshot: Snapshot?

    @ObservationIgnored private let read: @Sendable (URL?) -> Snapshot
    @ObservationIgnored private let stamp: @Sendable (URL?) -> Stamp
    /// Bumped by `invalidate`.
    @ObservationIgnored private var generation = 0
    /// What the last count was made from.
    @ObservationIgnored private var counted: (directory: URL?, generation: Int, stamp: Stamp)?
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    init(read: @escaping @Sendable (URL?) -> Snapshot = CatalogStatsCache.readSnapshot,
         stamp: @escaping @Sendable (URL?) -> Stamp = CatalogStatsCache.fileStamp) {
        self.read = read
        self.stamp = stamp
    }

    /// The next `refresh` counts again (after «Clear Thumbnails…»). The old value stays shown meanwhile.
    func invalidate() {
        generation += 1
    }

    /// Counts again if the catalog changed since the last count; returns once `snapshot` is current. Appears that
    /// come while a count runs wait for it instead of starting another. The count goes on if the caller is
    /// cancelled (the card went away), so the next appear has it.
    func refresh(directory: URL?) async {
        while let running = inFlight { await running.value }
        // The task clears `inFlight` itself, before it completes: a waiter that wakes before this caller would
        // otherwise loop on the finished task without ever yielding the main actor.
        let task = Task {
            await self.count(directory: directory)
            self.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    private func count(directory: URL?) async {
        let generation = generation
        let previous = counted.flatMap { $0.directory == directory && $0.generation == generation ? $0.stamp : nil }
        let read = read, stamp = stamp
        let result = await Task.detached(priority: .utility) { () -> (Stamp, Snapshot?) in
            // Stamped before reading: a change during the read shows up as a new stamp next time.
            let now = stamp(directory)
            return (now, now == previous ? nil : read(directory))
        }.value
        counted = (directory, generation, result.0)
        if let fresh = result.1, fresh != snapshot { snapshot = fresh }
    }

    /// The real count: the catalog's tables, and the local volumes' names only when a `uuid:` volume needs them.
    nonisolated static func readSnapshot(directory: URL?) -> Snapshot {
        let stats = directory.flatMap(CatalogStats.read)
        let names = stats.map(CatalogStats.needsLocalNames) == true ? CatalogStats.mountedLocalNames() : [:]
        return Snapshot(stats: stats, names: names)
    }

    /// The size and date of `Catalog.db`, `Thumbs.db` and their `-wal`s: one local stat each.
    nonisolated static func fileStamp(directory: URL?) -> Stamp {
        guard let directory else { return Stamp(files: []) }
        let fm = FileManager.default
        let files = ["Catalog.db", "Catalog.db-wal", "Thumbs.db", "Thumbs.db-wal"].map { name in
            let attributes = try? fm.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return Stamp.File(size: (attributes?[.size] as? Int) ?? -1, modified: attributes?[.modificationDate] as? Date)
        }
        return Stamp(files: files)
    }
}
