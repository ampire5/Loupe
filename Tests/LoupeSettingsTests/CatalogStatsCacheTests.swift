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

    /// A cache whose reads fail (the catalog is there but busy) while `failing` is set.
    private func makeFlakyCache(_ probe: Probe, failing: OSAllocatedUnfairLock<Bool>) -> CatalogStatsCache {
        CatalogStatsCache(
            read: { _ in
                let n = probe.loads.withLock { $0 += 1; return $0 }
                if failing.withLock({ $0 }) { return nil }
                return CatalogStatsCache.Snapshot(stats: nil, names: ["read": "\(n)"])
            },
            stamp: { _ in CatalogStatsCache.Stamp(files: [.init(size: probe.stamp.withLock { $0 }, modified: nil)]) })
    }

    @Test func failedReadIsNotCachedAndCountsAgain() async {
        let probe = Probe()
        let failing = OSAllocatedUnfairLock(initialState: true)
        let cache = makeFlakyCache(probe, failing: failing)
        let dir = URL(fileURLWithPath: "/nonexistent-catalog")
        await cache.refresh(directory: dir)
        #expect(cache.snapshot == nil, "a failed read is not «no catalog»")
        failing.withLock { $0 = false }
        // Same files on disk: the failed read must not have recorded the stamp.
        await cache.refresh(directory: dir)
        #expect(probe.loads.withLock { $0 } == 2)
        #expect(cache.snapshot?.names == ["read": "2"])
    }

    @Test func failedReadKeepsThePreviousSnapshot() async {
        let probe = Probe()
        let failing = OSAllocatedUnfairLock(initialState: false)
        let cache = makeFlakyCache(probe, failing: failing)
        let dir = URL(fileURLWithPath: "/nonexistent-catalog")
        await cache.refresh(directory: dir)
        #expect(cache.snapshot?.names == ["read": "1"])
        probe.stamp.withLock { $0 = 2 }
        failing.withLock { $0 = true }
        await cache.refresh(directory: dir)
        #expect(probe.loads.withLock { $0 } == 2)
        #expect(cache.snapshot?.names == ["read": "1"], "the previous count stays shown")
        failing.withLock { $0 = false }
        await cache.refresh(directory: dir)
        #expect(probe.loads.withLock { $0 } == 3)
        #expect(cache.snapshot?.names == ["read": "3"])
    }

    @Test func readSnapshotFailsOnlyWhenTheCatalogIsThere() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("loupe-snap-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // No Catalog.db: a real «no catalog».
        #expect(CatalogStatsCache.readSnapshot(directory: dir) == CatalogStatsCache.Snapshot(stats: nil, names: [:]))
        #expect(CatalogStatsCache.readSnapshot(directory: nil) == CatalogStatsCache.Snapshot(stats: nil, names: [:]))
        // A Catalog.db that cannot be read: a failed read, not «no catalog».
        try Data("not a database".utf8).write(to: dir.appendingPathComponent("Catalog.db"))
        #expect(CatalogStatsCache.readSnapshot(directory: dir) == nil)
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
