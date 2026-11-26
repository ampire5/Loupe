import CoreGraphics
import Foundation

/// The GPU side of the cache: makes pyramids, uploads decoded levels into them and evicts levels again.
/// The app's loader wraps `TiledImage` (LoupeRender); tests use a fake. `LoupeCore` knows nothing of Metal.
public protocol PyramidLoader: Sendable {
    associatedtype Pyramid: AnyObject & Sendable
    /// An empty pyramid (nothing resident) for an image of `grid`, in its own colour space.
    func makePyramid(grid: TileGrid, colorSpace: CGColorSpace) -> Pyramid
    /// Uploads `image` as its level and (re)builds every coarser level; returns once they are resident.
    func upload(_ image: LevelImage, into pyramid: Pyramid) async throws
    /// Releases levels finer than `level`.
    func evict(finerThan level: Int, of pyramid: Pyramid)
    /// Finest resident level, nil when nothing is resident. Resident levels are a suffix finest...last.
    func finestResidentLevel(of pyramid: Pyramid) -> Int?
    /// Allocation cost of building these levels, before any textures exist.
    func estimatedPyramidBytes(for grid: TileGrid, levels: Range<Int>) -> Int
    /// Bytes allocated for all levels currently resident.
    func residentPyramidBytes(of pyramid: Pyramid, grid: TileGrid) -> Int
}

public extension PyramidLoader {
    func estimatedPyramidBytes(for grid: TileGrid, levels: Range<Int>) -> Int {
        grid.byteCount(levels: levels)
    }

    func residentPyramidBytes(of pyramid: Pyramid, grid: TileGrid) -> Int {
        guard let finest = finestResidentLevel(of: pyramid) else { return 0 }
        return estimatedPyramidBytes(for: grid, levels: finest..<grid.levelCount)
    }
}
