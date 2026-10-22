import LoupeCore
import Metal
import MetalFX

/// The MetalFX path's per-view-size state (M3a spec §3.5): the spatial scaler and its two textures, each the size of
/// the view (~85 MB on 6K), so the renderer holds them only while frames use MetalFX; and a third, `secondOutput`, only
/// while those frames are of a photo with alpha over the checkerboard.
final class MetalFXStage {
    let width: Int
    let height: Int
    let scaler: MTLFXSpatialScaler
    /// The level's visible region 1:1 (texel i is level px origin + i), the image's edge pixels repeated around it;
    /// for a photo with alpha composited onto one backdrop colour.
    let input: MTLTexture
    /// The scaler's result: the input's content region stretched over the whole texture (for a photo with alpha, the
    /// run over the backdrop's first colour).
    let output: MTLTexture
    /// The run over the checkerboard's second colour (Shaders, metalfxFragment): made by the first frame that needs it,
    /// released by the first MetalFX frame that does not.
    var secondOutput: MTLTexture?
    private let device: MTLDevice
    let composePass = MTLRenderPassDescriptor()
    let drawPass = MTLRenderPassDescriptor()

    /// Nil when the scaler or a texture cannot be made.
    init?(device: MTLDevice, width: Int, height: Int) {
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = width
        d.inputHeight = height
        d.outputWidth = width
        d.outputHeight = height
        d.colorTextureFormat = .bgra8Unorm_srgb
        d.outputTextureFormat = .bgra8Unorm_srgb
        d.colorProcessingMode = .perceptual
        guard let scaler = d.makeSpatialScaler(device: device) else { return nil }
        guard let input = Self.texture(device, width, height, scaler.colorTextureUsage.union(.renderTarget), "metalfx input"),
              let output = Self.texture(device, width, height, scaler.outputTextureUsage.union(.shaderRead),
                                        "metalfx output") else { return nil }
        scaler.colorTexture = input
        scaler.outputTexture = output
        self.device = device
        self.width = width
        self.height = height
        self.scaler = scaler
        self.input = input
        self.output = output
        let compose = composePass.colorAttachments[0]!
        compose.texture = input
        compose.loadAction = .dontCare   // the compose pass writes every texel the scaler reads
        compose.storeAction = .store
        let draw = drawPass.colorAttachments[0]!
        draw.loadAction = .dontCare   // the full-view triangle writes every pixel
        draw.storeAction = .store
    }

    /// `secondOutput`, made if it is not there yet; nil when it cannot be made.
    func makeSecondOutput() -> MTLTexture? {
        if secondOutput == nil {
            secondOutput = Self.texture(device, width, height, scaler.outputTextureUsage.union(.shaderRead),
                                        "metalfx output, second checker colour")
        }
        return secondOutput
    }

    private static func texture(_ device: MTLDevice, _ width: Int, _ height: Int, _ usage: MTLTextureUsage,
                                _ label: String) -> MTLTexture? {
        let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
                                                         mipmapped: false)
        t.storageMode = .private
        t.usage = usage
        let made = device.makeTexture(descriptor: t)
        made?.label = label
        return made
    }
}

extension TileRenderer {
    /// The MetalFX path, three passes: `metalfxComposeFragment`, composing the level 1:1 and oriented into the input
    /// from the whole oriented level px under the view's top-left corner, reads clamped into the level (so the image's
    /// edge pixels repeat around it and no background is filtered into the image); the scaler, magnifying
    /// `ceil(view / m) + 1` input texels per axis onto the whole output; `metalfxFragment`, drawing the output into
    /// `target` through one bilinear sample that maps each view px back to the right output position, so the pan's
    /// fraction and the content's rounding move nothing, and cutting to the background by pixel centre. A photo with
    /// alpha is composed over a backdrop colour; over the checkerboard compose and scaler run twice, once per cell
    /// colour, into `output` and `secondOutput` (Shaders, metalfxFragment). False when the scaler, its textures (the
    /// second output included) or a compose pass's encoder cannot be made; the caller then draws the frame by another
    /// path, which writes every pixel of `target`. Nothing is encoded then, except when the second run's compose encoder
    /// fails after the first run: those passes only fill the stage's textures. A scaler, textures or second output that
    /// could not be made is not retried at that view size while the stage lives (frames keep the fallback, without an
    /// ~85 MB allocation each), and the context hears of it, so the stats line names what is drawn.
    ///
    /// With a cut (a page of a spread, `encode`) compose and scaler run over the whole view as for any frame, and the
    /// final pass cuts the picture to it; a region that does not clear loads `target` and draws only within the cut.
    func encodeMetalFX(_ frame: LevelFrame, commandBuffer: MTLCommandBuffer, target: MTLTexture,
                       region: Region = .whole) -> Bool {
        let clip = region.writes(target)
        let width = target.width, height = target.height
        guard width > 0, height > 0 else { return true }
        if metalFX.map({ $0.width != width || $0.height != height }) ?? true {
            metalFX = nil   // a view-size change: let the old textures go before making the new ones
            guard metalFXFailedSize != SIMD2(width, height) else { return false }
            metalFX = failMetalFXStage ? nil : MetalFXStage(device: context.device, width: width, height: height)
            metalFXFailedSize = metalFX == nil ? SIMD2(width, height) : nil
            metalFXSecondFailedSize = nil   // a new size may fit the second output
            noteMetalFXStage(made: metalFX != nil)
        }
        guard let stage = metalFX else { return false }
        // Over the checkerboard, the second run's output; a solid backdrop or an opaque photo lets it go.
        let colors = transparency.colors
        let twoRuns = frame.hasAlpha && colors.0 != colors.1
        if twoRuns {
            if clip == nil { metalFXFirst.secondOutput = true } else { metalFXOthers.secondOutput = true }
        }
        if !twoRuns {
            // Kept while another page of the frame (or of the frame before, for the first page) runs twice.
            if !(clip == nil ? metalFXOthersBefore.secondOutput : metalFXFirst.secondOutput) { stage.secondOutput = nil }
        } else if stage.secondOutput == nil {
            guard metalFXSecondFailedSize != SIMD2(width, height) else {
                // Still failed at this size: this frame falls back too, even if a frame between drew MetalFX.
                if lastMetalFXNote != false { noteMetalFXStage(made: false) }
                return false
            }
            if failMetalFXSecondOutput || stage.makeSecondOutput() == nil {
                metalFXSecondFailedSize = SIMD2(width, height)
                noteMetalFXStage(made: false)
                return false
            }
        }
        // This frame draws MetalFX (an opaque photo, say, after a second output failed): the stats line names it again.
        if lastMetalFXNote == false { noteMetalFXStage(made: true) }

        // The same Float geometry the other paths draw with.
        let m = Double(frame.levelToView)
        let offset = SIMD2(Double(frame.offset.x), Double(frame.offset.y))
        // The input holds whole stored px, and on a mirrored axis oriented px i is stored px levelSize - 1 - i: that
        // grid starts `lead` = levelSize - extent before the image's oriented origin (the overhang of an odd size's
        // last level px, 0 on level 0), so oriented level position u is input grid position u + lead.
        let size = frame.grid.levelSize(frame.level), o = frame.orientation
        let whole = o.translation(storedSize: CGSize(width: size.width, height: size.height))
        let exact = o.translation(storedSize: CGSize(width: frame.extent.x, height: frame.extent.y))
        let gap = SIMD2(whole.x - exact.x, whole.y - exact.y)
        let lead = o.swapsAxes ? SIMD2(gap.y, gap.x) : gap
        let origin = SIMD2((-offset.x / m + lead.x).rounded(.down), (-offset.y / m + lead.y).rounded(.down))
        // Level px origin ... origin + view / m + 1 cover the view; at m close to 1 that can exceed the input by one
        // texel, and the last view column or row then samples the output's clamped edge.
        let content = (x: min(width, Int((Double(width) / m).rounded(.up)) + 1),
                       y: min(height, Int((Double(height) / m).rounded(.up)) + 1))

        let last = o.translation(storedSize: CGSize(width: size.width - 1, height: size.height - 1))
        var compose = MetalFXComposeParams(origin: SIMD2(Int32(origin.x), Int32(origin.y)),
                                           levelSize: SIMD2(UInt32(size.width), UInt32(size.height)),
                                           columns: UInt32(frame.grid.columns(frame.level)),
                                           shift: SIMD2(Int32(last.x), Int32(last.y)), orient: frame.orient)
        let backdrop = transparencyParams(frame)
        // One run, or one per checker colour: the compose pass composites onto the run's colour (its `first`), and the
        // scaler magnifies the input into the run's output. The second run's compose pass overwrites the input after
        // the first run's scaler has read it (Metal orders the two through the tracked texture).
        var runs = [(backdrop, stage.output)]
        if twoRuns, let second = stage.secondOutput {
            var swapped = backdrop
            swapped.first = backdrop.second
            runs.append((swapped, second))
        }
        stage.scaler.inputContentWidth = content.x
        stage.scaler.inputContentHeight = content.y
        for (runBackdrop, output) in runs {
            guard let composer = commandBuffer.makeRenderCommandEncoder(descriptor: stage.composePass) else {
                noteMetalFXStage(made: false)   // this frame only: the next one tries again (and reports MetalFX)
                return false
            }
            composer.label = "metalfx compose"
            composer.setRenderPipelineState(context.metalFXPipeline(pixelFormat: .bgra8Unorm_srgb, compose: true,
                                                                    alpha: frame.hasAlpha, colorLUT: frame.color != nil))
            if frame.hasAlpha {
                var colour = runBackdrop
                composer.setFragmentBytes(&colour, length: MemoryLayout<TransparencyParams>.stride, index: 1)
                // A photo with alpha is corrected here, before it is composited (Shaders, metalfxFragment).
                if let color = frame.color { setFragmentColorCube(color, on: composer) }
            }
            // The content region and a 2-texel margin, in case the scaler's taps reach past it: they get edge pixels too.
            composer.setScissorRect(MTLScissorRect(x: 0, y: 0, width: min(width, content.x + 2),
                                                   height: min(height, content.y + 2)))
            composer.setFragmentTexture(frame.view, index: 0)
            composer.setFragmentBytes(&compose, length: MemoryLayout<MetalFXComposeParams>.stride, index: 0)
            composer.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            composer.endEncoding()
            stage.scaler.outputTexture = output
            stage.scaler.encode(commandBuffer: commandBuffer)
        }

        // View position v is oriented level position (v - offset) / m, input position that plus lead minus origin,
        // output position that times output / content.
        let stretch = SIMD2(Double(width) / Double(content.x), Double(height) / Double(content.y))
        var imageMin = frame.offset
        var imageMax = imageMin + frame.orientedExtent * frame.levelToView
        if let cut = region.cut {   // the viewport ends the picture (its edge, read clamped, repeats up to it)
            imageMin = SIMD2(Float(cut.x), Float(cut.y))
            imageMax = SIMD2(Float(cut.x + cut.width), Float(cut.y + cut.height))
        }
        var params = MetalFXParams(viewToOutputScale: SIMD2<Float>(stretch / m),
                                   viewToOutputOffset: SIMD2<Float>((-offset / m + lead - origin) * stretch),
                                   imageMin: imageMin, imageMax: imageMax, background: background(for: target))
        let draw = stage.drawPass.colorAttachments[0]!
        draw.texture = target
        draw.loadAction = clip == nil ? .dontCare : .load   // the full-view triangle writes every pixel, or the clip's
        let made = commandBuffer.makeRenderCommandEncoder(descriptor: stage.drawPass)
        draw.texture = nil   // do not keep the drawable alive until the next frame
        guard let encoder = made else {   // the scaler ran, nothing drew its output: at least clear the drawable
            if clip == nil { encodeTiles(nil, nearest: false, commandBuffer: commandBuffer, target: target) }
            return true
        }
        encoder.label = "metalfx draw"
        if let clip { encoder.setScissorRect(clip) }
        encoder.setRenderPipelineState(context.metalFXPipeline(pixelFormat: target.pixelFormat, alpha: frame.hasAlpha,
                                                               curveTable: frame.inverseCurve != nil,
                                                               colorLUT: frame.color != nil))
        encoder.setFragmentTexture(stage.output, index: 0)
        if let inverse = frame.inverseCurve { encoder.setFragmentTexture(inverse, index: 3) }
        // An opaque photo is corrected here, after the scaler.
        if !frame.hasAlpha, let color = frame.color { setFragmentColorCube(color, on: encoder) }
        encoder.setFragmentBytes(&params, length: MemoryLayout<MetalFXParams>.stride, index: 0)
        if frame.hasAlpha {
            var cells = backdrop
            encoder.setFragmentTexture(stage.secondOutput ?? stage.output, index: 1)
            encoder.setFragmentBytes(&cells, length: MemoryLayout<TransparencyParams>.stride, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    /// Tells the context whether MetalFX could be set up (`MetalContext.drawnMode`), and remembers it.
    private func noteMetalFXStage(made: Bool) {
        lastMetalFXNote = made
        context.noteMetalFXStage(made: made)
    }
}
