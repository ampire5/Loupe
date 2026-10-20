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
}
