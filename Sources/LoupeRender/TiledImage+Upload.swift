import Foundation
import LoupeCore
import Metal

/// The GPU side of `TiledImage.upload`: texture allocation, the tile blits and the pyramid build.
/// Kept apart from `TiledImage.swift`, which owns residency and its lock.
extension TiledImage {
    /// One descriptor per pyramid level. Pure (allocates nothing), so limits can be checked without a GPU.
    /// Throws `.tooLarge` when a level has more tiles than a texture array can hold: Metal's descriptor
    /// validation would otherwise abort the process.
    static func descriptors(for grid: TileGrid) throws -> [MTLTextureDescriptor] {
        guard grid.fitsTextureArrays else { throw DecodeError.tooLarge }
        return (0..<grid.levelCount).map { level in
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = .bgra8Unorm
            d.width = TileGrid.slotSize
            d.height = TileGrid.slotSize
            d.arrayLength = grid.columns(level) * grid.rows(level)
            d.storageMode = .private
            d.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            return d
        }
    }

    /// Allocates fresh textures for `level...last`, blits `pixels` into `level` and downsamples the rest, all in one
    /// command buffer on `context.uploadQueue`; returns them (index 0 = `level`) after the GPU completes. Awaits a
    /// completion handler rather than blocking a thread. Nothing is published here: the caller swaps them in.
    /// `premultipliedLinear` (pixels with alpha < 1, or of a `.table` curve: its curve's `CurveTables.upload()`):
    /// `uploadPremultipliedLinear` writes `level` through that table instead of the blits, as premultiplied linear light
    /// (`Shaders.source`); the pyramid kernels then build the rest in that form as they are.
    /// `gpuSeconds`: the command buffer's `gpuEndTime - gpuStartTime` (blits and pyramid), from its completed handler.
    func encodeAndRun(_ pixels: DecodedImage, level: Int, filter: PyramidFilter, premultipliedLinear: MTLBuffer? = nil,
                      context: MetalContext) async throws
        -> (textures: [MTLTexture], views: [MTLTexture], gpuSeconds: Double) {
        let device = context.device
        var textures: [MTLTexture] = [], views: [MTLTexture] = []
        for (l, descriptor) in try Self.descriptors(for: grid).enumerated() where l >= level {
            guard let texture = device.makeTexture(descriptor: descriptor),
                  let view = texture.makeTextureView(pixelFormat: .bgra8Unorm_srgb) else { throw DecodeError.outOfMemory }
            texture.label = "level \(l)"
            textures.append(texture)
            views.append(view)
        }
        // The MTLBuffer wraps memory it does not own; its deallocator keeps the pixel buffer alive until the
        // MTLBuffer itself is released (a command buffer retains it for as long as the GPU may read it).
        let buffer = pixels.buffer
        guard let source = device.makeBuffer(bytesNoCopy: buffer.bytes, length: buffer.length, options: .storageModeShared,
                                             deallocator: { _, _ in withExtendedLifetime(buffer) {} }),
              let commands = context.uploadQueue.makeCommandBuffer() else { throw DecodeError.outOfMemory }
        source.label = "decoded level \(level)"
        commands.label = "upload level \(level)"

        if let premultipliedLinear {
            try encodePremultipliedLinear(commands, level: level, into: textures[0], from: source,
                                          bytesPerRow: pixels.bytesPerRow, table: premultipliedLinear, context: context)
        } else {
            guard let blit = commands.makeBlitCommandEncoder() else { throw DecodeError.outOfMemory }
            encodeUpload(blit, level: level, into: textures[0], from: source, bytesPerRow: pixels.bytesPerRow)
            blit.endEncoding()
        }
        try buildPyramid(from: level, textures: textures, views: views, filter: filter, commandBuffer: commands, context: context)

        let gpuSeconds = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
            commands.addCompletedHandler { buffer in
                // The handler holds the image, so its pages outlive every GPU read of them (the command buffer retains `source`).
                withExtendedLifetime(pixels) {
                    if let error = buffer.error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: buffer.gpuEndTime - buffer.gpuStartTime) }
                }
            }
            commands.commit()
        }
        return (textures, views, gpuSeconds)
    }

    /// One blit per tile of `level`: the clipped slot rect goes to the slice at `slotRect.origin - slotOrigin`
    /// (8 px in at the top/left level edges, 0 elsewhere), so a slot's apron holds real neighbour pixels.
    /// `source` holds the whole level, `grid.levelSize(level)` px.
    private func encodeUpload(_ blit: MTLBlitCommandEncoder, level: Int, into texture: MTLTexture,
                              from source: MTLBuffer, bytesPerRow: Int) {
        for row in 0..<grid.rows(level) {
            for column in 0..<grid.columns(level) {
                let tile = TileID(level: level, column: column, row: row)
                let rect = grid.slotRect(tile), origin = grid.slotOrigin(tile)
                blit.copy(from: source, sourceOffset: rect.y * bytesPerRow + rect.x * 4,
                          sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * rect.height,
                          sourceSize: MTLSize(width: rect.width, height: rect.height, depth: 1),
                          to: texture, destinationSlice: grid.slice(of: tile), destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: rect.x - origin.x, y: rect.y - origin.y, z: 0))
            }
        }
    }

    /// The upload of a level with alpha < 1 or of a `.table` curve: one `uploadPremultipliedLinear` dispatch over every
    /// slot texel of `level`, writing what the blits would (slot texels inside the level, aprons included), each texel
    /// premultiplied in linear light through `table` (`MetalContext.premultipliedLinearTable`). Throws `.outOfMemory`
    /// if the encoder cannot be made.
    private func encodePremultipliedLinear(_ commands: MTLCommandBuffer, level: Int, into texture: MTLTexture,
                                           from source: MTLBuffer, bytesPerRow: Int, table: MTLBuffer,
                                           context: MetalContext) throws {
        guard let encoder = commands.makeComputeCommandEncoder() else { throw DecodeError.outOfMemory }
        encoder.label = "upload level \(level), premultiplied linear"
        let pipeline = context.uploadPremultipliedLinear
        var params = AlphaUploadParams(levelSize: Self.size(grid.levelSize(level)), columns: UInt32(grid.columns(level)),
                                       bytesPerRow: UInt32(bytesPerRow))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<AlphaUploadParams>.stride, index: 1)
        encoder.setBuffer(table, offset: 0, index: 2)
        encoder.setTexture(texture, index: 0)
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: TileGrid.slotSize, height: TileGrid.slotSize, depth: texture.arrayLength),
                                threadsPerThreadgroup: MTLSize(width: width, height: max(pipeline.maxTotalThreadsPerThreadgroup / width, 1),
                                                               depth: 1))
        encoder.endEncoding()
    }

    /// Fills levels `start + 1`... with one dispatch per level, `L` -> `L + 1`: `downsample2x` for `.box`,
    /// `downsampleLanczos2x` for `.lanczos3`, reading level `L` through its sRGB view (so the filter works in linear
    /// light) and writing level `L + 1`'s unorm texture. `textures`/`views` hold levels `start...last` (index 0 = `start`).
    /// Each level gets its own compute encoder: level `L + 1` is read by the next dispatch, and encoder
    /// boundaries order those write-then-read dependencies (and the upload blits before the first read)
    /// without relying on in-encoder barriers between texture views; that cross-encoder ordering relies on
    /// Metal's default hazard tracking (the textures are tracked, as `descriptors(for:)` leaves it). A pyramid has
    /// at most ~15 levels and the dispatches are tiny next to the work in them, so the extra encoders cost nothing
    /// measurable. Throws `.outOfMemory` if an encoder cannot be created, so an upload never commits a half-built pyramid.
    func buildPyramid(from start: Int, textures: [MTLTexture], views: [MTLTexture], filter: PyramidFilter,
                      commandBuffer: MTLCommandBuffer, context: MetalContext) throws {
        let pipeline = filter == .box ? context.downsample : context.downsampleLanczos
        // Box: the grid is non-uniform (528 x 528 x tiles), so size threadgroups from the pipeline (Apple's
        // recommendation for dispatchThreads): a full SIMD width wide, as tall as the thread budget allows.
        // Lanczos: the kernel's 16 x 16 groups, which share their source rows in threadgroup memory; 528 = 33 * 16.
        let width = pipeline.threadExecutionWidth
        let threadsPerGroup = filter == .box
            ? MTLSize(width: width, height: max(pipeline.maxTotalThreadsPerThreadgroup / width, 1), depth: 1)
            : MTLSize(width: 16, height: 16, depth: 1)
        for level in (start + 1)..<max(grid.levelCount, start + 1) {
            let index = level - start
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw DecodeError.outOfMemory }
            encoder.label = "downsample level \(level)"
            var params = DownsampleParams(
                srcLevelSize: Self.size(grid.levelSize(level - 1)), dstLevelSize: Self.size(grid.levelSize(level)),
                srcColumns: UInt32(grid.columns(level - 1)), dstColumns: UInt32(grid.columns(level)))
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(views[index - 1], index: 0)
            encoder.setTexture(textures[index], index: 1)
            encoder.setBytes(&params, length: MemoryLayout<DownsampleParams>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: TileGrid.slotSize, height: TileGrid.slotSize, depth: textures[index].arrayLength),
                                    threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }
    }

    private static func size(_ s: PixelSize) -> SIMD2<UInt32> { SIMD2(UInt32(s.width), UInt32(s.height)) }
}
