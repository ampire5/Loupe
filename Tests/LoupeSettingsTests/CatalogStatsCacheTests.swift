import Foundation
import os
import Testing
import LoupeCore
@testable import LoupeSettings

/// Settings › Performance › Catalog: the card shows the last count at once and counts again only when something
/// changed (a clear, or the catalog's files on disk).
@MainActor
struct CatalogStatsCacheTests {
    /// How many times the cache read the catalog, and the stamp the catalog's files have now.
    private final class Probe: Sendable {
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let stamp = OSAllocatedUnfairLock(initialState: 1)
    }

    private func makeCache(_ probe: Probe) -> CatalogStatsCache {
        CatalogStatsCache(
            read: { _ in
                probe.loads.withLock { $0 += 1 }
                return CatalogStatsCache.Snapshot(stats: nil, names: [:])
            },
            stamp: { _ in CatalogStatsCache.Stamp(files: [.init(size: probe.stamp.withLock { $0 }, modified: nil)]) })
    }

    @Test func secondAppearShowsTheValueAtOnceWithoutCounting() async {
        let probe = Probe()
        let cache = makeCache(probe)
        let dir = URL(fileURLWithPath: "/nonexistent-catalog")
        #expect(cache.snapshot == nil)
        await cache.refresh(directory: dir)
        #expect(probe.loads.withLock { $0 } == 1)
        // The second appear: the value is there before any work.
        #expect(cache.snapshot != nil)
        await cache.refresh(directory: dir)
        #expect(probe.loads.withLock { $0 } == 1)
    }

    @Test func invalidateCountsAgain() async {
        let probe = Probe()
        let cache = makeCache(probe)
        let dir = URL(fileURLWithPath: "/nonexistent-catalog")
        await cache.refresh(directory: dir)
        cache.invalidate()
        #expect(cache.snapshot != nil, "the old value stays on screen while counting again")
        await cache.refresh(directory: dir)
        #expect(probe.loads.withLock { $0 } == 2)
    }

    @Test func changedCatalogFilesCountAgain() async {
        let probe = Probe()
        let cache = makeCache(probe)
        let dir = URL(fileURLWithPath: "/nonexistent-catalog")
        await cache.refresh(directory: dir)
        probe.stamp.withLock { $0 = 2 }
        await cache.refresh(directory: dir)
        #expect(probe.loads.withLock { $0 } == 2)
    }

    @Test func concurrentAppearsCountOnce() async {
        let probe = Probe()
        let cache = makeCache(probe)
        let dir = URL(fileURLWithPath: "/nonexistent-catalog")
        async let a: Void = cache.refresh(directory: dir)
        async let b: Void = cache.refresh(directory: dir)
        _ = await (a, b)
        #expect(probe.loads.withLock { $0 } == 1)
    }

    @Test func fileStampFollowsTheCatalogFiles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("loupe-stamp-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let before = CatalogStatsCache.fileStamp(directory: dir)
        try Data(count: 10).write(to: dir.appendingPathComponent("Catalog.db-wal"))
        let after = CatalogStatsCache.fileStamp(directory: dir)
        #expect(before != after)
        #expect(after == CatalogStatsCache.fileStamp(directory: dir))
    }
}
