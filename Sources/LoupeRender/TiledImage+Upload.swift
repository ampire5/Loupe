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

    /// Slices (528 x 528 slot textures) an upload hands the GPU per command buffer: the level's blits (or its
    /// premultiplied-linear pass) and each pyramid level go in pieces of this many slices, each committed once the
    /// previous one completed and no frame is in flight (`FrameTraffic`), so a frame drawn meanwhile gets the GPU. In
    /// one command buffer a 147 MP photo held the GPU for ~130 ms, and a pan at 100 % stopped for 150–175 ms whenever
    /// the next photo uploaded; in pieces of 16 (≤ 3.6 ms of GPU each) yielding to frames, the pan's frames keep their
    /// quiet 7–8 ms and one of ~24 is late, while the upload takes ~0.28 s instead of ~0.13 s (i7-10700K + Radeon Pro
    /// 5500 XT, 5120 x 2880 at 60 Hz, `LoupeBench panload`; 8 or 4 slices: no better, longer uploads).
    static let pieceSlices = 16

    /// Allocates fresh textures for `level...last`, fills `level` from `pixels` and downsamples the rest, in pieces of
    /// `pieceSlices` slices on `context.uploadQueue`, one command buffer each and each awaited (a completion handler,
    /// never a blocked thread) before the next; returns them (index 0 = `level`) once the GPU completed the last.
    /// Nothing is published here: the caller swaps them in, so a failure part way leaves nothing half-built in view.
    /// `premultipliedLinear` (pixels with alpha < 1, or of a `.table` curve: its curve's `CurveTables.upload()`):
    /// `uploadPremultipliedLinear` writes `level` through that table instead of the blits, as premultiplied linear light
    /// (`Shaders.source`); the pyramid kernels then build the rest in that form as they are.
    /// `gpuSeconds`: the sum over the pieces of `gpuEndTime - gpuStartTime`, from their completed handlers.
    func encodeAndRun(_ pixels: DecodedImage, level: Int, filter: PyramidFilter, premultipliedLinear: MTLBuffer? = nil,
                      pieceSlices: Int = TiledImage.pieceSlices, context: MetalContext) async throws
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
                                             deallocator: { _, _ in withExtendedLifetime(buffer) {} })
        else { throw DecodeError.outOfMemory }
        source.label = "decoded level \(level)"

        var gpuSeconds = 0.0
        for slices in Self.pieces(of: grid.columns(level) * grid.rows(level), size: pieceSlices) {
            gpuSeconds += try await Self.run(context, label: "upload level \(level), slices \(slices)") { commands in
                if let premultipliedLinear {
                    try encodePremultipliedLinear(commands, level: level, slices: slices, into: textures[0], from: source,
                                                  bytesPerRow: pixels.bytesPerRow, table: premultipliedLinear,
                                                  context: context)
                } else {
                    guard let blit = commands.makeBlitCommandEncoder() else { throw DecodeError.outOfMemory }
                    encodeUpload(blit, level: level, slices: slices, into: textures[0], from: source,
                                 bytesPerRow: pixels.bytesPerRow)
                    blit.endEncoding()
                }
            }
        }
        for l in (level + 1)..<max(grid.levelCount, level + 1) {
            let index = l - level
            for slices in Self.pieces(of: grid.columns(l) * grid.rows(l), size: pieceSlices) {
                gpuSeconds += try await Self.run(context, label: "downsample level \(l), slices \(slices)") { commands in
                    try encodeDownsample(commands, level: l, slices: slices, from: views[index - 1],
                                         into: textures[index], filter: filter, context: context)
                }
            }
        }
        // The pages outlive every GPU read of them: the last piece has completed.
        withExtendedLifetime(pixels) {}
        return (textures, views, gpuSeconds)
    }

    /// `0..<count` in consecutive ranges of `size` (the last one shorter). Pure, for the tests.
    static func pieces(of count: Int, size: Int) -> [Range<Int>] {
        let size = max(1, size)
        return stride(from: 0, to: count, by: size).map { $0..<min(count, $0 + size) }
    }

    /// Once no frame is in flight (`FrameTraffic.quiet`), encodes one command buffer on `context.uploadQueue` with
    /// `encode`, commits it and returns its GPU seconds once it completed. Throws `.outOfMemory` if it cannot be made,
    /// what `encode` throws (nothing committed), or its error.
    private static func run(_ context: MetalContext, label: String,
                            _ encode: (MTLCommandBuffer) throws -> Void) async throws -> Double {
        await context.frames.quiet()
        guard let commands = context.uploadQueue.makeCommandBuffer() else { throw DecodeError.outOfMemory }
        commands.label = label
        try encode(commands)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
            commands.addCompletedHandler { buffer in
                if let error = buffer.error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: buffer.gpuEndTime - buffer.gpuStartTime) }
            }
            commands.commit()
        }
    }

    /// One blit per tile of `level` in `slices`: the clipped slot rect goes to the slice at `slotRect.origin -
    /// slotOrigin` (8 px in at the top/left level edges, 0 elsewhere), so a slot's apron holds real neighbour pixels.
    /// `source` holds the whole level, `grid.levelSize(level)` px.
    private func encodeUpload(_ blit: MTLBlitCommandEncoder, level: Int, slices: Range<Int>, into texture: MTLTexture,
                              from source: MTLBuffer, bytesPerRow: Int) {
        let columns = grid.columns(level)
        for slice in slices {
            let tile = TileID(level: level, column: slice % columns, row: slice / columns)
            let rect = grid.slotRect(tile), origin = grid.slotOrigin(tile)
            blit.copy(from: source, sourceOffset: rect.y * bytesPerRow + rect.x * 4,
                      sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * rect.height,
                      sourceSize: MTLSize(width: rect.width, height: rect.height, depth: 1),
                      to: texture, destinationSlice: grid.slice(of: tile), destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: rect.x - origin.x, y: rect.y - origin.y, z: 0))
        }
    }

    /// The upload of a level with alpha < 1 or of a `.table` curve: one `uploadPremultipliedLinear` dispatch over every
    /// slot texel of `slices` of `level`, writing what the blits would (slot texels inside the level, aprons included),
    /// each texel premultiplied in linear light through `table` (`MetalContext.premultipliedLinearTable`). Throws
    /// `.outOfMemory` if the encoder cannot be made.
    private func encodePremultipliedLinear(_ commands: MTLCommandBuffer, level: Int, slices: Range<Int>,
                                           into texture: MTLTexture, from source: MTLBuffer, bytesPerRow: Int,
                                           table: MTLBuffer, context: MetalContext) throws {
        guard let encoder = commands.makeComputeCommandEncoder() else { throw DecodeError.outOfMemory }
        encoder.label = "upload level \(level), premultiplied linear"
        let pipeline = context.uploadPremultipliedLinear
        var params = AlphaUploadParams(levelSize: Self.size(grid.levelSize(level)), columns: UInt32(grid.columns(level)),
                                       bytesPerRow: UInt32(bytesPerRow), firstSlice: UInt32(slices.lowerBound))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<AlphaUploadParams>.stride, index: 1)
        encoder.setBuffer(table, offset: 0, index: 2)
        encoder.setTexture(texture, index: 0)
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: TileGrid.slotSize, height: TileGrid.slotSize, depth: slices.count),
                                threadsPerThreadgroup: MTLSize(width: width, height: max(pipeline.maxTotalThreadsPerThreadgroup / width, 1),
                                                               depth: 1))
        encoder.endEncoding()
    }

    /// Fills `slices` of `level` from level `level - 1`: `downsample2x` for `.box`, `downsampleLanczos2x` for
    /// `.lanczos3`, reading the finer level through its sRGB view `source` (so the filter works in linear light) and
    /// writing `destination`, the level's unorm texture. The pieces of one level, and the levels, run in order on the
    /// upload queue, each awaited before the next is encoded, so every read sees the finished level above it. Throws
    /// `.outOfMemory` if the encoder cannot be made.
    private func encodeDownsample(_ commands: MTLCommandBuffer, level: Int, slices: Range<Int>, from source: MTLTexture,
                                  into destination: MTLTexture, filter: PyramidFilter, context: MetalContext) throws {
        let pipeline = filter == .box ? context.downsample : context.downsampleLanczos
        // Box: the grid is non-uniform (528 x 528 x tiles), so size threadgroups from the pipeline (Apple's
        // recommendation for dispatchThreads): a full SIMD width wide, as tall as the thread budget allows.
        // Lanczos: the kernel's 16 x 16 groups, which share their source rows in threadgroup memory; 528 = 33 * 16.
        let width = pipeline.threadExecutionWidth
        let threadsPerGroup = filter == .box
            ? MTLSize(width: width, height: max(pipeline.maxTotalThreadsPerThreadgroup / width, 1), depth: 1)
            : MTLSize(width: 16, height: 16, depth: 1)
        guard let encoder = commands.makeComputeCommandEncoder() else { throw DecodeError.outOfMemory }
        encoder.label = "downsample level \(level)"
        var params = DownsampleParams(
            srcLevelSize: Self.size(grid.levelSize(level - 1)), dstLevelSize: Self.size(grid.levelSize(level)),
            srcColumns: UInt32(grid.columns(level - 1)), dstColumns: UInt32(grid.columns(level)),
            firstSlice: UInt32(slices.lowerBound))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<DownsampleParams>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: TileGrid.slotSize, height: TileGrid.slotSize, depth: slices.count),
                                threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }

    private static func size(_ s: PixelSize) -> SIMD2<UInt32> { SIMD2(UInt32(s.width), UInt32(s.height)) }
}
