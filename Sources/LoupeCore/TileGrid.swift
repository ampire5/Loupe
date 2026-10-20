import Foundation

/// Identifies one tile of the pyramid: level 0 is full resolution, each further level halves it.
public struct TileID: Hashable, Sendable {
    public let level: Int
    public let column: Int
    public let row: Int

    public init(level: Int, column: Int, row: Int) {
        self.level = level
        self.column = column
        self.row = row
    }
}

/// The image pyramid and its tiling, as pure integer maths, so upload, pyramid build and
/// renderer agree on every tile's position without sharing any state.
///
/// Tiles hold 512 px of content plus an 8 px apron on every side (528 px slots), so bilinear
/// sampling at a tile edge reads real neighbour pixels instead of a seam. Level `L` measures
/// `ceil(size / 2^L)` per axis; the last level is the first whose larger side is at most 512.
/// `level` arguments must lie in `0..<levelCount`.
public struct TileGrid: Equatable, Sendable {
    public static let tileSize = 512
    public static let apron = 8
    public static let slotSize = 528

    /// Metal's limit on a texture array's length (`MTLTextureDescriptor.arrayLength`), and the renderer keeps
    /// one array per level with one slice per tile, so no level may have more tiles than this: 2048 tiles of
    /// 512 px is about 536 MP (e.g. 23170² or a 100000 x 5000 px panorama), beyond which the viewer refuses the image.
    public static let maxTilesPerLevel = 2048

    public let imageSize: PixelSize
    public let levelCount: Int

    public init(imageSize: PixelSize) {
        self.imageSize = imageSize
        // A side of 0 (or less) never exceeds 512, so a degenerate image gets one empty level.
        var count = 1
        var size = imageSize
        while max(size.width, size.height) > Self.tileSize {
            size = PixelSize(width: Self.halved(size.width), height: Self.halved(size.height))
            count += 1
        }
        levelCount = count
    }

    /// The most tiles any level holds (level 0 has the most; checked per level anyway, so the answer does not
    /// depend on that).
    public var maxTilesInLevel: Int {
        (0..<levelCount).map { columns($0) * rows($0) }.max() ?? 0
    }

    /// Whether every level fits a texture array of `maxTilesPerLevel` slices. Pure header maths, so the
    /// caller can refuse an oversized image before it spends seconds and gigabytes decoding it.
    public var fitsTextureArrays: Bool { maxTilesInLevel <= Self.maxTilesPerLevel }

    /// `fitsTextureArrays` for an image of this size.
    public static func fitsTextureArrays(_ size: PixelSize) -> Bool { TileGrid(imageSize: size).fitsTextureArrays }

    private static func halved(_ n: Int) -> Int { (max(n, 0) + 1) / 2 }

    /// Level size, `ceil(size / 2^level)`. Matches what repeated 2x2 box-downsampling yields,
    /// where an odd edge pixel is kept rather than dropped.
    public func levelSize(_ level: Int) -> PixelSize {
        func scaled(_ n: Int) -> Int {
            let shift = min(max(level, 0), Int.bitWidth - 2)
            return (max(n, 0) + (1 << shift) - 1) >> shift
        }
        return PixelSize(width: scaled(imageSize.width), height: scaled(imageSize.height))
    }

    public func columns(_ level: Int) -> Int { (levelSize(level).width + Self.tileSize - 1) / Self.tileSize }
    public func rows(_ level: Int) -> Int { (levelSize(level).height + Self.tileSize - 1) / Self.tileSize }

    /// Index of the tile's slot in its level's texture array (row-major).
    public func slice(of tile: TileID) -> Int { tile.row * columns(tile.level) + tile.column }

    private func levelBounds(_ level: Int) -> PixelRect {
        let size = levelSize(level)
        return PixelRect(x: 0, y: 0, width: size.width, height: size.height)
    }

    /// The 512 px square the tile owns, in level pixels, clipped to the level (edge tiles are smaller).
    public func contentRect(_ tile: TileID) -> PixelRect {
        let t = Self.tileSize
        let raw = PixelRect(x: tile.column * t, y: tile.row * t, width: t, height: t)
        return raw.intersection(levelBounds(tile.level)) ?? PixelRect(x: raw.x, y: raw.y, width: 0, height: 0)
    }

    /// Content plus apron, clipped to the level: the pixels that are really uploaded into the slot.
    public func slotRect(_ tile: TileID) -> PixelRect {
        let a = Self.apron, t = Self.tileSize + 2 * Self.apron
        let raw = PixelRect(x: tile.column * Self.tileSize - a, y: tile.row * Self.tileSize - a, width: t, height: t)
        return raw.intersection(levelBounds(tile.level)) ?? PixelRect(x: raw.x, y: raw.y, width: 0, height: 0)
    }

    /// Level position of the slot's texel (0, 0), unclipped, so it can be negative at the top/left edge.
    /// `slotRect.origin - slotOrigin` is where the uploaded pixels start inside the slot.
    public func slotOrigin(_ tile: TileID) -> PixelPoint {
        PixelPoint(x: tile.column * Self.tileSize - Self.apron, y: tile.row * Self.tileSize - Self.apron)
    }

    /// Tiles whose content overlaps `rect` (level pixels), row-major. The rect is clipped to the
    /// level and treated as half-open, so an edge exactly on a tile boundary excludes the next tile.
    public func tiles(level: Int, intersecting rect: CGRect) -> [TileID] {
        let size = levelSize(level)
        guard !rect.isNull, !rect.minX.isNaN, !rect.minY.isNaN, !rect.maxX.isNaN, !rect.maxY.isNaN else { return [] }
        let x0 = max(rect.minX, 0), y0 = max(rect.minY, 0)
        let x1 = min(rect.maxX, Double(size.width)), y1 = min(rect.maxY, Double(size.height))
        guard x1 > x0, y1 > y0 else { return [] }
        let t = Self.tileSize
        // Bounds are finite and within the level here, so the Int conversions are safe.
        let c0 = Int(x0.rounded(.down)) / t, c1 = (Int(x1.rounded(.up)) - 1) / t
        let r0 = Int(y0.rounded(.down)) / t, r1 = (Int(y1.rounded(.up)) - 1) / t
        var result: [TileID] = []
        result.reserveCapacity((c1 - c0 + 1) * (r1 - r0 + 1))
        for r in r0...r1 {
            for c in c0...c1 { result.append(TileID(level: level, column: c, row: r)) }
        }
        return result
    }

    /// The coarsest level that is still at least as sharp as the screen needs at `scale`
    /// (screen px per image px): `max(0, floor(log2(1/s)))`, clamped to the available levels.
    /// A scale of 0 or less is infinitely zoomed out (coarsest); NaN falls back to full resolution.
    public static func level(forScale s: Double, levelCount: Int) -> Int {
        let last = max(levelCount - 1, 0)
        if s.isNaN { return 0 }
        if s <= 0 { return last }
        let l = (-log2(s)).rounded(.down)
        guard l > 0 else { return 0 }
        return l >= Double(last) ? last : Int(l)
    }

    /// The level a frame really draws: the one the scale needs, or the finest resident one when that is not
    /// resident (a preview only), which is then stretched. The renderer and the resample mode must agree on it.
    public func drawnLevel(forScale scale: Double, finestResident: Int) -> Int {
        max(Self.level(forScale: scale, levelCount: levelCount), finestResident)
    }
}

// MARK: Cache sizing

extension TileGrid {
    /// Lfit: the coarsest level that is still as sharp as Fit on a screen of `screen` pixels, and never finer
    /// than 100 % needs (a photo smaller than the screen is not "fit" any larger than it is). Computed for the
    /// whole screen, not the window, so a resize or fullscreen does not invalidate the preview. A degenerate
    /// image or screen has no meaningful fit scale and gets level 0. Fit is of the picture as shown: `orientation` is
    /// the one it is drawn with (`.up` with `exif-orientation=no`), so a turned photo fits by its oriented size, which
    /// on a screen of the other aspect is the coarser or the finer level (a portrait screen, a landscape photo shown
    /// upright). The grid itself stays the stored one; a level count does not depend on the orientation.
    public func previewLevel(forScreen screen: PixelSize, orientation: ImageOrientation = .up) -> Int {
        let shown = orientation.orientedSize(imageSize)
        guard shown.width > 0, shown.height > 0, screen.width > 0, screen.height > 0 else { return 0 }
        let fitScale = min(Double(screen.width) / Double(shown.width), Double(screen.height) / Double(shown.height))
        return Self.level(forScale: min(1, fitScale), levelCount: levelCount)
    }

    /// GPU bytes of the slot arrays of `levels` (528² x 4 per tile, edge tiles cost a full slot). Levels outside
    /// the pyramid count for nothing, so callers can pass `Lfit + 1 ..< levelCount` without clamping first.
    public func byteCount(levels: Range<Int>) -> Int {
        let slotBytes = Self.slotSize * Self.slotSize * 4
        let lower = max(levels.lowerBound, 0), upper = min(levels.upperBound, levelCount)
        guard lower < upper else { return 0 }
        return (lower..<upper).reduce(0) { $0 + columns($1) * rows($1) * slotBytes }
    }
}
