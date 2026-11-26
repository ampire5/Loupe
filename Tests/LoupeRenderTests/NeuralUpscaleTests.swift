import Foundation
import Testing
import LoupeCore
@testable import LoupeRender

struct NeuralUpscaleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_MODEL"] != nil))
    func installedModelProducesNativePyramid() async throws {
        let model = try installedModel()
        let source = try await TiledImage.make(from: TestImages.synthetic(513, 319))
        let worker = NeuralUpscaleWorker()
        let cancellation = UpscaleCancellation()
        let result = try await worker.process(source, model: model,
                                              limit: 64 * 1024 * 1024, cancellation: cancellation)
        #expect([2, 4].contains(result.scale))
        let outputSize = PixelSize(width: 513 * result.scale, height: 319 * result.scale)
        #expect(result.image.grid.imageSize == outputSize)
        #expect(result.image.finestResidentLevel == 0)
        #expect(result.image.byteCount == UpscaleGeometry.residentBytes(outputSize))
        let a = try await TestImages.readSlice(result.image.levels[0], slice: 0)
        let b = TestImages.texel(a, x: 128, y: 128)
        let c = TestImages.texel(a, x: 384, y: 384)
        #expect(abs(Int(b.g) - Int(c.g)) + abs(Int(b.b) - Int(c.b)) > 10)
        await #expect(throws: NeuralUpscaleError.self) {
            try await worker.process(source, model: model, limit: 1, cancellation: UpscaleCancellation())
        }
        cancellation.cancel()
        await #expect(throws: CancellationError.self) {
            try await worker.process(source, model: model, limit: 64 * 1024 * 1024, cancellation: cancellation)
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_PHOTOS"] != nil))
    func measureInstalledModelOnPhotos() async throws {
        let model = try installedModel()
        let paths = try #require(ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_PHOTOS"]).split(separator: "|")
        let worker = NeuralUpscaleWorker()
        for path in paths {
            let data = try Data(contentsOf: URL(fileURLWithPath: String(path)))
            let source = try await TiledImage.make(from: ImageIODecoder.decodeFull(data))
            var times: [Duration] = []
            for _ in 0..<4 {
                let start = ContinuousClock.now
                let result = try await worker.process(source, model: model,
                                                      limit: 256 * 1024 * 1024, cancellation: UpscaleCancellation())
                times.append(start.duration(to: .now))
                #expect(result.image.finestResidentLevel == 0)
            }
            print("Upscale \(source.grid.imageSize), first \(times[0]), warm \(times.dropFirst().sorted())")
        }
    }

    private func installedModel() throws -> NeuralUpscaleModel {
        let path = try #require(ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_MODEL"])
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var model = try #require(NeuralUpscaleModel.scan(url.deletingLastPathComponent()).first { $0.url.path == url.path })
        model.margin = 40
        return model
    }

}
