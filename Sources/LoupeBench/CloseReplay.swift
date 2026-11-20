import Darwin
import Foundation
import LoupeCore
import LoupeRender

enum CloseReplay {
    private struct Sample {
        let footprint = ProcessMemory.footprint()
        let gpu = ReplayMetrics.gpuAllocated()
    }

    static func run(_ script: ReplayScript, files: [URL], options: ReplayOptions) async {
        guard files.count > script.steps.count else { fail("close needs at least six images") }
        let limits = Replay.limits(options)
        let reader = FileReader(chunkReader: { fd, buffer, count, offset in
            if options.noCache && offset == 0 { _ = fcntl(fd, F_NOCACHE, 1) }
            return FileReader.pread(fd, buffer, count, offset)
        })
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: limits)

        print("## Replay close (MiB)")
        print("| Cycle | Footprint at 0.5 s | Footprint at 3 s | GPU at 3 s | Cache at 3 s |")
        print("|---:|---:|---:|---:|---:|")
        let baseline = Sample()
        print("| Before first open | – | \(mib(baseline.footprint)) | \(mib(baseline.gpu)) | 0 |")
        var samples: [Sample] = []
        for cycle in 1...20 {
            let session = CacheSessionID(cycle)
            let driver = ReplayDriver(cache: cache, files: files, zoom: script.zoom, screen: options.screen,
                                      box: FrameBox(), showBlurry: limits.showBlurry, session: session)
            await cache.register(session) { [weak driver] url in
                Task { await driver?.update(url) }
            }
            await cache.setActivity(session, active: true, visible: true)
            _ = await driver.begin(number: 0, index: 0, move: 0, burst: false)
            try? await Task.sleep(for: script.openDwell)
            await driver.endStep()
            var index = 0
            for (step, move) in script.steps.enumerated() {
                index += move.move
                _ = await driver.begin(number: step + 1, index: index, move: move.move, burst: false)
                try? await Task.sleep(for: move.dwell)
                await driver.endStep()
            }
            let records = await driver.records
            guard records.contains(where: { $0.previewMs != nil && $0.failure == nil }) else {
                fail("close cycle \(cycle): no image reached preview")
            }
            await driver.close()
            await cache.unregister(session)
            let deadline = ContinuousClock.now + .seconds(30)
            while !(await cache.isIdle) {
                guard ContinuousClock.now < deadline else { fail("close cycle \(cycle): cache did not go idle") }
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Record both the early footprint and the same three-second settling interval as other replays.
            let idle = ContinuousClock.now
            try? await Task.sleep(until: idle + .milliseconds(500), clock: .continuous)
            let early = ProcessMemory.footprint()
            try? await Task.sleep(until: idle + .seconds(3), clock: .continuous)
            let stats = await cache.stats()
            let sample = Sample()
            samples.append(sample)
            print("| \(cycle) | \(mib(early)) | \(mib(sample.footprint)) | \(mib(sample.gpu)) | "
                  + "\(mib(stats.usedBytes + stats.graphicsUsedBytes)) |")
            guard stats.usedBytes == 0, stats.graphicsUsedBytes == 0 else {
                fail("close cycle \(cycle): cache held bytes after unregister")
            }
        }
        let tail = samples.suffix(10).map(\.footprint)
        let mean = Double(tail.reduce(0, +)) / Double(tail.count)
        let deviation = tail.map { abs(Double($0) - mean) / mean }.max() ?? .infinity
        print(String(format: "\nFootprint plateau (last 10, ±5%% of mean): %@, max deviation %.2f%%.",
                     deviation <= 0.05 ? "pass" : "fail", deviation * 100))
        guard deviation <= 0.05 else { fail("close footprint did not reach a plateau") }
    }

    private static func mib(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}
