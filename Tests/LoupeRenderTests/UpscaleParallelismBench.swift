import Foundation
import LoupeCore
import LoupeRender
import Testing

/// Run with one model and a real photo. Each invocation isolates peak RSS for its worker count.
@MainActor struct UpscaleParallelismBench {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_BENCH_UPSCALE_WORKERS"] != nil))
    func measuresThroughputAndMainActorDelay() async throws {
        let environment = ProcessInfo.processInfo.environment
        let count = try #require(environment["LOUPE_BENCH_UPSCALE_WORKERS"].flatMap(Int.init))
        try #require((1...3).contains(count))
        let photo = URL(fileURLWithPath: try #require(environment["LOUPE_BENCH_UPSCALE_PHOTO"]))
        let folder = URL(fileURLWithPath: try #require(environment["LOUPE_BENCH_UPSCALE_MODELS"]))
        let factor = environment["LOUPE_BENCH_UPSCALE_SCALE"].flatMap(Int.init) ?? 2
        let candidates = NeuralUpscaleModel.scan(folder)
        var chosen: NeuralUpscaleModel?
        for item in candidates {
            if try await item.nativeScale().rawValue == factor { chosen = item; break }
        }
        var model = try #require(chosen)
        model.compute = .cpuAndGPU
        let profile = model
        let source = try await TiledImage.make(from: ImageIODecoder.decodeFull(Data(contentsOf: photo)))
        let limit = 256 * 1024 * 1024
        let workers = (0..<count).map { _ in NeuralUpscaleWorker() }
        for worker in workers {
            _ = try await worker.process(source, model: profile, limit: limit, cancellation: UpscaleCancellation())
        }

        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: output) }
        let inputs = try (0..<6).map { index -> SavedUpscale in
            let input = output.appendingPathComponent("benchmark-\(index).jpg")
            try FileManager.default.copyItem(at: photo, to: input)
            let values = try input.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let stamp = FileStamp(modified: try #require(values.contentModificationDate), size: try #require(values.fileSize))
            return SavedUpscale(source: input, stamp: stamp)
        }
        let clock = ContinuousClock()
        let started = clock.now
        let monitor = Task { @MainActor in
            var samples: [Double] = []
            while !Task.isCancelled {
                let due = clock.now + .milliseconds(16)
                do { try await clock.sleep(until: due, tolerance: .zero) } catch { break }
                samples.append(Self.ms(due.duration(to: clock.now)))
            }
            return samples
        }
        let latencies = try await withThrowingTaskGroup(of: [Double].self) { group in
            for (index, worker) in workers.enumerated() {
                let assigned = stride(from: index, to: inputs.count, by: count).map { inputs[$0] }
                group.addTask(priority: .utility) {
                    var processing: [Double] = []
                    for copy in assigned {
                        let start = clock.now
                        let result = try await worker.process(source, model: profile, limit: limit, cancellation: UpscaleCancellation(),
                                                              saving: .init(copy: copy, orientation: .up, model: "benchmark"))
                        try #require(result.savedCopy == copy)
                        processing.append(Self.ms(start.duration(to: clock.now)))
                    }
                    return processing
                }
            }
            var samples: [Double] = []
            for try await result in group { samples += result }
            return samples
        }
        let wall = Self.ms(started.duration(to: clock.now))
        monitor.cancel()
        let delays = await monitor.value.sorted()
        let delay95 = delays.isEmpty ? 0 : delays[Int(Double(delays.count - 1) * 0.95)]
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("Upscale \(source.grid.imageSize.width)x\(source.grid.imageSize.height) \(factor)x workers=\(count)"
            + " wallMS=\(Int(wall)) photosPerSecond=\(Double(inputs.count) * 1_000 / wall)"
            + " perPhotoMS=\(latencies.sorted().map(Int.init)) mainDelayP95MS=\(delay95)"
            + " mainDelayMaxMS=\(delays.last ?? 0) rssMiB=\(usage.ru_maxrss / 1_048_576)")
    }

    nonisolated private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
