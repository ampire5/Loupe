import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

// The ImageCache test rig over the fakes (CacheFakes.swift), shared by ImageCacheTests and ImageCacheSessionsTests.
// Waiting polls the cache's own state up to a deadline; nothing relies on a sleep being long enough.

/// 2000×1500 on a 1000×750 screen: Lfit = 1, coarse = 2, three levels, so a level-0 upload means full resolution.
let rigScreen = PixelSize(width: 1000, height: 750)
let rigPhoto = PixelSize(width: 2000, height: 1500)

struct Rig {
    let cache: ImageCache<FakeLoader>
    let reader = FakeReader()
    let decoder: FakeDecoder
    let loader = FakeLoader()

    /// `queueReader`: reads go through it instead of `reader` (which then sees none).
    init(size: PixelSize = rigPhoto, limits: CacheLimits = CacheLimits(), pool: DecodePool = DecodePool(),
         queueReader: QueueReader? = nil, pressureRestoreAfter: Duration = .seconds(30)) {
        let decoder = FakeDecoder(size: size)
        self.decoder = decoder
        cache = ImageCache(loader: loader, reader: queueReader ?? reader, pool: pool,
                           decoder: { _ in decoder }, limits: limits, pressureRestoreAfter: pressureRestoreAfter)
    }

    func focus(_ files: [URL], _ current: Int, direction: Int = 1, dwelling: Bool = false, needsFull: Bool = false,
               screen: PixelSize = rigScreen, previous: Int? = nil, scrubbing: Bool = false) async {
        await cache.setFocus(files: files, focus: CacheFocus(count: files.count, current: current, direction: direction,
                                                            dwelling: dwelling, needsFull: needsFull, screen: screen,
                                                            previous: previous, scrubbing: scrubbing))
    }

    func state(_ url: URL) async -> CacheGoal? { await cache.entry(url)?.state }
    func finest(_ url: URL) async -> Int? { (await cache.entry(url)?.pyramid)?.finest }

    /// Gives file i the width 2000 + i (Lfit 1, three levels as before), so the loader's uploads can be told apart.
    func distinctWidths(_ files: [URL]) {
        for (i, url) in files.enumerated() { decoder.setSize(url, PixelSize(width: width(i), height: 1500)) }
    }
    func width(_ i: Int) -> Int { 2000 + i }

    func settle() async -> Bool { await eventually { await cache.isIdle } }

    func setMemory(_ bytes: Int) async {
        var limits = await cache.limits
        limits.memory = bytes
        await cache.setLimits(limits)
    }

    /// Resident pyramid bytes of `files`' entries (what `usedBytes` counts besides the few bytes of fake file data).
    func pyramidBytes(_ files: [URL]) async -> Int {
        var total = 0
        for url in files {
            guard let e = await cache.entry(url), let info = e.info, let finest = e.pyramid?.finest else { continue }
            let grid = TileGrid(imageSize: info.pixelSize)
            total += grid.byteCount(levels: finest..<grid.levelCount)
        }
        return total
    }

    func clear() async {
        await cache.setFocus(files: [], focus: CacheFocus(count: 0, current: 0, direction: 1, dwelling: false,
                                                          needsFull: false, screen: rigScreen))
    }
}

/// Polls `condition` until it holds (up to 10 s).
func eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while !(await condition()) {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

func atLeast(_ goal: CacheGoal, _ state: CacheGoal?) -> Bool { state.map { $0 >= goal } ?? false }
