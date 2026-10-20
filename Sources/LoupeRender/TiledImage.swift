import CoreGraphics
import Foundation
import LoupeCore
import Metal
import os

/// An image resident on the GPU as a pyramid of 528x528 tile slots (512 px content + 8 px apron),
/// one `type2DArray` texture per level whose slices are the level's tiles in row-major order
/// (`TileGrid.slice(of:)`). Slots rather than one huge texture per level keep every texture within
/// Metal's size limits and let the renderer address a tile by slice alone.
///
/// Levels are resident one by one (M2 cache): a preview uploads only its level and the coarser ones, the full
/// resolution arrives later and the cache may evict it again. Resident levels are always a suffix
/// `finest...last`, because an upload of level L always (re)builds every coarser level. The level arrays sit
/// behind a lock: the render thread copies them once per frame while an upload or eviction swaps them.
/// Textures are never written once published, so a frame sampling an old texture keeps seeing intact pixels;
/// its command buffer retains the texture until the GPU is done with it.
public final class TiledImage: @unchecked Sendable {
    public let grid: TileGrid
    /// The image's own colour space (pixels are never converted); the app tags the `CAMetalLayer` with it.
    public let colorSpace: CGColorSpace

    /// Per level, nil when not resident. `textures`: `bgra8Unorm`, private (`.shaderWrite` lets the downsample
    /// kernel fill coarser levels; `.pixelFormatView` allows the views). `views`: `bgra8Unorm_srgb` views of
    /// them, so sampling linearises texels before filtering and blends and averages happen in linear light.
    struct Levels {
        var textures: [MTLTexture?]
        var views: [MTLTexture?]
        var revision = 0
        /// Whether an upload published a level with alpha < 1 (`hasAlpha`).
        var hasAlpha = false
        /// The tables of the photo's transfer curve, resolved by its first upload (`curve`).
        var curve: CurveTables?
        /// While an upload is in flight (at most one per image, see `uploads`): the finest level it may still
        /// publish. Starts at 0 and is raised by `evict`, so an eviction during the upload is not undone by it
        /// (M2 spec §4.4: the result for evicted levels is discarded). Nil when no upload is in flight.
        var uploadFloor: Int?
    }

    private let state: OSAllocatedUnfairLock<Levels>
    /// Serialises uploads to this image, so two uploads cannot swap their levels in the wrong order.
    private let uploads = AsyncGate()
    /// Test hook: runs after an upload's GPU work completes, just before its levels are published.
    nonisolated(unsafe) var willPublish: (() -> Void)?

    private init(grid: TileGrid, colorSpace: CGColorSpace) {
        self.grid = grid
        self.colorSpace = colorSpace
        let none = [MTLTexture?](repeating: nil, count: grid.levelCount)
        state = OSAllocatedUnfairLock(uncheckedState: Levels(textures: none, views: none))
    }

    /// An image with no level resident yet; the renderer draws nothing for it until an `upload` completes.
    public static func empty(grid: TileGrid, colorSpace: CGColorSpace) -> TiledImage {
        TiledImage(grid: grid, colorSpace: colorSpace)
    }

    /// Uploads `image` (level 0 pixels) and builds every coarser level with `filter`: `empty` + `upload` at level 0.
    /// Throws `.unreadable` for an empty image, `.tooLarge` when a level needs more tiles than a texture array
    /// holds (checked before anything is allocated), and `.outOfMemory` when a texture or buffer cannot be allocated.
    public static func make(from image: DecodedImage, filter: PyramidFilter = .box,
                            context: MetalContext = .shared) async throws -> TiledImage {
        guard image.pixelSize.width > 0, image.pixelSize.height > 0 else { throw DecodeError.unreadable }
        let result = TiledImage(grid: TileGrid(imageSize: image.pixelSize), colorSpace: image.colorSpace)
        try await result.upload(LevelImage(image: image, level: 0), filter: filter, context: context)
        return result
    }

    // MARK: Residency

    /// Finest resident level, nil when nothing is resident. Resident levels are always a suffix finest...last.
    public var finestResidentLevel: Int? {
        state.withLockUnchecked { $0.views.firstIndex { $0 != nil } }
    }

    /// Copy of the sampling views under the lock: nil for non-resident levels. The renderer reads it once per
    /// frame, so a swap during the frame cannot mix levels of two uploads.
    public func residentViews() -> [MTLTexture?] {
        state.withLockUnchecked { $0.views }
    }

    /// Whether the photo has transparency: set when an upload (a preview or level 0) publishes pixels with any alpha
    /// below 255, found by one scan of the decoded buffer in that upload (`DecodedImage.hasTransparentPixel`; only
    /// when the decoder reports an alpha channel at all). Such levels hold premultiplied linear light (`Shaders.source`)
    /// and are drawn by the `HAS_ALPHA` pipelines over the backdrop; a photo whose alpha channel is all 255 stays
    /// false and takes the ordinary pipelines (M3b spec §3). Never cleared: once a level had alpha, the photo has it.
    public var hasAlpha: Bool { state.withLockUnchecked { $0.hasAlpha } }

    /// Tests: the transfer curve of `colorSpace` (M3b spec §4) that the levels' linear light and the frames' output
    /// follow, once the first upload resolved it (off the cache actor: the first non-sRGB curve of a process costs
    /// ~2 ms); nil before.
    var curve: ColorCurve? { state.withLockUnchecked { $0.curve?.curve } }

    /// `residentViews()`, `hasAlpha` and the curve's tables read together under the lock, so a frame never pairs levels
    /// of one upload with the alpha flag of another.
    func residentState() -> (views: [MTLTexture?], hasAlpha: Bool, curve: CurveTables?) {
        state.withLockUnchecked { ($0.views, $0.hasAlpha, $0.curve) }
    }

    /// Increments on every upload and eviction, so a viewer can tell that the image got sharper (or coarser).
    public var revision: Int { state.withLockUnchecked { $0.revision } }

    /// GPU memory held by the resident level textures.
    public var byteCount: Int {
        state.withLockUnchecked { levels in
            levels.textures.reduce(0) { $0 + ($1?.arrayLength ?? 0) * TileGrid.slotSize * TileGrid.slotSize * 4 }
        }
    }

    /// Every level texture, indexed by level (internal, for tests). Only valid on a fully resident image:
    /// traps otherwise, so an index can never silently name a different level.
    var levels: [MTLTexture] {
        state.withLockUnchecked { levels in
            precondition(levels.textures.allSatisfy { $0 != nil }, "levels: image is not fully resident")
            return levels.textures.map { $0! }
        }
    }
    /// Every sampling view, indexed by level (internal, for tests; fully resident images only, see `levels`).
    var sampleViews: [MTLTexture] {
        state.withLockUnchecked { levels in
            precondition(levels.views.allSatisfy { $0 != nil }, "sampleViews: image is not fully resident")
            return levels.views.map { $0! }
        }
    }

    /// Releases levels finer than `level` (eviction of the full resolution); bumps `revision` when it dropped
    /// something. An upload in flight will not publish those levels either. Frames already encoded keep their
    /// textures alive until they complete.
    public func evict(finerThan level: Int) {
        let floor = min(max(level, 0), grid.levelCount)
        state.withLockUnchecked { levels in
            if let current = levels.uploadFloor { levels.uploadFloor = max(current, floor) }
            var dropped = false
            for l in 0..<floor where levels.textures[l] != nil {
                levels.textures[l] = nil
                levels.views[l] = nil
                dropped = true
            }
            if dropped { levels.revision += 1 }
        }
    }

    // MARK: Upload

    /// Uploads `image` as level `level` and (re)builds every coarser level with `filter` on `context.uploadQueue`;
    /// on completion swaps in the new textures for `level...` atomically and bumps `revision`. Returns the GPU time of
    /// that work in seconds (blits and pyramid build, one command buffer), nil when the upload was skipped.
    ///
    /// Fresh textures are allocated for `level...last` and published only after the GPU completes, so a frame
    /// sampling the old ones is never disturbed; finer levels already resident stay. Levels that `evict` dropped
    /// while this upload was in flight are discarded, not published (nothing is published, and `revision` stays,
    /// when that covers every level). The GPU reads the decoded pixels in place (no copy), which is why
    /// `DecodedImage.buffer` is page-aligned; the buffer may be freed once this returns. Uploads to one image are
    /// serialised, in the order they reach the gate.
    ///
    /// An upload that finds `level` or a finer one already resident once it holds the gate is skipped (nothing
    /// published, `revision` unchanged): it would only replace coarse levels built from finer pixels with ones
    /// built from its own (a preview queued behind a full upload, say).
    /// Throws `.unreadable` when the level is outside the pyramid or the pixels are not `grid.levelSize(level)`,
    /// `.tooLarge` / `.outOfMemory` as `make`, or the command buffer's error.
    @discardableResult
    public func upload(_ image: LevelImage, filter: PyramidFilter = .box,
                       context: MetalContext = .shared) async throws -> Double? {
        let level = image.level, pixels = image.image, size = pixels.pixelSize
        guard (0..<grid.levelCount).contains(level), size == grid.levelSize(level), size.width > 0, size.height > 0,
              pixels.bytesPerRow >= size.width * 4, pixels.bytesPerRow * size.height <= pixels.buffer.length
        else { throw DecodeError.unreadable }

        await uploads.acquire()
        if let finest = finestResidentLevel, finest <= level {
            await uploads.release()
            return nil
        }
        let resolved = state.withLockUnchecked { levels in
            levels.uploadFloor = 0
            return levels.curve
        }
        let transparent = pixels.hasAlphaChannel && pixels.hasTransparentPixel()
        let gpuSeconds: Double
        do {
            // The curve once per photo (uploads are serialised by the gate); its tables are shared by every photo with it.
            guard let curve = resolved ?? context.curveTables(for: ColorCurve.of(colorSpace)) else {
                throw DecodeError.outOfMemory
            }
            // A level with alpha < 1, or any level of a `.table` curve, goes through the upload table (`Shaders.source`).
            var table: MTLBuffer?
            if transparent || curve.inverse != nil {
                guard let made = curve.upload() else { throw DecodeError.outOfMemory }
                table = made
            }
            let (textures, views, seconds) = try await encodeAndRun(pixels, level: level, filter: filter,
                                                                   premultipliedLinear: table, context: context)
            gpuSeconds = seconds
            willPublish?()
            state.withLockUnchecked { levels in
                let first = max(level, levels.uploadFloor ?? 0)
                levels.uploadFloor = nil
                levels.curve = curve
                guard first < grid.levelCount else { return }
                for l in first..<grid.levelCount {
                    levels.textures[l] = textures[l - level]
                    levels.views[l] = views[l - level]
                }
                levels.hasAlpha = levels.hasAlpha || transparent
                levels.revision += 1
            }
        } catch {
            state.withLockUnchecked { $0.uploadFloor = nil }
            await uploads.release()
            throw error
        }
        await uploads.release()
        return gpuSeconds
    }
}

/// A FIFO async mutex: `acquire` suspends (without blocking a thread) until the previous holder calls `release`.
actor AsyncGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate straight to the next waiter (which stays `held`), or frees it.
    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}
