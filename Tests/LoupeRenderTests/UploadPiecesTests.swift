import CoreGraphics
import Foundation
import LoupeCore
import Metal
import QuartzCore
import Testing
@testable import LoupeRender

@Test func piecesCoverTheRangeInOrder() {
    #expect(TiledImage.pieces(of: 10, size: 4) == [0..<4, 4..<8, 8..<10])
    #expect(TiledImage.pieces(of: 3, size: 16) == [0..<3])
    #expect(TiledImage.pieces(of: 0, size: 16).isEmpty)
    #expect(TiledImage.pieces(of: 2, size: 0) == [0..<1, 1..<2])
}

/// A pyramid built one slice per command buffer is the one built in a single command buffer, byte for byte, for both
/// filters and both upload paths (the blits; the premultiplied-linear pass of an image with alpha < 1): pieces only
/// split the work, every slice still reads the finished level above it.
@Test(arguments: [PyramidFilter.box, .lanczos3], [false, true])
func pyramidInPiecesMatchesOneCommandBuffer(filter: PyramidFilter, alpha: Bool) async throws {
    let context = MetalContext.shared
    let pixels = TestImages.synthetic(1600, 1100) { x, y in
        let p = TestImages.noiseAndEdges(x, y)
        guard alpha else { return p }
        let a = UInt8(truncatingIfNeeded: 64 + (x + y) % 192)
        func premultiplied(_ c: UInt8) -> UInt8 { UInt8((Int(c) * Int(a) + 127) / 255) }
        return (premultiplied(p.b), premultiplied(p.g), premultiplied(p.r), a)
    }
    let grid = TileGrid(imageSize: pixels.pixelSize)
    #expect(grid.columns(0) * grid.rows(0) == 12 && grid.levelCount >= 3)
    let table = alpha ? try #require(context.curveTables(for: ColorCurve.of(pixels.colorSpace))?.upload()) : nil
    func build(_ pieceSlices: Int) async throws -> [MTLTexture] {
        let image = TiledImage.empty(grid: grid, colorSpace: pixels.colorSpace)
        return try await image.encodeAndRun(pixels, level: 0, filter: filter, premultipliedLinear: table,
                                            pieceSlices: pieceSlices, context: context).textures
    }
    let whole = try await build(10_000), pieces = try await build(1)
    for level in 0..<grid.levelCount {
        for slice in 0..<(grid.columns(level) * grid.rows(level)) {
            let a = try await TestImages.readSlice(whole[level], slice: slice)
            let b = try await TestImages.readSlice(pieces[level], slice: slice)
            // The first differing byte, not `a == b`: a failing array expectation would diff 1.1 MB.
            let first = a.indices.first { a[$0] != b[$0] }
            #expect(first == nil, "level \(level), slice \(slice): byte \(first ?? 0) of \(a.count)")
        }
    }
}

/// The number of `traffic`'s waiters, once `quiet` has registered one: polled with yields, as the waiter registers
/// on another task.
private func waitForWaiter(_ traffic: FrameTraffic) async {
    while traffic.waiting == 0 { await Task.yield() }
}

@Test func quietReturnsAtOnceWithoutFrames() async {
    let traffic = FrameTraffic(), start = CACurrentMediaTime()
    await traffic.quiet(wait: 10)
    #expect(CACurrentMediaTime() - start < 1)
    #expect(traffic.inFlight == 0 && traffic.waiting == 0)
}

@Test func quietWaitsForTheTrackedFrame() async throws {
    let traffic = FrameTraffic()
    let frame = try #require(MetalContext.shared.queue.makeCommandBuffer())
    traffic.track(frame)
    #expect(traffic.inFlight == 1)
    let quiet = Task { () -> Double in
        await traffic.quiet(wait: 10)
        return CACurrentMediaTime()
    }
    await waitForWaiter(traffic)
    let committed = CACurrentMediaTime()
    frame.commit()
    let returned = await quiet.value
    #expect(returned >= committed && returned - committed < 1)
    #expect(traffic.inFlight == 0 && traffic.waiting == 0)
}

/// A frame tracked and never committed holds an upload up for `wait` at most.
@Test func quietGivesUpAfterTheWait() async throws {
    let traffic = FrameTraffic()
    let frame = try #require(MetalContext.shared.queue.makeCommandBuffer())
    traffic.track(frame)
    let start = CACurrentMediaTime()
    await traffic.quiet(wait: 0.05)
    let waited = CACurrentMediaTime() - start
    #expect(waited >= 0.05 && waited < 1)
    #expect(traffic.inFlight == 1 && traffic.waiting == 0)
    frame.commit()
    frame.waitUntilCompleted()
}
