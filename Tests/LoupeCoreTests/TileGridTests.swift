import Testing
import Foundation
@testable import LoupeCore

@Test func levelsFor147MP() {
    let g = TileGrid(imageSize: PixelSize(width: 10502, height: 14000))
    #expect(g.levelCount == 6)                                         // 14000 → 7000 → 3500 → 1750 → 875 → 438
    #expect(g.levelSize(1) == PixelSize(width: 5251, height: 7000))
    #expect(g.columns(0) == 21 && g.rows(0) == 28)
}
@Test func oddLevelSizes() {           // Review Focus
    let g = TileGrid(imageSize: PixelSize(width: 13468, height: 10100))
    #expect(g.levelSize(3) == PixelSize(width: 1684, height: 1263))     // ceil(13468/8), ceil(10100/8)
    let last = TileID(level: 0, column: g.columns(0) - 1, row: g.rows(0) - 1)
    #expect(g.contentRect(last) == PixelRect(x: 26 * 512, y: 19 * 512, width: 13468 - 26 * 512, height: 10100 - 19 * 512))
    #expect(g.slotRect(last) == PixelRect(x: 26 * 512 - 8, y: 19 * 512 - 8, width: 13468 - 26 * 512 + 8, height: 10100 - 19 * 512 + 8))
}
@Test func firstSlotClippedAtOrigin() {
    let g = TileGrid(imageSize: PixelSize(width: 2000, height: 2000))
    #expect(g.slotRect(TileID(level: 0, column: 0, row: 0)) == PixelRect(x: 0, y: 0, width: 520, height: 520))
    #expect(g.slotOrigin(TileID(level: 0, column: 0, row: 0)) == PixelPoint(x: -8, y: -8))
}
@Test func onePixelImage() {
    let g = TileGrid(imageSize: PixelSize(width: 1, height: 1))
    #expect(g.levelCount == 1 && g.columns(0) == 1 && g.rows(0) == 1)
}
@Test func huge20k() {                  // Review Focus
    let g = TileGrid(imageSize: PixelSize(width: 20000, height: 20000))
    #expect(g.columns(0) * g.rows(0) == 40 * 40 && g.columns(0) * g.rows(0) <= 2048)
}
@Test func visibleTiles() {
    let g = TileGrid(imageSize: PixelSize(width: 10502, height: 14000))
    let t = g.tiles(level: 0, intersecting: CGRect(x: 500, y: 600, width: 600, height: 30))
    #expect(t == [TileID(level: 0, column: 0, row: 1), TileID(level: 0, column: 1, row: 1), TileID(level: 0, column: 2, row: 1)])
}
@Test func levelChoice() {
    #expect(TileGrid.level(forScale: 1, levelCount: 6) == 0)
    #expect(TileGrid.level(forScale: 4, levelCount: 6) == 0)
    #expect(TileGrid.level(forScale: 0.3, levelCount: 6) == 1)          // level ½ is the nearest larger
    #expect(TileGrid.level(forScale: 0.25, levelCount: 6) == 2)
    #expect(TileGrid.level(forScale: 0.001, levelCount: 6) == 5)
}

// MARK: - Edge cases

@Test func tileBoundaryIsHalfOpen() {
    let g = TileGrid(imageSize: PixelSize(width: 2000, height: 2000))
    // x 0..<512 and y 0..<512 is exactly tile (0,0); the edge at 512 must not pull in the next tile.
    #expect(g.tiles(level: 0, intersecting: CGRect(x: 0, y: 0, width: 512, height: 512)) == [TileID(level: 0, column: 0, row: 0)])
    // A rect starting exactly on a boundary excludes the previous tile.
    #expect(g.tiles(level: 0, intersecting: CGRect(x: 512, y: 512, width: 10, height: 10)) == [TileID(level: 0, column: 1, row: 1)])
    // One pixel beyond does include the next one.
    #expect(g.tiles(level: 0, intersecting: CGRect(x: 0, y: 0, width: 513, height: 512)).count == 2)
}
@Test func tilesAreRowMajorAndClipped() {
    let g = TileGrid(imageSize: PixelSize(width: 1100, height: 1100))   // 3 x 3 tiles
    let t = g.tiles(level: 0, intersecting: CGRect(x: -500, y: -500, width: 5000, height: 5000))
    #expect(t.count == 9)
    #expect(t.first == TileID(level: 0, column: 0, row: 0) && t.last == TileID(level: 0, column: 2, row: 2))
    #expect(t[1] == TileID(level: 0, column: 1, row: 0))
    #expect(g.tiles(level: 0, intersecting: CGRect(x: 2000, y: 0, width: 10, height: 10)) == [])
    #expect(g.tiles(level: 0, intersecting: CGRect(x: 10, y: 10, width: 0, height: 0)) == [])
    #expect(g.tiles(level: 0, intersecting: .null) == [])
    #expect(g.tiles(level: 0, intersecting: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)) == [])
}
@Test func sliceIndexAndHigherLevels() {
    let g = TileGrid(imageSize: PixelSize(width: 10502, height: 14000))
    #expect(g.slice(of: TileID(level: 0, column: 3, row: 2)) == 2 * 21 + 3)
    #expect(g.columns(2) == 6 && g.rows(2) == 7)                         // 2626 x 3500
    #expect(g.slotOrigin(TileID(level: 0, column: 2, row: 1)) == PixelPoint(x: 2 * 512 - 8, y: 512 - 8))
    let last = TileID(level: 5, column: 0, row: 0)
    #expect(g.contentRect(last) == PixelRect(x: 0, y: 0, width: 329, height: 438))
}
@Test func degenerateImageDoesNotCrash() {
    for size in [PixelSize(width: 0, height: 0), PixelSize(width: 0, height: 700), PixelSize(width: 900, height: 0)] {
        let g = TileGrid(imageSize: size)
        #expect(g.levelCount >= 1)
        #expect(g.columns(0) >= 0 && g.rows(0) >= 0)
        #expect(g.tiles(level: 0, intersecting: CGRect(x: 0, y: 0, width: 5000, height: 5000)).isEmpty)
    }
    let empty = TileGrid(imageSize: PixelSize(width: 0, height: 0))
    #expect(empty.levelCount == 1 && empty.columns(0) == 0 && empty.rows(0) == 0)
}
@Test func levelChoiceDegenerateScales() {
    for s in [0.0, -1, -Double.infinity, Double.nan, Double.infinity, 1e-300, 1e300] {
        let l = TileGrid.level(forScale: s, levelCount: 6)
        #expect((0..<6).contains(l))
    }
    #expect(TileGrid.level(forScale: 0, levelCount: 6) == 5)             // infinitely far out: coarsest
    #expect(TileGrid.level(forScale: .infinity, levelCount: 6) == 0)
    #expect(TileGrid.level(forScale: 0.5, levelCount: 0) == 0)
}

@Test func textureArrayLimit() {
    // 20000² is 40 x 40 = 1600 tiles; 24000² is 47 x 47 = 2209; 40000 x 14000 is 79 x 28 = 2212; a 100000 x 5000
    // panorama (196 x 10 = 1960) still fits although it is far wider than any square image that does.
    let fits = [(20000, 20000), (23000, 23000), (100_000, 5000), (512, 512), (0, 0)]
    let tooBig = [(24000, 24000), (40000, 14000)]
    for (w, h) in fits { #expect(TileGrid.fitsTextureArrays(PixelSize(width: w, height: h)), "\(w)x\(h)") }
    for (w, h) in tooBig { #expect(!TileGrid.fitsTextureArrays(PixelSize(width: w, height: h)), "\(w)x\(h)") }
    #expect(TileGrid(imageSize: PixelSize(width: 20000, height: 20000)).maxTilesInLevel == 1600)
    #expect(TileGrid(imageSize: PixelSize(width: 24000, height: 24000)).maxTilesInLevel == 2209)
}

// MARK: Cache sizes

@Test func previewLevel6K() {
    let screen = PixelSize(width: 6144, height: 3456)
    #expect(TileGrid(imageSize: PixelSize(width: 10502, height: 14000)).previewLevel(forScreen: screen) == 2)
    #expect(TileGrid(imageSize: PixelSize(width: 3840, height: 2161)).previewLevel(forScreen: screen) == 0)
    // Degenerate sizes mean no preview level to speak of: level 0.
    #expect(TileGrid(imageSize: PixelSize(width: 0, height: 0)).previewLevel(forScreen: screen) == 0)
    #expect(TileGrid(imageSize: PixelSize(width: 10502, height: 14000)).previewLevel(forScreen: PixelSize(width: 0, height: 0)) == 0)
}
@Test func byteCountCountsSlotsPerTile() {
    let g = TileGrid(imageSize: PixelSize(width: 10502, height: 14000))
    let slot = 528 * 528 * 4
    #expect(g.byteCount(levels: 2..<3) == 6 * 7 * slot)
    #expect(g.byteCount(levels: 2..<6) == (6 * 7 + 3 * 4 + 2 * 2 + 1) * slot)
    #expect(g.byteCount(levels: 0..<0) == 0)
    #expect(g.byteCount(levels: 4..<99) == g.byteCount(levels: 4..<6))   // clamped to the levels that exist
}

/// Lfit is the fit of the picture as shown. A stored-landscape EXIF 6 photo on a portrait screen fits by its oriented
/// (portrait) size, which needs level 0 at Fit: the stored fit would say level 1, too coarse for the Fit it shows.
@Test func lfitFollowsOrientationOnAPortraitScreen() {
    let portrait = PixelSize(width: 2160, height: 3840)
    let grid = TileGrid(imageSize: PixelSize(width: 6000, height: 4000))
    #expect(grid.previewLevel(forScreen: portrait) == 1)
    let lfit = grid.previewLevel(forScreen: portrait, orientation: .right)
    let fit = ViewTransform(imageSize: CGSize(width: 4000, height: 6000), viewSize: CGSize(width: 2160, height: 3840))
    let needed = TileGrid.level(forScale: fit.scale, levelCount: grid.levelCount)
    #expect(needed == 0 && lfit <= needed)
    #expect(grid.previewLevel(forScreen: portrait, orientation: .left) == 0)
    #expect(grid.previewLevel(forScreen: portrait, orientation: .down) == 1)   // no swap, the stored fit
}

/// The iPhone case: stored 4032x3024 with EXIF 6 on a 3024x1964 screen is shown 3024x4032, which fits at 0.49, so
/// level 1 is as sharp as Fit (the stored fit, 0.65, would keep level 0: four times the memory).
@Test func lfitOfAnUprightIPhonePhotoIsCoarser() {
    let grid = TileGrid(imageSize: PixelSize(width: 4032, height: 3024))
    let screen = PixelSize(width: 3024, height: 1964)
    #expect(grid.previewLevel(forScreen: screen) == 0)
    #expect(grid.previewLevel(forScreen: screen, orientation: .right) == 1)
}
