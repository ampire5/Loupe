import LoupeCore
import Metal
import Testing
@testable import LoupeRender

// MARK: - Compilation and Swift/MSL layout agreement

@Test func pipelinesCompile() {
    let c = MetalContext.shared
    #expect(c.downsample.threadExecutionWidth > 0)
    _ = c.tilePipeline(pixelFormat: .bgra8Unorm_srgb)
    _ = c.tilePipeline(pixelFormat: .bgra8Unorm)
}

@Test func tilePipelineIsCachedPerFormat() {
    let c = MetalContext.shared
    #expect(c.tilePipeline(pixelFormat: .bgra8Unorm_srgb) === c.tilePipeline(pixelFormat: .bgra8Unorm_srgb))
    #expect(c.tilePipeline(pixelFormat: .bgra8Unorm_srgb) !== c.tilePipeline(pixelFormat: .bgra8Unorm))
}

/// The MSL structs are laid out by the Metal compiler; these sizes are what it produces for them
/// (float2/uint2 align to 8, so `TileInstance` gets 4 bytes of tail padding).
@Test func shaderStructLayoutsMatchMSL() {
    #expect(MemoryLayout<DownsampleParams>.size == 24 && MemoryLayout<DownsampleParams>.stride == 24)
    #expect(MemoryLayout<DownsampleParams>.alignment == 8)
    #expect(MemoryLayout<DownsampleParams>.offset(of: \.srcColumns) == 16)
    #expect(MemoryLayout<DownsampleParams>.offset(of: \.dstColumns) == 20)

    #expect(MemoryLayout<TileInstance>.stride == 32 && MemoryLayout<TileInstance>.alignment == 8)
    #expect(MemoryLayout<TileInstance>.offset(of: \.slotOrigin) == 16)
    #expect(MemoryLayout<TileInstance>.offset(of: \.slice) == 24)

    // int4 aligns to 16, so the struct does too.
    #expect(MemoryLayout<TileUniforms>.size == 64 && MemoryLayout<TileUniforms>.stride == 64)
    #expect(MemoryLayout<TileUniforms>.alignment == 16)
    #expect(MemoryLayout<TileUniforms>.offset(of: \.levelSize) == 24)
    #expect(MemoryLayout<TileUniforms>.offset(of: \.orient) == 32)
    #expect(MemoryLayout<TileUniforms>.offset(of: \.shift) == 48)

    // float4 aligns to 16, so the struct does too and `background` starts at 48.
    #expect(MemoryLayout<ResampleParams>.size == 96 && MemoryLayout<ResampleParams>.stride == 96)
    #expect(MemoryLayout<ResampleParams>.alignment == 16)
    #expect(MemoryLayout<ResampleParams>.offset(of: \.levelToViewOffset) == 8)
    #expect(MemoryLayout<ResampleParams>.offset(of: \.levelSize) == 16)
    #expect(MemoryLayout<ResampleParams>.offset(of: \.extent) == 24)
    #expect(MemoryLayout<ResampleParams>.offset(of: \.viewSize) == 32)
    #expect(MemoryLayout<ResampleParams>.offset(of: \.columns) == 40)
    #expect(MemoryLayout<ResampleParams>.offset(of: \.antiringing) == 44)
    #expect(MemoryLayout<ResampleParams>.offset(of: \.background) == 48)
    #expect(MemoryLayout<ResampleParams>.offset(of: \.orient) == 64)
    #expect(MemoryLayout<ResampleParams>.offset(of: \.shift) == 80)
    #expect(MemoryLayout<MetalFXParams>.size == 48 && MemoryLayout<MetalFXParams>.alignment == 16)
    #expect(MemoryLayout<MetalFXParams>.offset(of: \.background) == 32)
    #expect(MemoryLayout<MetalFXComposeParams>.size == 48 && MemoryLayout<MetalFXComposeParams>.stride == 48)
    #expect(MemoryLayout<MetalFXComposeParams>.alignment == 16)
    #expect(MemoryLayout<MetalFXComposeParams>.offset(of: \.columns) == 16)
    #expect(MemoryLayout<MetalFXComposeParams>.offset(of: \.shift) == 24)
    #expect(MemoryLayout<MetalFXComposeParams>.offset(of: \.orient) == 32)
    #expect(MemoryLayout<PanPillParams>.size == 80 && MemoryLayout<PanPillParams>.stride == 80)
    #expect(MemoryLayout<PanPillParams>.alignment == 16)
    #expect(MemoryLayout<PanPillParams>.offset(of: \.radius) == 16)
    #expect(MemoryLayout<PanPillParams>.offset(of: \.encoded) == 28)
    #expect(MemoryLayout<PanPillParams>.offset(of: \.origin) == 32)
    #expect(MemoryLayout<PanPillParams>.offset(of: \.fill) == 48)
    #expect(MemoryLayout<PanPillParams>.offset(of: \.line) == 64)
    #expect(MemoryLayout<TransparencyParams>.size == 48 && MemoryLayout<TransparencyParams>.alignment == 16)
    #expect(MemoryLayout<TransparencyParams>.offset(of: \.anchor) == 32)
    #expect(MemoryLayout<TransparencyParams>.offset(of: \.invCell) == 40)
    #expect(MemoryLayout<AlphaUploadParams>.size == 16 && MemoryLayout<AlphaUploadParams>.alignment == 8)
    #expect(MemoryLayout<AlphaUploadParams>.offset(of: \.bytesPerRow) == 12)
}

/// Eight pipelines (four kernels, up and down), each compiled once and able to run the kernel's full 16 x 16
/// threadgroup, which its barriers need.
@Test func resamplePipelinesAreCachedPerKernelAndDirection() {
    let c = MetalContext.shared
    var states: [ObjectIdentifier] = []
    for kernel in ResampleKernel.allCases {
        for upscale in [false, true] {
            let state = c.resamplePipeline(kernel: kernel, upscale: upscale)
            #expect(state === c.resamplePipeline(kernel: kernel, upscale: upscale))
            #expect(state.maxTotalThreadsPerThreadgroup >= 256)
            states.append(ObjectIdentifier(state))
        }
    }
    #expect(Set(states).count == 8)
}

// MARK: - GPU helpers (hand-filled slots; real tile upload is Task 11)

private let slot = 528
private let poison: [UInt8] = [0, 0, 255, 255]          // opaque red, BGRA

/// A level's slot array: the bgra8Unorm storage plus its bgra8Unorm_srgb view.
private func makeSlots(_ c: MetalContext, count: Int) -> (unorm: MTLTexture, srgb: MTLTexture) {
    let d = MTLTextureDescriptor()
    d.textureType = .type2DArray
    d.pixelFormat = .bgra8Unorm
    d.width = slot
    d.height = slot
    d.arrayLength = count
    d.storageMode = .shared
    d.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
    let t = c.device.makeTexture(descriptor: d)!
    return (t, t.makeTextureView(pixelFormat: .bgra8Unorm_srgb)!)
}

/// Writes BGRA bytes into a rectangle of one slot.
private func fill(_ t: MTLTexture, slice: Int, x: Int, y: Int, width: Int, height: Int, bytes: [UInt8]) {
    precondition(bytes.count == width * height * 4)
    bytes.withUnsafeBytes {
        t.replace(region: MTLRegionMake2D(x, y, width, height), mipmapLevel: 0, slice: slice,
                  withBytes: $0.baseAddress!, bytesPerRow: width * 4, bytesPerImage: width * height * 4)
    }
}

private func fillSlot(_ t: MTLTexture, slice: Int, pixel: [UInt8]) {
    fill(t, slice: slice, x: 0, y: 0, width: slot, height: slot,
         bytes: Array([[UInt8]](repeating: pixel, count: slot * slot).joined()))
}

private func gray(_ v: UInt8, alpha: UInt8 = 255) -> [UInt8] { [v, v, v, alpha] }

/// BGRA bytes of one texel.
private func texel(_ t: MTLTexture, slice: Int = 0, _ x: Int, _ y: Int) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 4)
    p.withUnsafeMutableBytes {
        t.getBytes($0.baseAddress!, bytesPerRow: 4, bytesPerImage: 4,
                   from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0, slice: slice)
    }
    return p
}

private func close(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 1) -> Bool {
    zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
}

private func runDownsample(_ c: MetalContext, src: MTLTexture, dst: MTLTexture, params: DownsampleParams) {
    var p = params
    let cb = c.queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(c.downsample)
    enc.setTexture(src, index: 0)
    enc.setTexture(dst, index: 1)
    enc.setBytes(&p, length: MemoryLayout<DownsampleParams>.stride, index: 0)
    let w = c.downsample.threadExecutionWidth
    enc.dispatchThreads(MTLSize(width: slot, height: slot, depth: dst.arrayLength),
                        threadsPerThreadgroup: MTLSize(width: w, height: c.downsample.maxTotalThreadsPerThreadgroup / w, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    #expect(cb.status == .completed)
}

// MARK: - downsample2x

/// 3×2 source → 2×1 destination in one tile. Averages in linear light (black+white → sRGB 188,
/// not 128), keeps alpha linear, reuses the odd last source column, clamps apron texels to the
/// destination level (the far apron must average both source rows, not just the last) and never
/// reads the (poisoned) source apron.
@Test func downsampleAveragesInLinearLightAndClampsToLevel() {
    let c = MetalContext.shared
    let src = makeSlots(c, count: 1), dst = makeSlots(c, count: 1)
    fillSlot(src.unorm, slice: 0, pixel: poison)
    let content: [[UInt8]] = [gray(0, alpha: 0), gray(255), gray(255),
                              gray(255), gray(0), gray(0)]
    fill(src.unorm, slice: 0, x: 8, y: 8, width: 3, height: 2, bytes: Array(content.joined()))

    runDownsample(c, src: src.srgb, dst: dst.unorm,
                  params: DownsampleParams(srcLevelSize: [3, 2], dstLevelSize: [2, 1], srcColumns: 1, dstColumns: 1))

    let mixed = [188, 188, 188, 191].map(UInt8.init)    // linear 0.5 → sRGB 0.7354; alpha (0+3·255)/4
    #expect(close(texel(dst.unorm, 8, 8), mixed))        // level (0, 0)
    #expect(close(texel(dst.unorm, 9, 8), gray(188)))    // level (1, 0): source x 2 and 3→2
    #expect(close(texel(dst.unorm, 0, 0), mixed))        // apron clamps to level (0, 0)
    #expect(close(texel(dst.unorm, 527, 527), gray(188))) // far apron clamps to level (1, 0)
}

/// 520×1 source (two tiles) → 260×1 destination (one tile): destination x 256 reads source
/// 512/513, which live in tile 1 — not in tile 0's apron, which is filled with a different value here.
/// Uniform greys also check the sRGB decode → linear → exact encode round trip.
@Test func downsampleReadsEachSourcePixelFromItsOwnTile() {
    let c = MetalContext.shared
    let src = makeSlots(c, count: 2), dst = makeSlots(c, count: 1)
    fillSlot(src.unorm, slice: 0, pixel: gray(60))
    fillSlot(src.unorm, slice: 1, pixel: gray(200))

    runDownsample(c, src: src.srgb, dst: dst.unorm,
                  params: DownsampleParams(srcLevelSize: [520, 1], dstLevelSize: [260, 1], srcColumns: 2, dstColumns: 1))

    #expect(close(texel(dst.unorm, 8 + 255, 8), gray(60)))
    #expect(close(texel(dst.unorm, 8 + 256, 8), gray(200)))
    #expect(close(texel(dst.unorm, 8 + 259, 8), gray(200)))
}

// MARK: - tileVertex / tileFragment

private func drawTile(_ c: MetalContext, slots: MTLTexture, instance: TileInstance, uniforms: TileUniforms,
                      viewWidth: Int, viewHeight: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: viewWidth,
                                                     height: viewHeight, mipmapped: false)
    d.storageMode = .shared
    d.usage = [.renderTarget]
    let target = c.device.makeTexture(descriptor: d)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 1, alpha: 1)
    pass.colorAttachments[0].storeAction = .store
    var i = instance, u = uniforms
    let cb = c.queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
    enc.setRenderPipelineState(c.tilePipeline(pixelFormat: .bgra8Unorm_srgb))
    enc.setVertexBytes(&i, length: MemoryLayout<TileInstance>.stride, index: 0)
    enc.setVertexBytes(&u, length: MemoryLayout<TileUniforms>.stride, index: 1)
    enc.setFragmentTexture(slots, index: 0)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    #expect(cb.status == .completed)
    return target
}

/// A 4×2 level in slice 1, drawn 1:1 at view offset (2, 3): every level pixel lands on one view
/// pixel unchanged (texel centres, so no filtering), row 0 on top, clear colour around it.
@Test func tileDrawMapsLevelPixelsToViewPixels() {
    let c = MetalContext.shared
    let slots = makeSlots(c, count: 2)
    fillSlot(slots.unorm, slice: 1, pixel: poison)
    func value(_ x: Int, _ y: Int) -> UInt8 { UInt8(40 + 50 * x + 20 * y) }
    var content: [UInt8] = []
    for y in 0..<2 { for x in 0..<4 { content += gray(value(x, y)) } }
    fill(slots.unorm, slice: 1, x: 8, y: 8, width: 4, height: 2, bytes: content)

    let view = drawTile(c, slots: slots.srgb,
                        instance: TileInstance(contentOrigin: [0, 0], contentSize: [4, 2], slotOrigin: [-8, -8], slice: 1),
                        uniforms: TileUniforms(levelToViewScale: [1, 1], levelToViewOffset: [2, 3], viewSize: [16, 8], levelSize: [4, 2],
                                               orient: [1, 0, 0, 1], shift: [0, 0], viewToLevelScale: [1, 1]),
                        viewWidth: 16, viewHeight: 8)

    for y in 0..<2 { for x in 0..<4 { #expect(close(texel(view, 2 + x, 3 + y), gray(value(x, y))), "level (\(x), \(y))") } }
    let clear: [UInt8] = [255, 0, 0, 255]
    #expect(texel(view, 1, 3) == clear && texel(view, 6, 3) == clear)
    #expect(texel(view, 2, 2) == clear && texel(view, 2, 5) == clear)
}

/// Zoomed 4× into a 2×2 level whose apron is poisoned: view pixels near the level edge map to
/// level positions within half a pixel of it, which must clamp to the edge texel centre.
@Test func tileDrawClampsToLevelSoApronIsNeverRead() {
    let c = MetalContext.shared
    let slots = makeSlots(c, count: 1)
    fillSlot(slots.unorm, slice: 0, pixel: poison)
    fill(slots.unorm, slice: 0, x: 8, y: 8, width: 2, height: 2, bytes: Array([[UInt8]](repeating: gray(100), count: 4).joined()))

    let view = drawTile(c, slots: slots.srgb,
                        instance: TileInstance(contentOrigin: [0, 0], contentSize: [2, 2], slotOrigin: [-8, -8], slice: 0),
                        uniforms: TileUniforms(levelToViewScale: [4, 4], levelToViewOffset: [0, 0], viewSize: [8, 8], levelSize: [2, 2],
                                               orient: [1, 0, 0, 1], shift: [0, 0], viewToLevelScale: [0.25, 0.25]),
                        viewWidth: 8, viewHeight: 8)

    for (x, y) in [(0, 0), (7, 0), (0, 7), (7, 7), (3, 4)] { #expect(close(texel(view, x, y), gray(100)), "view (\(x), \(y))") }
}

/// The same layouts as the Metal compiler reports them, so the Swift mirrors are checked against
/// the real MSL structs rather than against hand-computed numbers.
@Test func shaderStructLayoutsMatchCompilerReflection() throws {
    let c = MetalContext.shared
    func members(_ b: MTLBufferBinding) -> [String: Int] {
        let s = b.bufferStructType ?? b.bufferPointerType?.elementStructType()
        return Dictionary(uniqueKeysWithValues: (s?.members ?? []).map { ($0.name, $0.offset) })
    }

    var computeReflection: MTLComputePipelineReflection?
    _ = try c.device.makeComputePipelineState(function: c.library.makeFunction(name: "downsample2x")!,
                                              options: [.bindingInfo, .bufferTypeInfo], reflection: &computeReflection)
    let params = try #require(computeReflection?.bindings.first { $0.name == "p" } as? MTLBufferBinding)
    #expect(params.bufferDataSize == MemoryLayout<DownsampleParams>.stride)
    #expect(members(params) == ["srcLevelSize": 0, "dstLevelSize": 8, "srcColumns": 16, "dstColumns": 20])

    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = c.library.makeFunction(name: "tileVertex")
    d.fragmentFunction = MetalContext.function(c.library, "tileFragment", alpha: true)
    d.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
    var renderReflection: MTLRenderPipelineReflection?
    _ = try c.device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &renderReflection)
    let bindings = renderReflection?.vertexBindings ?? []
    let instances = try #require(bindings.first { $0.name == "instances" } as? MTLBufferBinding)
    let uniforms = try #require(bindings.first { $0.name == "u" } as? MTLBufferBinding)
    #expect(instances.index == 0 && uniforms.index == 1)
    #expect(instances.bufferDataSize == MemoryLayout<TileInstance>.stride)
    #expect(members(instances) == ["contentOrigin": 0, "contentSize": 8, "slotOrigin": 16, "slice": 24])
    #expect(uniforms.bufferDataSize == MemoryLayout<TileUniforms>.stride)
    #expect(members(uniforms) == ["levelToViewScale": 0, "levelToViewOffset": 8, "viewSize": 16, "levelSize": 24,
                                  "orient": 32, "shift": 48, "viewToLevelScale": 56])
    let backdrop = try #require(renderReflection?.fragmentBindings.first { $0.name == "t" } as? MTLBufferBinding)
    let backdropMembers = ["first": 0, "second": 16, "anchor": 32, "invCell": 40, "pad": 44]
    #expect(backdrop.index == 1 && backdrop.bufferDataSize == MemoryLayout<TransparencyParams>.stride)
    #expect(members(backdrop) == backdropMembers)

    var resampleReflection: MTLComputePipelineReflection?
    _ = try c.device.makeComputePipelineState(function: MetalContext.resampleFunction(c.library, kernel: .lanczos3,
                                                                                      upscale: true, alpha: true),
                                              options: [.bindingInfo, .bufferTypeInfo], reflection: &resampleReflection)
    let resampleBackdrop = try #require(resampleReflection?.bindings.first { $0.name == "t" } as? MTLBufferBinding)
    #expect(resampleBackdrop.index == 2 && members(resampleBackdrop) == backdropMembers)
    let resample = try #require(resampleReflection?.bindings.first { $0.name == "p" } as? MTLBufferBinding)
    #expect(resample.index == 0)
    #expect(resample.bufferDataSize == MemoryLayout<ResampleParams>.stride)
    #expect(members(resample) == ["levelToViewScale": 0, "pad0": 4, "levelToViewOffset": 8, "levelSize": 16, "extent": 24,
                                  "viewSize": 32, "columns": 40, "antiringing": 44, "background": 48, "orient": 64,
                                  "shift": 80, "pad1": 88])

    let fx = MTLRenderPipelineDescriptor()
    fx.vertexFunction = c.library.makeFunction(name: "metalfxVertex")
    fx.fragmentFunction = MetalContext.function(c.library, "metalfxFragment", alpha: true)
    fx.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
    var fxReflection: MTLRenderPipelineReflection?
    _ = try c.device.makeRenderPipelineState(descriptor: fx, options: [.bindingInfo, .bufferTypeInfo], reflection: &fxReflection)
    let fxParams = try #require(fxReflection?.fragmentBindings.first { $0.name == "p" } as? MTLBufferBinding)
    #expect(fxParams.index == 0 && fxParams.bufferDataSize == MemoryLayout<MetalFXParams>.stride)
    #expect(members(fxParams) == ["viewToOutputScale": 0, "viewToOutputOffset": 8, "imageMin": 16, "imageMax": 24,
                                  "background": 32])
    let fxBackdrop = try #require(fxReflection?.fragmentBindings.first { $0.name == "t" } as? MTLBufferBinding)
    #expect(fxBackdrop.index == 1 && members(fxBackdrop) == backdropMembers)

    let compose = MTLRenderPipelineDescriptor()
    compose.vertexFunction = c.library.makeFunction(name: "metalfxVertex")
    compose.fragmentFunction = MetalContext.function(c.library, "metalfxComposeFragment", alpha: false)
    compose.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
    var composeReflection: MTLRenderPipelineReflection?
    _ = try c.device.makeRenderPipelineState(descriptor: compose, options: [.bindingInfo, .bufferTypeInfo],
                                             reflection: &composeReflection)
    let composeParams = try #require(composeReflection?.fragmentBindings.first { $0.name == "p" } as? MTLBufferBinding)
    #expect(composeParams.index == 0 && composeParams.bufferDataSize == MemoryLayout<MetalFXComposeParams>.stride)
    #expect(members(composeParams) == ["origin": 0, "levelSize": 8, "columns": 16, "pad0": 20, "shift": 24,
                                       "orient": 32])

    var uploadReflection: MTLComputePipelineReflection?
    _ = try c.device.makeComputePipelineState(function: c.library.makeFunction(name: "uploadPremultipliedLinear")!,
                                              options: [.bindingInfo, .bufferTypeInfo], reflection: &uploadReflection)
    let upload = try #require(uploadReflection?.bindings.first { $0.name == "p" } as? MTLBufferBinding)
    #expect(upload.index == 1 && upload.bufferDataSize == MemoryLayout<AlphaUploadParams>.stride)
    #expect(members(upload) == ["levelSize": 0, "columns": 8, "bytesPerRow": 12])
}

@Test func curveTableVariantsBindTheInverseTableAtTexture3() throws {
    // Every CURVE_TABLE function takes its inverse table at texture 3, where TileRenderer binds it.
    let c = MetalContext.shared
    var compute: MTLComputePipelineReflection?
    _ = try c.device.makeComputePipelineState(function: MetalContext.resampleFunction(c.library, kernel: .lanczos3,
                                                                                      upscale: false, curveTable: true),
                                              options: [.bindingInfo], reflection: &compute)
    #expect(compute?.bindings.first { $0.name == "inverse" }?.index == 3)
    _ = try c.device.makeComputePipelineState(function: MetalContext.function(c.library, "resampleEWA", alpha: true,
                                                                              curveTable: true),
                                              options: [.bindingInfo], reflection: &compute)
    #expect(compute?.bindings.first { $0.name == "inverse" }?.index == 3)
    for (vertex, fragment) in [("tileVertex", "tileFragment"), ("tileVertex", "tileFragmentNearest"),
                               ("metalfxVertex", "metalfxFragment")] {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = c.library.makeFunction(name: vertex)
        d.fragmentFunction = MetalContext.function(c.library, fragment, alpha: false, curveTable: true)
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        var render: MTLRenderPipelineReflection?
        _ = try c.device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo], reflection: &render)
        #expect(render?.fragmentBindings.first { $0.name == "inverse" }?.index == 3, "\(fragment)")
    }
}

@Test func encodeSRGBVariantsCompile() throws {
    // The resample kernels' ENCODE_SRGB variants (GPUs without shader writes to _srgb textures, Intel and AMD Macs):
    // every kernel, both directions, with the other variants they combine with. On such a GPU TileRenderer uses them
    // for every compute frame, so a variant that fails to build would leave those Macs without Lanczos, Mitchell or EWA.
    let c = MetalContext.shared
    for kernel in ResampleKernel.allCases {
        for upscale in [false, true] {
            for (alpha, cube) in [(false, false), (true, false), (false, true)] {
                _ = try c.device.makeComputePipelineState(function: MetalContext.resampleFunction(
                    c.library, kernel: kernel, upscale: upscale, alpha: alpha, colorLUT: cube, encodeSRGB: true))
            }
        }
    }
    _ = try c.device.makeComputePipelineState(function: MetalContext.function(c.library, "resampleEWA", alpha: true,
                                                                              encodeSRGB: true))
}

@Test func uploadQueueIsSeparate() {
    let c = MetalContext.shared
    #expect(c.uploadQueue !== c.queue)
    #expect(c.uploadQueue.label == "upload")
}
