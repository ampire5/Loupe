import CoreGraphics
import LoupeCore
import Metal
import Testing
@testable import LoupeRender

private typealias Px = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

private func toLinear(_ v: UInt8) -> Double {
    let c = Double(v) / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

private func toSRGB(_ l: Double) -> Double {
    255 * (l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055)
}

/// Deterministic pseudo-random channel values, so a wrong source pixel or tap changes the result.
private func scrambled(_ x: Int, _ y: Int) -> Px {
    func h(_ n: Int) -> UInt8 { UInt8(truncatingIfNeeded: (n &* 2654435761) >> 13) }
    return (h(x &* 31 &+ y &* 17 &+ 1), h(x &* 7 &+ y &* 57 &+ 2), h(x &* 91 &+ y &* 3 &+ 3), 255)
}

@Test func averagesInLinearLight() async throws {
    // A pixel checker of sRGB 0 and 255: every 2x2 block is half white, so linear 0.5 = sRGB 188, not 128.
    let image = TestImages.synthetic(600, 600) { x, y in
        let v: UInt8 = (x + y) % 2 == 0 ? 255 : 0
        return (v, v, v, 255)
    }
    let t = try await TiledImage.make(from: image)
    #expect(t.grid.levelCount == 2)
    let slice = try await TestImages.readSlice(t.levels[1], slice: 0, level: 0)
    for (x, y) in [(0, 0), (1, 0), (100, 77), (299, 299)] {
        let p = TestImages.texel(slice, x: x + 8, y: y + 8)
        for channel in [p.b, p.g, p.r] { #expect(abs(Int(channel) - 188) <= 1) }
        #expect(p.a == 255)
    }
}

@Test func oddSizeEdge() async throws {
    // 1025x3, only column 1024 white: level 1 is 513x2 in two tile columns; the odd last column
    // averages its single source pixel with itself (clamped pair) rather than with black.
    let image = TestImages.synthetic(1025, 3) { x, _ in
        let v: UInt8 = x == 1024 ? 255 : 0
        return (v, v, v, 255)
    }
    let t = try await TiledImage.make(from: image)
    #expect(t.grid.levelSize(1) == PixelSize(width: 513, height: 2))
    #expect(t.grid.columns(1) == 2 && t.grid.rows(1) == 1)
    let left = try await TestImages.readSlice(t.levels[1], slice: 0)
    let right = try await TestImages.readSlice(t.levels[1], slice: 1)
    for y in 0..<2 {
        let edge = TestImages.texel(right, x: 8, y: 8 + y)   // level pixel (512, y)
        #expect(edge.b == 255 && edge.g == 255 && edge.r == 255 && edge.a == 255)
        let inner = TestImages.texel(left, x: 511 + 8, y: 8 + y)   // level pixel (511, y)
        #expect(inner.b == 0 && inner.g == 0 && inner.r == 0 && inner.a == 255)
    }
}

/// Every apron texel next to a level-1 tile boundary must equal the neighbour's content texel it mirrors.
private func expectAprons(width: Int, height: Int, horizontal: Bool, filter: PyramidFilter = .box) async throws {
    let t = try await TiledImage.make(from: TestImages.synthetic(width, height, pixel: scrambled), filter: filter)
    let grid = t.grid
    let tiles = horizontal ? grid.columns(1) : grid.rows(1)
    #expect(tiles >= 2)
    func slice(_ i: Int) async throws -> [UInt8] {
        let tile = horizontal ? TileID(level: 1, column: i, row: 0) : TileID(level: 1, column: 0, row: i)
        return try await TestImages.readSlice(t.levels[1], slice: grid.slice(of: tile))
    }
    let a = try await slice(0), b = try await slice(1)
    let extent = horizontal ? grid.contentRect(TileID(level: 1, column: 0, row: 0)).height
                            : grid.contentRect(TileID(level: 1, column: 0, row: 0)).width
    var different = 0
    for along in 0..<extent {
        for k in 0..<TileGrid.apron {
            // a's far apron (slot 520+k) mirrors b's first content texels (8+k); b's near apron (k) mirrors a's last (512+k).
            let (aApron, bContent, bApron, aContent) = horizontal
                ? (TestImages.texel(a, x: 520 + k, y: 8 + along), TestImages.texel(b, x: 8 + k, y: 8 + along),
                   TestImages.texel(b, x: k, y: 8 + along), TestImages.texel(a, x: 512 + k, y: 8 + along))
                : (TestImages.texel(a, x: 8 + along, y: 520 + k), TestImages.texel(b, x: 8 + along, y: 8 + k),
                   TestImages.texel(b, x: 8 + along, y: k), TestImages.texel(a, x: 8 + along, y: 512 + k))
            #expect(aApron == bContent)
            #expect(bApron == aContent)
            if aApron != (0, 0, 0, 0) { different += 1 }
        }
    }
    #expect(different > extent)   // the aprons really hold data, not just matching zeros
}

@Test func edgeColumnsMatch() async throws {
    try await expectAprons(width: 2200, height: 300, horizontal: true)
}

@Test func edgeRowsMatch() async throws {
    try await expectAprons(width: 300, height: 2200, horizontal: false)
}

@Test func coarsestLevelSmall() async throws {
    let t = try await TiledImage.make(from: TestImages.synthetic(1100, 700, pixel: scrambled))
    #expect(t.grid.levelCount == 3)
    #expect(t.grid.levelSize(2) == PixelSize(width: 275, height: 175))
    #expect(t.grid.columns(2) == 1 && t.grid.rows(2) == 1)
    #expect(t.levels.count == 3 && t.levels[2].arrayLength == 1)
    let slice = try await TestImages.readSlice(t.levels[2], slice: 0)
    // Tolerance +-1: level 1 is stored as 8-bit sRGB before level 2 averages it, so the GPU result carries
    // two rounding stages (level 1 and level 2) against the exact one-step reference computed here.
    // Each level-2 texel is the average of its 4x4 level-0 block, in linear light (alpha as-is).
    for (x, y) in [(0, 0), (1, 0), (137, 90), (274, 0), (0, 174), (274, 174)] {
        var sum = [0.0, 0.0, 0.0]
        for dy in 0..<4 {
            for dx in 0..<4 {
                let p = scrambled(x * 4 + dx, y * 4 + dy)
                sum[0] += toLinear(p.b); sum[1] += toLinear(p.g); sum[2] += toLinear(p.r)
            }
        }
        let got = TestImages.texel(slice, x: x + 8, y: y + 8)
        for (channel, linearSum) in zip([got.b, got.g, got.r], sum) {
            let expected = toSRGB(linearSum / 16)
            #expect(abs(Double(channel) - expected) <= 1.0, "level 2 texel (\(x), \(y)): got \(channel), expected \(expected)")
        }
        #expect(got.a == 255)
    }
}

// MARK: pyramid-filter

/// FNV-1a over every slot texel of levels 1... (level 0's aprons past the image edge are never written, so it is left
/// out; the coarser levels are written in full, aprons included).
private func pyramidHash(_ t: TiledImage) async throws -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for level in 1..<t.grid.levelCount {
        for slice in 0..<t.levels[level].arrayLength {
            for b in try await TestImages.readSlice(t.levels[level], slice: slice) { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        }
    }
    return h
}

@Test func boxUnchanged() async throws {
    // The hash of levels 1-2 of this image as downsample2x built them before pyramid-filter existed (M4 Max,
    // 2026-10-15): the box path must stay byte-identical, by default and when asked for by name.
    let image = TestImages.synthetic(1300, 900, pixel: TestImages.noiseAndEdges)
    let byDefault = try await TiledImage.make(from: image)
    let named = try await TiledImage.make(from: image, filter: .box)
    #expect(byDefault.grid.levelCount == 3)
    #expect(try await pyramidHash(byDefault) == 0x52f1_e3c9_4fd2_8ceb)
    #expect(try await pyramidHash(named) == 0x52f1_e3c9_4fd2_8ceb)
}

@Test func lanczosLevelMatchesReference() async throws {
    // Level 1 (650 x 450, two tile columns) against a CPU double Lanczos-3 2x decimation of level 0 in linear light:
    // exactly a resample at m = 0.5 with the image at view (0, 0), 12 taps per axis, edges clamped.
    let (width, height) = (1300, 900)
    let t = try await TiledImage.make(from: TestImages.synthetic(width, height, pixel: TestImages.noiseAndEdges),
                                      filter: .lanczos3)
    let size = t.grid.levelSize(1)
    #expect(size == PixelSize(width: 650, height: 450) && t.grid.columns(1) == 2)
    let level = try await TestImages.readLevel(t.levels[1], grid: t.grid, level: 1)
    let base = level.buffer.bytes.assumingMemoryBound(to: UInt8.self)
    var got = [UInt8](repeating: 0, count: size.width * size.height * 4)
    for y in 0..<size.height {
        for x in 0..<size.width * 4 { got[y * size.width * 4 + x] = base[y * level.bytesPerRow + x] }
    }
    let expected = ResampleReference.render(
        source: { x, y in
            let p = TestImages.noiseAndEdges(x, y)
            return (ResampleReference.linear(p.r), ResampleReference.linear(p.g), ResampleReference.linear(p.b))
        },
        width: width, height: height, kernel: .lanczos3, m: 0.5, offset: .zero,
        extent: SIMD2(Double(width), Double(height)), viewWidth: size.width, viewHeight: size.height, background: (0, 0, 0))
    let all = ResampleReference.psnr(got, expected, width: size.width)
    let seam = ResampleReference.psnr(got, expected, width: size.width) { x, _ in abs(Double(x) - 512) <= 16 }
    print("PSNR pyramid lanczos3 level 1: \(all) dB, seam \(seam) dB")
    #expect(all >= 55, "level 1: \(all) dB")
    #expect(seam >= 55, "seam: \(seam) dB")
    #expect(stride(from: 3, to: got.count, by: 4).allSatisfy { got[$0] == 255 })
    // Not the box result: the filter really changed.
    let box = try await TiledImage.make(from: TestImages.synthetic(width, height, pixel: TestImages.noiseAndEdges))
    #expect(try await pyramidHash(box) != pyramidHash(t))
    // The aprons hold the neighbour tiles' pixels, as for box.
    try await expectAprons(width: width, height: height, horizontal: true, filter: .lanczos3)
    try await expectAprons(width: 300, height: 2200, horizontal: false, filter: .lanczos3)
}
