import CoreGraphics
import Foundation
import LoupeCore
import Metal

/// Draws the visible part of a `TiledImage` for a `ViewTransform`, by one of the frame paths of M3a spec §3.1: the
/// `resample` compute kernel (one dispatch over the drawable, reading the level's tile slots directly), the tile
/// fragment pass (one instanced draw of the visible tiles, bilinear or nearest), or MetalFX Spatial
/// (TileRenderer+MetalFX.swift). The app calls `encode` every frame from its render thread, so the per-frame work is
/// kept small: the render pass descriptor and the instance array are reused, and instance buffers come from a ring
/// that is only allocated (or grown) when a frame needs more.
///
/// Not thread-safe: create it anywhere, then use it (`encode`, `background`, `resample`) from one thread at a time.
public final class TileRenderer {
    /// The colour outside the image (letterbox) and of a frame without an image; black by default (spec §6).
    /// Like the fragment output it is linear light: the `_srgb` target encodes it on store (0.5 becomes 188).
    public var background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// The resampling keys of loupe.conf; each frame picks its path from them (`ResampleSettings.mode`). Like
    /// `background`, set before `encode`: the next frame uses the new filter.
    public var resample = ResampleSettings()

    /// What shows through the transparent pixels of a photo with alpha (`TiledImage.hasAlpha`, M3b spec §3): the
    /// checkerboard or a colour, already in linear light. Set like `background`; photos without alpha ignore it.
    public var transparency = TransparencySettings()
    /// Drawable pixels per point of the window (`backingScaleFactor`): a checker cell is `checkerSizePt` times this.
    public var backingScale = 1.0

    /// The colour cube of the photo the next frames draw (M3c spec §5), set with the image it belongs to: nil, or the
    /// shared identity fully shown (`ColorLUT.identity`, `mix` 1), draws with the pipelines of before; anything else with
    /// their `COLOR_LUT` variant, which samples it (and `from`, while `mix` < 1) at the output of every path.
    public var color: ColorFrame?

    /// Diagnostics, called on the render thread: once per renderer, when a MetalFX or EWA Lanczos frame has to be
    /// drawn with Lanczos-3 instead. The app routes it to its debug log.
    public var log: ((String) -> Void)?

    /// What the last `encode` drew (for tests): its path, as really drawn (a MetalFX or EWA fallback is Lanczos-3), and
    /// pyramid level; nil when it drew no image.
    private(set) var lastMode: ResampleMode?
    private(set) var lastLevel: Int?
    /// Whether the last `encode` drew with a `HAS_ALPHA` pipeline (for tests).
    private(set) var lastHasAlpha = false
    /// Whether the last `encode` drew with a `CURVE_TABLE` pipeline, into the target's unorm view (for tests).
    private(set) var lastCurveTable = false
    /// Whether the last `encode` drew an image through its colour cube, with a `COLOR_LUT` pipeline (tests, stats).
    public private(set) var lastColorLUT = false

    /// Whether MetalFX frames go through the scaler: the GPU's support, which tests turn off to reach the fallback.
    var metalFXSupported: Bool
    /// The MetalFX scaler and its two view-size textures while frames use MetalFX; released by the first frame that
    /// draws an image by another path (a frame without one keeps them: switching photos does not remake the scaler).
    var metalFX: MetalFXStage?
    /// The view size whose scaler or textures could not be made: its frames draw Lanczos-3 without retrying every
    /// frame, until the size changes.
    var metalFXFailedSize: SIMD2<Int>?
    /// Tests: making the scaler and textures fails, to reach that fallback.
    var failMetalFXStage = false
    /// The view size whose second checker output (`MetalFXStage.secondOutput`) could not be made: frames of a photo
    /// with alpha over the checkerboard draw Lanczos-3 at that size without retrying the allocation every frame (until
    /// the stage is made again: a new size, or MetalFX after another path).
    var metalFXSecondFailedSize: SIMD2<Int>?
    /// Tests: making the second checker output fails.
    var failMetalFXSecondOutput = false
    /// Whether the renderer holds MetalFX's scaler and textures (for tests).
    var holdsMetalFX: Bool { metalFX != nil }
    /// Whether it holds the second checker output too (for tests).
    var holdsMetalFXSecondOutput: Bool { metalFX?.secondOutput != nil }
    /// What this renderer last told the context about MetalFX (`noteMetalFXStage`), for tests: false after a failure.
    var lastMetalFXNote: Bool?
    /// What a frame of two pages needs of the MetalFX stage, so that pages on different paths do not let it (or its
    /// second output) go and remake it for each other every frame (`encode`'s `clears` starts a frame): the first page's
    /// needs in this frame, the other pages' in this frame and in the frame before.
    struct MetalFXUse {
        var stage = false
        var secondOutput = false
    }
    var metalFXFirst = MetalFXUse()
    var metalFXOthers = MetalFXUse()
    var metalFXOthersBefore = MetalFXUse()
    private var loggedMetalFXFallback = false
    private var loggedEWAFallback = false
    private var loggedCurveFallback = false

    /// Instance data up to this many bytes goes inline with `setVertexBytes` (Metal's recommended limit for
    /// it is 4 KiB); larger frames use the buffer ring. Internal so tests can force the ring.
    var inlineInstanceLimit = 4096
    /// Frames whose instances went through the ring (for tests).
    private(set) var bufferedFrameCount = 0

    let context: MetalContext
    private let device: MTLDevice
    private let pixelFormat: MTLPixelFormat
    private let pipeline: MTLRenderPipelineState
    private let nearestPipeline: MTLRenderPipelineState
    private let pass = MTLRenderPassDescriptor()
    private var instances: [TileInstance] = []

    /// Three instance buffers, one per frame the GPU may still be reading. Each has its own semaphore, taken
    /// while a command buffer that reads it is in flight and given back by that buffer's completed handler,
    /// so a slot is never rewritten under the GPU, whatever order command buffers complete in.
    private var ring: [MTLBuffer?] = [nil, nil, nil]
    private let ringFree = (0..<3).map { _ in DispatchSemaphore(value: 1) }
    private var ringIndex = 0

    /// `pixelFormat` must be an `_srgb` format (the app's `CAMetalLayer` uses `bgra8Unorm_srgb`): the tile
    /// fragment shader samples the sRGB views, filters in linear light and returns linear values, which only
    /// an `_srgb` target re-encodes; a plain unorm target would show the image too dark. A photo with a `.table` curve
    /// is written into the target's unorm view instead (`encode`).
    public init(context: MetalContext = .shared, pixelFormat: MTLPixelFormat) {
        self.context = context
        device = context.device
        metalFXSupported = context.supportsMetalFX
        self.pixelFormat = pixelFormat
        pipeline = context.tilePipeline(pixelFormat: pixelFormat)
        nearestPipeline = context.tilePipeline(pixelFormat: pixelFormat, nearest: true)
        instances.reserveCapacity(512)
        let attachment = pass.colorAttachments[0]!
        attachment.loadAction = .clear
        attachment.storeAction = .store
    }

    /// Draws `image` for `transform` (whose viewSize must equal the target size) into `target`, background around it;
    /// without an image (or before any level is resident) just clears `target` to the background.
    ///
    /// A photo whose curve is not sRGB's (`ColorCurve.table`, M3b spec §4) is drawn by the `CURVE_TABLE` pipelines into
    /// a `bgra8Unorm` view of `target` (made per frame: views that change only the sRGB-ness need no `.pixelFormatView`
    /// usage), each pixel the photo's own encoded level from its inverse table; around the picture the background's
    /// bytes, as on any frame.
    ///
    /// A frame with a colour cube (`color`, M3c spec §5) takes the `COLOR_LUT` variant of whatever pipelines it would take
    /// (`HAS_ALPHA` and `CURVE_TABLE` included): each path samples the cube where its colour is final, before the backdrop
    /// and the output encode; MetalFX in the pass that composites (Shaders.source). Without one it is the frame of before.
    ///
    /// `orientation` turns and mirrors the stored image for the view (M3b spec §2.1): `transform.imageSize` is the
    /// oriented size (`orientation.orientedSize` of the image's stored one); every path maps view px to oriented level
    /// px and on to stored ones, so the pixels stay as stored and the frame costs the same. `.up` draws as stored.
    ///
    /// The pyramid level is the coarsest one still as sharp as the screen needs (`TileGrid.drawnLevel`), so a
    /// zoomed-out 147 MP photo draws a few downsampled tiles rather than sampling level 0 sparsely. If that level is
    /// not resident (only a preview is loaded), the finest resident level is stretched to fit. The path follows from
    /// the settings, the scale and that level (`ResampleSettings.mode`): the compute kernel writes `target` directly,
    /// so `target` needs `.shaderWrite` usage (a drawable has it when its layer is not `framebufferOnly`).
    /// `commandBuffer` must be committed: when a frame's instances do not fit inline, the ring slot it uses
    /// is released by the buffer's completed handler, and a fourth such frame waits for that release.
    ///
    /// Two pages in one frame (spread spec, «Архитектура»): the first page's call clears (`clears`, the default) and
    /// writes all of `target`, as a single page does, its picture confined to its own view rect anyway; each further
    /// page's call passes `clears: false` and its `viewport` (drawable px, `PagePlacement.viewport`), and writes nothing
    /// outside it: the tile passes load the target and scissor to it, the compute kernels are dispatched over it alone,
    /// MetalFX's final pass loads and scissors. Within the viewport such a call draws the picture; around it the target
    /// keeps what the first call put there, the background (the kernels and MetalFX write it there again, the tile pass
    /// does not), and without an image or a resident level it encodes nothing. `transform` is the page's own
    /// (`PagePlacement.transform`): its `viewSize` is the target's like any frame's. MetalFX keeps its view-sized
    /// stage, and each page runs it over the whole view (its final pass then cuts it to the viewport): twice the
    /// scaler's work in a frame of two MetalFX pages, and no stage per page.
    public func encode(image: TiledImage?, transform: ViewTransform, orientation: ImageOrientation = .up,
                       into commandBuffer: MTLCommandBuffer, target: MTLTexture,
                       viewport: CGRect? = nil, clears: Bool = true) {
        lastMode = nil
        lastLevel = nil
        lastHasAlpha = false
        lastCurveTable = false
        lastColorLUT = false
        if clears {
            metalFXOthersBefore = metalFXOthers
            metalFXOthers = MetalFXUse()
            metalFXFirst = MetalFXUse()
        }
        // Nil: the call clears and may write all of target. Otherwise the px it may write; none, nothing to draw.
        var clip: MTLScissorRect?
        if !clears {
            guard let c = Self.scissor(viewport, target: target) else { return }
            clip = c
        }
        guard let image, var frame = LevelFrame(image: image, transform: transform, orientation: orientation) else {
            if clears { encodeTiles(nil, nearest: false, commandBuffer: commandBuffer, target: target) }
            return
        }
        var target = target
        if frame.inverseCurve != nil {
            if let format = Self.unormFormat(of: target.pixelFormat), let view = target.makeTextureView(pixelFormat: format) {
                target = view
            } else {
                // Never reached by the app (its drawable is bgra8Unorm_srgb, which always has the view). The sRGB
                // pipelines then show the levels as stored, enc_srgb(lin_curve(s)), through the sRGB curve: tones come
                // out brighter than the photo's (ProPhoto 0.5 shows as 0.58) and the backdrop is not re-linearised.
                if !loggedCurveFallback {
                    loggedCurveFallback = true
                    log?("colour curve: no unorm view of a \(target.pixelFormat.rawValue) target; drawing with the sRGB curve")
                }
                frame.dropCurve()
            }
        }
        var mode = resample.mode(scale: transform.drawnScale, level: frame.level)
        if mode == .metalfx, !metalFXSupported {
            mode = metalFXFallback(because: "this GPU has no MetalFX spatial scaler")
        }
        if mode == .ewaLanczos, !context.supportsEWA {
            if !loggedEWAFallback {
                loggedEWAFallback = true
                log?("upscale=ewa-lanczos: this GPU cannot filter the weight table (r32Float); drawing with lanczos3")
            }
            mode = MetalContext.metalFXFallback
        }
        // ~85 MB each on 6K: held only while frames use them (a page of the same frame, or the next page of a spread
        // as the frame before had it, counts as using it).
        if mode == .metalfx {
            if clears { metalFXFirst.stage = true } else { metalFXOthers.stage = true }
        } else if !(clears ? metalFXOthersBefore.stage : metalFXFirst.stage) {
            metalFX = nil
        }
        if let color, !color.isIdentity { frame.color = color }
        lastMode = mode
        lastLevel = frame.level
        lastHasAlpha = frame.hasAlpha
        lastCurveTable = frame.inverseCurve != nil
        lastColorLUT = frame.color != nil
        switch mode {
        case .kernel(let kernel, let upscale):
            encodeResample(frame, kernel: kernel, upscale: upscale, commandBuffer: commandBuffer, target: target, clip: clip)
        case .ewaLanczos:
            encodeResample(frame, kernel: nil, upscale: true, commandBuffer: commandBuffer, target: target, clip: clip)
        case .bilinear:
            encodeTiles(frame, nearest: false, commandBuffer: commandBuffer, target: target, clip: clip)
        case .nearest:
            encodeTiles(frame, nearest: true, commandBuffer: commandBuffer, target: target, clip: clip)
        case .metalfx:
            if !encodeMetalFX(frame, commandBuffer: commandBuffer, target: target, clip: clip) {
                let size = "\(target.width)x\(target.height)"
                lastMode = metalFXFallback(because: "no MetalFX spatial scaler or textures could be made for \(size)")
                encodeResample(frame, kernel: .lanczos3, upscale: true, commandBuffer: commandBuffer, target: target,
                               clip: clip)
            }
        }
    }

    /// `viewport` as whole px of `target` (rounded outwards, clipped to it); nil when that leaves none. Nil `viewport`:
    /// all of target.
    static func scissor(_ viewport: CGRect?, target: MTLTexture) -> MTLScissorRect? {
        guard let viewport else {
            return target.width > 0 && target.height > 0
                ? MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height) : nil
        }
        guard !viewport.isNull, viewport.minX.isFinite, viewport.maxX.isFinite, viewport.minY.isFinite,
              viewport.maxY.isFinite else { return nil }
        let x0 = Int(max(viewport.minX.rounded(.down), 0)), y0 = Int(max(viewport.minY.rounded(.down), 0))
        let x1 = Int(min(viewport.maxX.rounded(.up), Double(target.width)))
        let y1 = Int(min(viewport.maxY.rounded(.up), Double(target.height)))
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The path a MetalFX frame takes when MetalFX cannot draw it, logged the first time.
    private func metalFXFallback(because reason: String) -> ResampleMode {
        if !loggedMetalFXFallback {
            loggedMetalFXFallback = true
            log?("upscale=metalfx: \(reason); drawing with lanczos3")
        }
        return MetalContext.metalFXFallback
    }

    /// The compute path: one `resample` dispatch (or `resampleEWA` when `kernel` is nil, `upscale = ewa-lanczos`)
    /// writes every pixel of `target` (of `clip`, when given), background included, so there is no render pass and no
    /// clear. Needs no tile instances: each threadgroup finds its texels' slots itself.
    private func encodeResample(_ frame: LevelFrame, kernel: ResampleKernel?, upscale: Bool,
                                commandBuffer: MTLCommandBuffer, target: MTLTexture, clip: MTLScissorRect? = nil) {
        guard target.width > 0, target.height > 0 else { return }
        // The dispatch covers view px x0 ..< x0 + w, y0 ..< y0 + h: the whole target, or the clip. The kernels work in
        // the dispatch's own px, so the view geometry is given less (x0, y0) (whole px, exact in Float for offsets under
        // 2^21 px) and only their writes add it back. Without a clip it is the dispatch of before, to the bit.
        let x0 = clip?.x ?? 0, y0 = clip?.y ?? 0
        let w = clip?.width ?? target.width, h = clip?.height ?? target.height
        let shift = SIMD2(Float(x0), Float(y0))
        // A GPU that cannot write _srgb textures from a shader (Intel and AMD Macs) gets the target's unorm view and
        // the ENCODE_SRGB variant, which encodes itself; background(for:) then gives the background encoded too. A
        // `.table` frame's target is that view already, written through the inverse table.
        var target = target, encodeSRGB = false
        if !context.supportsSRGBWrites, let format = Self.unormFormat(of: target.pixelFormat),
           let view = target.makeTextureView(pixelFormat: format) {
            target = view
            encodeSRGB = true
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = kernel == nil ? "resampleEWA" : "resample"
        let size = frame.grid.levelSize(frame.level)
        // lanczos-antiring is a Lanczos option (spec §5), EWA Lanczos included; the separable shader applies it only
        // when magnifying, EWA only ever magnifies.
        let antiringing = resample.antiringing && (kernel == nil || kernel == .lanczos3 || kernel == .lanczos2)
        var params = ResampleParams(levelToViewScale: frame.levelToView, levelToViewOffset: frame.offset - shift,
                                    levelSize: SIMD2(UInt32(size.width), UInt32(size.height)),
                                    extent: frame.orientedExtent,
                                    viewSize: SIMD2(UInt32(w), UInt32(h)),
                                    columns: UInt32(frame.grid.columns(frame.level)),
                                    antiringing: antiringing ? 1 : 0, background: background(for: target),
                                    orient: frame.orient, shift: frame.shift, origin: SIMD2(UInt32(x0), UInt32(y0)))
        let table = frame.inverseCurve != nil, cube = frame.color != nil
        if let kernel {
            encoder.setComputePipelineState(context.resamplePipeline(kernel: kernel, upscale: upscale, alpha: frame.hasAlpha,
                                                                     curveTable: table, colorLUT: cube,
                                                                     encodeSRGB: encodeSRGB))
        } else {
            encoder.setComputePipelineState(context.ewaPipeline(alpha: frame.hasAlpha, curveTable: table, colorLUT: cube,
                                                                encodeSRGB: encodeSRGB))
            encoder.setTexture(context.ewaWeights, index: 2)
            var cutoff2 = MetalContext.ewaCutoffSquared
            encoder.setBytes(&cutoff2, length: MemoryLayout<Float>.stride, index: 1)
        }
        encoder.setTexture(frame.view, index: 0)
        encoder.setTexture(target, index: 1)
        if table { encoder.setTexture(frame.inverseCurve, index: 3) }
        encoder.setBytes(&params, length: MemoryLayout<ResampleParams>.stride, index: 0)
        if frame.hasAlpha {
            var backdrop = transparencyParams(frame)
            backdrop.anchor -= shift
            encoder.setBytes(&backdrop, length: MemoryLayout<TransparencyParams>.stride, index: 2)
        }
        if let color = frame.color {
            var params = ColorLUTParams(mix: color.mix)
            encoder.setTexture(color.lut.texture, index: 4)
            encoder.setTexture(fromTexture(color, params), index: 5)
            encoder.setBytes(&params, length: MemoryLayout<ColorLUTParams>.stride, index: 3)
        }
        let group = 16   // the kernels' threadgroup side; their threadgroup arrays are sized for exactly this
        encoder.dispatchThreadgroups(MTLSize(width: (w + group - 1) / group, height: (h + group - 1) / group, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: group, height: group, depth: 1))
        encoder.endEncoding()
    }

    /// The pan position pills (M4b spec §5) over the finished frame in `target`: one `panIndicators` dispatch per pill over
    /// its rect, in `commandBuffer` after the frame's own passes. Black at 50 %, a 1 physical px white outline at 60 %,
    /// corners rounded to half the thickness, all times `alpha`. Encodes nothing for no pills or an alpha of 0.
    /// `target` is read and written: the app's drawable has `framebufferOnly = false`, a test's needs `shaderRead` and
    /// `shaderWrite`. The pills are in view pixels already, and the outline is one physical pixel whatever the window's
    /// scale, so `backingScale` is only part of the call's contract (the caller's `PanIndicators.pills` took it).
    public func encodePanIndicators(_ pills: [PanIndicatorPill], alpha: Float, backingScale: Double,
                                    into commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        guard alpha > 0, !pills.isEmpty, target.width > 0, target.height > 0,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "panIndicators"
        encoder.setComputePipelineState(context.panIndicators)
        encoder.setTexture(target, index: 0)
        let encoded: UInt32 = Self.unormFormat(of: target.pixelFormat) == nil ? 1 : 0
        for pill in pills {
            let r = pill.rect
            // The pixels the rect can touch (a pixel centre within half a pixel of the edge), inside the target.
            let x0 = max(Int(r.minX.rounded(.down)), 0), y0 = max(Int(r.minY.rounded(.down)), 0)
            let x1 = min(Int(r.maxX.rounded(.up)), target.width), y1 = min(Int(r.maxY.rounded(.up)), target.height)
            guard x1 > x0, y1 > y0 else { continue }
            var params = PanPillParams(rect: SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY)),
                                       radius: Float(min(r.width, r.height) / 2), outline: 1, alpha: alpha,
                                       encoded: encoded, origin: SIMD2(UInt32(x0), UInt32(y0)),
                                       fill: SIMD4(0, 0, 0, Self.pillFillAlpha), line: SIMD4(1, 1, 1, Self.pillLineAlpha))
            encoder.setBytes(&params, length: MemoryLayout<PanPillParams>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: x1 - x0, height: y1 - y0, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }
        encoder.endEncoding()
    }

    /// The pills' body (black) and outline (white) opacity, spec §5.1.
    private static let pillFillAlpha: Float = 0.5
    private static let pillLineAlpha: Float = 0.6

    /// The tile fragment pass: clears `target` and draws `frame`'s visible tiles, if any, bilinear or (`nearest`,
    /// pixel art) as hard level px. Tiles are stored ones, chosen by the stored rect under the view; the vertex shader
    /// turns their corners into the view. With a `clip` (a page after the first, `encode`) the pass loads `target`
    /// instead of clearing it and draws only within the clip.
    func encodeTiles(_ frame: LevelFrame?, nearest: Bool, commandBuffer: MTLCommandBuffer, target: MTLTexture,
                     clip: MTLScissorRect? = nil) {
        let attachment = pass.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = clip == nil ? .clear : .load
        attachment.clearColor = clearColor(for: target)
        let made = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        attachment.texture = nil   // the encoder has its copy; do not keep the drawable alive until the next frame
        guard let encoder = made else { return }
        encoder.label = "tiles"
        if let clip { encoder.setScissorRect(clip) }
        if let frame { drawTiles(frame, nearest: nearest, encoder: encoder, commandBuffer: commandBuffer, target: target) }
        encoder.endEncoding()
    }

    private func drawTiles(_ frame: LevelFrame, nearest: Bool, encoder: MTLRenderCommandEncoder,
                           commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        let grid = frame.grid, level = frame.level, factor = frame.factor
        let extentX = frame.extent.x, extentY = frame.extent.y
        let storedSize = CGSize(width: grid.imageSize.width, height: grid.imageSize.height)
        let visible = frame.orientation.storedRect(frame.transform.visibleRect, storedSize: storedSize)
        let levelRect = CGRect(x: visible.minX / factor, y: visible.minY / factor,
                               width: visible.width / factor, height: visible.height / factor)
        instances.removeAll(keepingCapacity: true)
        for tile in grid.tiles(level: level, intersecting: levelRect) {
            let content = grid.contentRect(tile), slot = grid.slotOrigin(tile)
            let width = min(Double(content.maxX), extentX) - Double(content.x)
            let height = min(Double(content.maxY), extentY) - Double(content.y)
            instances.append(TileInstance(contentOrigin: SIMD2(Float(content.x), Float(content.y)),
                                          contentSize: SIMD2(Float(width), Float(height)),
                                          slotOrigin: SIMD2(Float(slot.x), Float(slot.y)),
                                          slice: UInt32(grid.slice(of: tile))))
        }
        guard !instances.isEmpty else { return }

        let levelSize = grid.levelSize(level)
        var uniforms = TileUniforms(levelToViewScale: SIMD2(frame.levelToView, frame.levelToView),
                                    levelToViewOffset: frame.offset,
                                    viewSize: SIMD2(Float(target.width), Float(target.height)),
                                    levelSize: SIMD2(Float(levelSize.width), Float(levelSize.height)),
                                    orient: frame.orient, shift: frame.shift,
                                    viewToLevelScale: SIMD2(repeating: 1 / frame.levelToView))

        if frame.hasAlpha || frame.inverseCurve != nil || frame.color != nil {
            encoder.setRenderPipelineState(context.tilePipeline(pixelFormat: target.pixelFormat, nearest: nearest,
                                                                alpha: frame.hasAlpha, curveTable: frame.inverseCurve != nil,
                                                                colorLUT: frame.color != nil))
        } else {
            encoder.setRenderPipelineState(nearest ? nearestPipeline : pipeline)
        }
        if frame.hasAlpha {
            var backdrop = transparencyParams(frame)
            encoder.setFragmentBytes(&backdrop, length: MemoryLayout<TransparencyParams>.stride, index: 1)
        }
        if let inverse = frame.inverseCurve { encoder.setFragmentTexture(inverse, index: 3) }
        if let color = frame.color { setFragmentColorCube(color, on: encoder) }
        let length = instances.count * MemoryLayout<TileInstance>.stride
        let bound: Bool = instances.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            if length <= inlineInstanceLimit {
                encoder.setVertexBytes(base, length: length, index: 0)
                return true
            }
            guard let buffer = ringBuffer(length: length, for: commandBuffer) else { return false }
            buffer.contents().copyMemory(from: base, byteCount: length)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            bufferedFrameCount += 1
            return true
        }
        guard bound else { return }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TileUniforms>.stride, index: 1)
        if nearest { encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TileUniforms>.stride, index: 0) }
        encoder.setFragmentTexture(frame.view, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }

    /// Binds a frame's colour cube for a `COLOR_LUT` fragment function: `lut` at texture 4, `from` at 5, `ColorLUTParams`
    /// at buffer 2 (the kernels take them at the same textures and buffer 3, `encodeResample`).
    func setFragmentColorCube(_ color: ColorFrame, on encoder: MTLRenderCommandEncoder) {
        var params = ColorLUTParams(mix: color.mix)
        encoder.setFragmentTexture(color.lut.texture, index: 4)
        encoder.setFragmentTexture(fromTexture(color, params), index: 5)
        encoder.setFragmentBytes(&params, length: MemoryLayout<ColorLUTParams>.stride, index: 2)
    }

    /// What the shader samples as `from`: during a transition the cube it starts from (the shared identity when there is
    /// none); otherwise unused, but bound all the same (to `lut`), as a declared texture should be.
    private func fromTexture(_ color: ColorFrame, _ params: ColorLUTParams) -> MTLTexture {
        guard params.mix < 1 else { return color.lut.texture }
        return (color.from ?? ColorLUT.identity(context: context)).texture
    }

    /// The backdrop of `frame`'s transparent pixels: `transparency`'s colours, cells of `checkerSizePt * backingScale`
    /// drawable px from the image's top-left corner on screen, so they move with the pan and keep their size at any zoom.
    /// The colours' bytes are taken in the photo's space, as the background's are: for a `.table` curve they are
    /// linearised with it, so a cell comes out as its own bytes.
    func transparencyParams(_ frame: LevelFrame) -> TransparencyParams {
        var colors = transparency.colors
        if frame.inverseCurve != nil {
            let curve = frame.curve
            func relinearised(_ c: SIMD3<Float>) -> SIMD3<Float> {
                SIMD3(curve.decode(Float(MetalContext.srgbEncode(Double(c.x)))),
                      curve.decode(Float(MetalContext.srgbEncode(Double(c.y)))),
                      curve.decode(Float(MetalContext.srgbEncode(Double(c.z)))))
            }
            colors = (relinearised(colors.0), relinearised(colors.1))
        }
        let cell = max(Double(transparency.checkerSizePt) * backingScale, 1)
        return TransparencyParams(first: SIMD4(colors.0, 1), second: SIMD4(colors.1, 1), anchor: frame.offset,
                                  invCell: Float(1 / cell))
    }

    /// `background` as `target` stores it: linear light for an `_srgb` target, which encodes it on store; its
    /// sRGB-encoded values for the unorm view a `.table` frame writes. So the bytes around the picture are the same
    /// for every photo (the layer, tagged with the photo's space, shows them in that space, as before M3b).
    func background(for target: MTLTexture) -> SIMD4<Float> {
        let c = clearColor(for: target)
        return SIMD4(Float(c.red), Float(c.green), Float(c.blue), 1)
    }

    /// `background(for:)` as a clear colour.
    func clearColor(for target: MTLTexture) -> MTLClearColor {
        if Self.unormFormat(of: target.pixelFormat) != nil { return background }
        let c = background
        return MTLClearColor(red: MetalContext.srgbEncode(c.red), green: MetalContext.srgbEncode(c.green),
                             blue: MetalContext.srgbEncode(c.blue), alpha: 1)
    }

    /// The unorm format an `_srgb` one views as; nil for any other.
    static func unormFormat(of format: MTLPixelFormat) -> MTLPixelFormat? {
        switch format {
        case .bgra8Unorm_srgb: return .bgra8Unorm
        case .rgba8Unorm_srgb: return .rgba8Unorm
        default: return nil
        }
    }

    /// The next ring slot, at least `length` bytes, reserved until `commandBuffer` completes. Waits if the GPU
    /// still reads the slot from three buffered frames ago; grows it (rarely: a bigger window or more tiles).
    /// Nil only if a buffer cannot be allocated, in which case the frame shows just the background.
    private func ringBuffer(length: Int, for commandBuffer: MTLCommandBuffer) -> MTLBuffer? {
        let index = ringIndex
        ringIndex = (ringIndex + 1) % ring.count
        let free = ringFree[index]
        free.wait()
        if (ring[index]?.length ?? 0) < length {
            // Power-of-two growth from 8 KiB, so a slowly growing window does not reallocate every frame.
            var capacity = 8192
            while capacity < length { capacity *= 2 }
            ring[index] = device.makeBuffer(length: capacity, options: [.storageModeShared, .cpuCacheModeWriteCombined])
            ring[index]?.label = "tile instances \(index)"
        }
        guard let buffer = ring[index] else {
            free.signal()
            return nil
        }
        commandBuffer.addCompletedHandler { _ in free.signal() }
        return buffer
    }
}

/// What one frame draws: the level, its sampling view and where its pixels land in the view. Shared by all paths,
/// so they agree on the level and the geometry to the last bit. The level is stored, the transform oriented: view px
/// v is oriented level position `(v - offset) / levelToView`, which `orient` and `shift` map to the stored one.
struct LevelFrame {
    let grid: TileGrid
    let transform: ViewTransform
    let orientation: ImageOrientation
    let level: Int
    /// The level's `bgra8Unorm_srgb` view: reads and samples return linear light (premultiplied, with `hasAlpha`).
    let view: MTLTexture
    /// `TiledImage.hasAlpha` as of the views: the frame takes the `HAS_ALPHA` pipelines.
    let hasAlpha: Bool
    /// The photo's transfer curve and, for a `.table` one, its inverse table: the frame takes the `CURVE_TABLE`
    /// pipelines (nil: `.srgb`, the `_srgb` target encodes).
    private(set) var curve: ColorCurve
    private(set) var inverseCurve: MTLTexture?
    /// The frame's colour cube (`TileRenderer.color`, not the identity): the frame takes the `COLOR_LUT` pipelines.
    var color: ColorFrame?
    /// Image px per level px, `2^level`.
    let factor: Double
    /// The image's stored extent in level px. A level is ceil(size / 2^L) px, so at an odd size its last pixel
    /// overhangs the image; drawing stops at the image's exact extent instead, so the drawn area is the transform's
    /// image rect. A mirrored axis is mirrored about it (`shift`), not about the level's edge, which would move the
    /// picture by the overhang.
    let extent: (x: Double, y: Double)
    /// The orientation for the shaders: `ImageOrientation.matrix` and its `translation` of `extent` (stored level px).
    let orient: SIMD4<Int32>
    let shift: SIMD2<Float>
    /// Level px p lands on view px `p * levelToView + offset`, the offset taken from the transform itself (view
    /// position of image px 0) so the renderer and hit-testing agree to the last bit.
    let levelToView: Float
    let offset: SIMD2<Float>

    /// Nil when no level is resident. The resident views are copied once: an upload or eviction swapping levels
    /// meanwhile cannot change what this frame draws. When the level the scale needs is not resident, the finest
    /// resident one is stretched instead (`scale * 2^level` handles any level), so a zoomed-in preview is blurry
    /// rather than empty.
    init?(image: TiledImage, transform: ViewTransform, orientation: ImageOrientation) {
        let grid = image.grid
        let (views, hasAlpha, tables) = image.residentState()
        guard let finest = views.firstIndex(where: { $0 != nil }) else { return nil }
        let level = grid.drawnLevel(forScale: transform.drawnScale, finestResident: finest)
        guard level < views.count, let view = views[level] else { return nil }
        self.grid = grid
        self.transform = transform
        self.orientation = orientation
        self.level = level
        self.view = view
        self.hasAlpha = hasAlpha
        curve = tables?.curve ?? .srgb
        inverseCurve = tables?.inverse
        factor = Double(1 << level)
        extent = (Double(grid.imageSize.width) / factor, Double(grid.imageSize.height) / factor)
        let m = orientation.matrix, t = orientation.translation(storedSize: CGSize(width: extent.x, height: extent.y))
        orient = SIMD4(Int32(m.a), Int32(m.b), Int32(m.c), Int32(m.d))
        shift = SIMD2(Float(t.x), Float(t.y))
        let origin = transform.viewPoint(forImage: .zero)
        levelToView = Float(transform.drawnScale * factor)
        offset = SIMD2(Float(origin.x), Float(origin.y))
    }

    /// Draws the frame as an sRGB-curve one (when its target has no unorm view).
    mutating func dropCurve() {
        curve = .srgb
        inverseCurve = nil
    }

    /// The image's extent in oriented level px (`extent`, swapped for orientations 5...8): its view rect is
    /// `offset + orientedExtent * levelToView`.
    var orientedExtent: SIMD2<Float> {
        let e = SIMD2(Float(extent.x), Float(extent.y))
        return orientation.swapsAxes ? SIMD2(e.y, e.x) : e
    }
}
