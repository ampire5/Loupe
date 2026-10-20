import Foundation
import CoreGraphics
import LoupeCore
import Metal
import Testing
@testable import LoupeRender

private typealias Px = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)
private func same(_ a: Px, _ b: Px) -> Bool { a.b == b.b && a.g == b.g && a.r == b.r && a.a == b.a }

@Test func apronMatchesNeighbour() async throws {
    let t = try await TiledImage.make(from: TestImages.synthetic(1100, 700))
    #expect(t.grid.columns(0) == 3 && t.grid.rows(0) == 2)
    let slice = try await TestImages.readSlice(t.levels[0], slice: t.grid.slice(of: TileID(level: 0, column: 1, row: 0)))
    // Left apron: texel (0, 8) is source (504, 0); texel (8, 8) is source (512, 0) (top apron rows hold nothing).
    #expect(same(TestImages.texel(slice, x: 0, y: 8), TestImages.pattern(512 - 8, 0)))
    #expect(same(TestImages.texel(slice, x: 8, y: 8), TestImages.pattern(512, 0)))
    // Right apron reaches 8 px into tile 2; bottom apron reaches 8 px into row 1.
    #expect(same(TestImages.texel(slice, x: 527, y: 8), TestImages.pattern(1023 + 8, 0)))
    #expect(same(TestImages.texel(slice, x: 8, y: 527), TestImages.pattern(512, 511 + 8)))
}

@Test func lastTileHoldsEdgePixels() async throws {
    let t = try await TiledImage.make(from: TestImages.synthetic(1100, 700))
    let slice = try await TestImages.readSlice(t.levels[0], slice: t.grid.slice(of: TileID(level: 0, column: 2, row: 1)))
    // Tile (2, 1) content starts at source (1024, 512), at texel (8, 8); (1099, 699) is texel (8 + 75, 8 + 187).
    #expect(same(TestImages.texel(slice, x: 8 + 75, y: 8 + 187), TestImages.pattern(1099, 699)))
    #expect(same(TestImages.texel(slice, x: 8, y: 8), TestImages.pattern(1024, 512)))
    #expect(same(TestImages.texel(slice, x: 0, y: 0), TestImages.pattern(1016, 504)))
}

@Test func firstTileOffsetsByApron() async throws {
    let t = try await TiledImage.make(from: TestImages.synthetic(1100, 700))
    let slice = try await TestImages.readSlice(t.levels[0], slice: 0)
    #expect(same(TestImages.texel(slice, x: 8, y: 8), TestImages.pattern(0, 0)))
    #expect(same(TestImages.texel(slice, x: 527, y: 527), TestImages.pattern(519, 519)))
}

@Test func carriesColourSpaceAndByteCount() async throws {
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let t = try await TiledImage.make(from: TestImages.synthetic(1100, 700, colorSpace: p3))
    #expect(t.colorSpace.name == p3.name)
    #expect(t.levels.count == t.grid.levelCount && t.sampleViews.count == t.levels.count)
    let expected = (0..<t.grid.levelCount).reduce(0) { $0 + t.grid.columns($1) * t.grid.rows($1) * 528 * 528 * 4 }
    #expect(t.byteCount == expected)
    for (level, view) in zip(t.levels, t.sampleViews) {
        #expect(level.pixelFormat == .bgra8Unorm && view.pixelFormat == .bgra8Unorm_srgb)
        #expect(level.textureType == .type2DArray && level.storageMode == .private)
        #expect(level.usage.isSuperset(of: [.shaderRead, .shaderWrite, .pixelFormatView]))
    }
}

@Test func emptyImageThrows() async throws {
    let empty = TestImages.synthetic(0, 0)
    await #expect(throws: DecodeError.unreadable) { try await TiledImage.make(from: empty) }
}

@Test func arrayLimits() throws {
    let grid = TileGrid(imageSize: PixelSize(width: 20000, height: 20000))
    let descriptors = try TiledImage.descriptors(for: grid)
    #expect(descriptors.count == grid.levelCount)
    #expect(descriptors[0].arrayLength == 1600)
    for d in descriptors {
        #expect(d.arrayLength <= 2048)
        #expect(d.width == 528 && d.height == 528)   // every texture side is the slot size, far below Metal's 16384 limit
        #expect(d.textureType == .type2DArray && d.pixelFormat == .bgra8Unorm && d.storageMode == .private)
    }
}

/// Metal aborts the process on an `arrayLength` above 2048, so the descriptor step must refuse such a grid
/// first (24000² needs 47 x 47 = 2209 tiles). Only the check runs: no 2 GB image is built.
@Test func tooManyTilesThrowsBeforeAllocating() {
    for size in [PixelSize(width: 24000, height: 24000), PixelSize(width: 40000, height: 14000)] {
        #expect(throws: DecodeError.tooLarge) { try TiledImage.descriptors(for: TileGrid(imageSize: size)) }
    }
}

// MARK: - Per-level residency

private let bigSize = PixelSize(width: 3000, height: 2000)

/// An empty 3000×2000 image with only level 2 (750×500, 2×1 tiles) uploaded.
private func coarseOnly() async throws -> TiledImage {
    let grid = TileGrid(imageSize: bigSize)
    let t = TiledImage.empty(grid: grid, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    #expect(t.finestResidentLevel == nil && t.byteCount == 0)
    #expect(t.residentViews().count == grid.levelCount && t.residentViews().allSatisfy { $0 == nil })
    let size = grid.levelSize(2)
    try await t.upload(LevelImage(image: TestImages.synthetic(size.width, size.height), level: 2))
    return t
}

@Test func uploadCoarseLevelOnly() async throws {
    let t = try await coarseOnly()
    let grid = t.grid
    #expect(grid.levelCount > 3)
    #expect(t.finestResidentLevel == 2)
    let views = t.residentViews()
    #expect(views[0] == nil && views[1] == nil)
    #expect(views[2...].allSatisfy { $0 != nil })
    #expect(t.byteCount == grid.byteCount(levels: 2..<grid.levelCount))
    #expect(t.revision == 1)
    // Level 2 holds the uploaded pixels, with the apron logic of a level-0 upload (tile (1, 0) starts at 512).
    let slice = try await TestImages.readSlice(views[2]!, slice: grid.slice(of: TileID(level: 2, column: 1, row: 0)))
    #expect(same(TestImages.texel(slice, x: 8, y: 8), TestImages.pattern(512, 0)))
    #expect(same(TestImages.texel(slice, x: 0, y: 8), TestImages.pattern(504, 0)))
}

@Test func fullUploadReplacesCoarse() async throws {
    let t = try await coarseOnly()
    let before = t.revision, coarse = t.residentViews()
    try await t.upload(LevelImage(image: TestImages.synthetic(bigSize.width, bigSize.height), level: 0))
    #expect(t.finestResidentLevel == 0)
    #expect(t.revision > before)
    let views = t.residentViews()
    #expect(views.allSatisfy { $0 != nil })
    #expect(views[2]! !== coarse[2]!)   // a full upload rebuilds every coarser level from level 0
    #expect(t.byteCount == t.grid.byteCount(levels: 0..<t.grid.levelCount))
}

/// A preview upload onto a fully resident image is skipped: its coarse levels stay the ones built from level 0.
@Test func previewOntoFullIsSkipped() async throws {
    let t = try await TiledImage.make(from: TestImages.synthetic(bigSize.width, bigSize.height))
    let full = t.residentViews(), before = t.revision
    let size = t.grid.levelSize(2)
    try await t.upload(LevelImage(image: TestImages.synthetic(size.width, size.height), level: 2))
    let views = t.residentViews()
    #expect(t.finestResidentLevel == 0)
    #expect(zip(views, full).allSatisfy { $0! === $1! })
    #expect(t.revision == before)
}

/// A preview upload that queued on the gate behind a full upload (both decoded meanwhile) finds level 0
/// resident once it gets the gate, and is skipped instead of replacing the coarse levels with preview pixels.
@Test func previewQueuedBehindFullIsSkipped() async throws {
    let t = TiledImage.empty(grid: TileGrid(imageSize: bigSize), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    let size = t.grid.levelSize(2)
    let preview = LevelImage(image: TestImages.synthetic(size.width, size.height), level: 2)
    let queued = QueuedUpload()
    // Called while the full upload holds the gate: the preview upload queues behind it.
    t.willPublish = { queued.start { try await t.upload(preview) } }
    try await t.upload(LevelImage(image: TestImages.synthetic(bigSize.width, bigSize.height), level: 0))
    t.willPublish = nil
    try await queued.wait()
    #expect(t.finestResidentLevel == 0)
    #expect(t.revision == 1)   // only the full upload published
}

private final class QueuedUpload: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    /// Starts `work` the first time only (a later publish calls the hook again).
    func start(_ work: @escaping @Sendable () async throws -> Void) {
        lock.withLock { if task == nil { task = Task { try await work() } } }
    }
    func wait() async throws { try await lock.withLock { task }?.value }
}

@Test func evictKeepsPreview() async throws {
    let t = try await TiledImage.make(from: TestImages.synthetic(bigSize.width, bigSize.height))
    let before = t.revision
    t.evict(finerThan: 2)
    #expect(t.finestResidentLevel == 2)
    #expect(t.revision > before)
    let views = t.residentViews()
    #expect(views[0] == nil && views[1] == nil && views[2...].allSatisfy { $0 != nil })
    #expect(t.byteCount == t.grid.byteCount(levels: 2..<t.grid.levelCount))
}

@Test func levelSwapKeepsOldTexturesAlive() async throws {
    let t = try await TiledImage.make(from: TestImages.synthetic(1100, 700))
    let old = t.residentViews()
    let colour: Px = (1, 2, 3, 255)
    t.evict(finerThan: 1)   // a level-0 upload onto a resident level 0 would be skipped
    try await t.upload(LevelImage(image: TestImages.synthetic(1100, 700) { _, _ in colour }, level: 0))
    // The copy still reads the old pixels: the new upload went to fresh textures, not over these.
    let oldSlice = try await TestImages.readSlice(old[0]!, slice: 0)
    #expect(same(TestImages.texel(oldSlice, x: 8 + 100, y: 8 + 50), TestImages.pattern(100, 50)))
    let newSlice = try await TestImages.readSlice(t.residentViews()[0]!, slice: 0)
    #expect(same(TestImages.texel(newSlice, x: 8 + 100, y: 8 + 50), colour))
}

@Test func uploadRejectsWrongSizeOrLevel() async throws {
    let t = TiledImage.empty(grid: TileGrid(imageSize: bigSize), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    await #expect(throws: DecodeError.unreadable) {
        try await t.upload(LevelImage(image: TestImages.synthetic(700, 500), level: 2))
    }
    await #expect(throws: DecodeError.unreadable) {
        try await t.upload(LevelImage(image: TestImages.synthetic(1, 1), level: t.grid.levelCount))
    }
    #expect(t.finestResidentLevel == nil && t.revision == 0)
}

@Test func concurrentUploadsLeaveAConsistentSuffix() async throws {
    let t = TiledImage.empty(grid: TileGrid(imageSize: bigSize), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    let full = TestImages.synthetic(bigSize.width, bigSize.height)
    let size = t.grid.levelSize(2)
    let preview = TestImages.synthetic(size.width, size.height)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for k in 0..<6 {
            group.addTask { try await t.upload(LevelImage(image: k % 2 == 0 ? full : preview, level: k % 2 == 0 ? 0 : 2)) }
        }
        try await group.waitForAll()
    }
    #expect((1...6).contains(t.revision))   // a preview that finds level 0 resident is skipped
    #expect(t.finestResidentLevel == 0)
    #expect(t.residentViews().allSatisfy { $0 != nil })
    #expect(t.byteCount == t.grid.byteCount(levels: 0..<t.grid.levelCount))
}

@Test func evictDuringUploadIsNotUndone() async throws {
    let t = TiledImage.empty(grid: TileGrid(imageSize: bigSize), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    // The eviction lands after the GPU finished the level-0 upload but before it is published.
    t.willPublish = { t.evict(finerThan: 2) }
    try await t.upload(LevelImage(image: TestImages.synthetic(bigSize.width, bigSize.height), level: 0))
    #expect(t.finestResidentLevel == 2)
    #expect(t.byteCount == t.grid.byteCount(levels: 2..<t.grid.levelCount))
    #expect(t.revision == 1)   // the evict dropped nothing yet; the upload published 2...last
    // The guard lasts one upload only: the next full upload is published whole.
    t.willPublish = nil
    try await t.upload(LevelImage(image: TestImages.synthetic(bigSize.width, bigSize.height), level: 0))
    #expect(t.finestResidentLevel == 0)
}

@Test func evictOfNothingKeepsRevision() async throws {
    let t = try await coarseOnly()
    let before = t.revision
    t.evict(finerThan: 2)
    #expect(t.revision == before)
    t.evict(finerThan: 3)
    #expect(t.revision == before + 1 && t.finestResidentLevel == 3)
}
