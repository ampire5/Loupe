import LoupeCore
import Metal
import MetalFX
import Testing
@testable import LoupeRender

/// Tests the scaler's native FP16 boundary independently of the debanding algorithm.
@Suite struct DebandMetalFXPrecisionTests {
    @Test func formatsAndSecondCheckerStayPerceptualFloat() throws {
        let context = MetalContext.shared
        guard context.supportsMetalFX else { return }
        let original = try #require(MetalFXStage(device: context.device, width: 64, height: 64))
        #expect(!original.highPrecision)
        #expect(original.input.pixelFormat == .bgra8Unorm_srgb)
        #expect(original.output.pixelFormat == .bgra8Unorm_srgb)
        #expect(original.scaler.colorProcessingMode == .perceptual)
        let precise = try #require(MetalFXStage(device: context.device, width: 64, height: 64, highPrecision: true))
        #expect(precise.input.pixelFormat == .rgba16Float)
        #expect(precise.output.pixelFormat == .rgba16Float)
        #expect(precise.scaler.colorProcessingMode == .perceptual)
        let before = precise.allocatedBytes
        let second = try #require(precise.makeSecondOutput())
        #expect(second.pixelFormat == .rgba16Float)
        #expect(precise.allocatedBytes == before + second.allocatedSize)
    }

    @Test func nativeScalerPreservesLinearConstantColors() async throws {
        guard MetalContext.shared.supportsMetalFX else { return }
        for rgb: SIMD3<Float> in [SIMD3(0.02, 0.2, 0.7), SIMD3(repeating: 0.001), SIMD3(repeating: 0.8)] {
            let values = try await Self.scale { _, _ in rgb }
            // MetalFX has its own half-precision arithmetic. Compare in output sRGB
            // codes, so an accidental perceptual/linear conversion cannot hide here.
            for index in stride(from: 0, to: values.count, by: 4) {
                for channel in 0..<3 {
                    let expected = MetalContext.srgbEncode(Double(rgb[channel])) * 255
                    let actual = Double(values[index + channel]) * 255
                    #expect(abs(actual - expected) <= 1)
                }
            }
        }
    }

    @Test func subCodeGradientSurvivesScaler() async throws {
        guard MetalContext.shared.supportsMetalFX else { return }
        // This complete ramp occupies less than one RGB8 sRGB code. Requantizing
        // composition or scaling to RGB8 would flatten it to at most two values.
        let values = try await Self.scale { x, _ in SIMD3(repeating: 0.2 + Float(x) * 0.00002) }
        let row = (8..<56).map { values[(32 * 64 + $0) * 4] }
        #expect(Set(row).count > 2)
        let first = try #require(row.first), last = try #require(row.last)
        #expect(last > first)
    }

    private static func scale(_ pixel: (Int, Int) -> SIMD3<Float>) async throws -> [Half] {
        let context = MetalContext.shared, device = context.device
        let stage = try #require(MetalFXStage(device: device, width: 64, height: 64, highPrecision: true))
        let uploadDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                         width: 64, height: 64, mipmapped: false)
        uploadDescriptor.storageMode = .shared
        let upload = try #require(device.makeTexture(descriptor: uploadDescriptor))
        var pixels = [Half](repeating: 1, count: 64 * 64 * 4)
        for y in 0..<64 { for x in 0..<64 {
            let rgb = pixel(min(x, 31), min(y, 31))
            for channel in 0..<3 { pixels[(y * 64 + x) * 4 + channel] = Half(MetalContext.srgbEncode(Double(rgb[channel]))) }
        }}
        pixels.withUnsafeBytes {
            upload.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: 64 * 8)
        }
        let readback = try #require(device.makeBuffer(length: 64 * 64 * 8, options: .storageModeShared))
        let commands = try #require(context.queue.makeCommandBuffer())
        let uploadBlit = try #require(commands.makeBlitCommandEncoder())
        uploadBlit.copy(from: upload, to: stage.input)
        uploadBlit.endEncoding()
        stage.scaler.inputContentWidth = 32
        stage.scaler.inputContentHeight = 32
        stage.scaler.encode(commandBuffer: commands)
        let readBlit = try #require(commands.makeBlitCommandEncoder())
        readBlit.copy(from: stage.output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: 64, height: 64, depth: 1), to: readback, destinationOffset: 0,
                      destinationBytesPerRow: 64 * 8, destinationBytesPerImage: 64 * 64 * 8)
        readBlit.endEncoding()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            commands.addCompletedHandler { completed in
                if let error = completed.error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            commands.commit()
        }
        return Array(UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: Half.self), count: pixels.count))
    }
}
