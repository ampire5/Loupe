import Foundation
import LoupeCore
import LoupeRender
import Metal
import QuartzCore

// LoupeBench panload [--runs N] [--size WxH] [--cpu [--workers N]] [--no-upload] [--resident G [--touch]]
//
// What a pan at 100 % suffers while the next photo uploads: frames of a 147 MP zone plate (14000x10502, uploaded once)
// are drawn through the real TileRenderer at 60 Hz into a private bgra8Unorm_srgb target (default 5120x2880, a 5K
// screen), panning a little every frame, at most three in flight (the layer's drawables); after 1 s of quiet frames a
// second 147 MP photo uploads the way the cache uploads a decoded neighbour (`TiledImage.upload`, level 0 and its
// pyramid on the upload queue), and frames go on until 0.5 s after it completes. Per frame: from submit to the GPU's
// completion (a frame later than one period misses its vsync), and how long the frame waited for a free drawable.
// --cpu also swaps the channels of another 147 MP buffer on every core while the upload runs, as the JPEG XL decoder's
// RGBA → BGRA pass does (16 row bands through concurrentPerform; --workers N: N bands), to see whether the CPU side
// delays the frames. --no-upload leaves the upload out (the CPU load alone). --resident G first fills G gigabytes of
// private GPU buffers (the cache's other photos), to find where the GPU's memory runs out on a discrete card; --touch
// writes them all again before each run, as stepping brings the other photos back.

enum PanLoadBench {
    static let usage = "usage: LoupeBench panload [--runs N] [--size WxH] [--cpu [--workers N]] [--no-upload] [--resident G [--touch]]"
    static let period = 1.0 / 60

    struct Frame {
        let submit: Double
        let waited: Double
        var done = 0.0
        var gpu = 0.0
    }

    static func main(_ arguments: [String]) -> Never {
        var runs = 3, output = PixelSize(width: 5120, height: 2880), cpu = false, upload = true, workers = 16, resident = 0.0, touch = false
        var args = arguments[...]
        while let arg = args.popFirst() {
            switch arg {
            case "--runs":
                guard let v = args.popFirst(), let n = Int(v), n >= 1 else { fail("--runs needs a positive integer") }
                runs = n
            case "--size":
                let parts = (args.popFirst() ?? "").lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { fail("--size needs WxH") }
                output = PixelSize(width: parts[0], height: parts[1])
            case "--cpu": cpu = true
            case "--no-upload": upload = false
            case "--touch": touch = true
            case "--resident":
                guard let v = args.popFirst(), let g = Double(v), g >= 0 else { fail("--resident needs gigabytes, e.g. 4.5") }
                resident = g
            case "--workers":
                guard let v = args.popFirst(), let n = Int(v), n >= 1 else { fail("--workers needs a positive integer") }
                workers = n
            default: fail("unknown option \(arg)\n\(usage)")
            }
        }
        Task {
            await run(runs: runs, output: output, cpu: cpu, upload: upload, workers: workers, resident: resident, touch: touch)
            exit(0)
        }
        dispatchMain()
    }

    private static func run(runs: Int, output: PixelSize, cpu: Bool, upload: Bool, workers: Int, resident: Double, touch: Bool) async {
        print("# LoupeBench panload: \(RenderBench.machine()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("output \(output.width)x\(output.height) at 100 %, 60 Hz, 3 frames in flight; neighbour upload with the "
              + "\(Config().pyramidFilter.rawValue) pyramid\(cpu ? "; RGBA → BGRA on every core during the upload" : "")\n")
        let shownSize = PixelSize(width: 14000, height: 10502), nextSize = PixelSize(width: 10502, height: 14000)
        let shown: TiledImage, next: DecodedImage, scratch: DecodedImage?
        do {
            let decoded = try RenderBench.zonePlate(shownSize)
            shown = TiledImage.empty(grid: TileGrid(imageSize: shownSize), colorSpace: decoded.colorSpace)
            try await shown.upload(LevelImage(image: decoded, level: 0), filter: Config().pyramidFilter)
            next = try RenderBench.zonePlate(nextSize)
            scratch = cpu ? try RenderBench.zonePlate(nextSize) : nil
        } catch {
            fail("cannot make the test images: \(error)")
        }
        let held = holdResident(gigabytes: resident)
        let device = MetalContext.shared.device
        print(String(format: "GPU: %@, unified memory %@, recommended working set %.2f GB; held %.2f GB more; allocated %.2f GB\n",
                     device.name, device.hasUnifiedMemory ? "yes" : "no", Double(device.recommendedMaxWorkingSetSize) / 1e9,
                     Double(held.reduce(0) { $0 + $1.length }) / 1e9, Double(device.currentAllocatedSize) / 1e9))
        let renderer = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
        renderer.backingScale = 2
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: output.width,
                                                         height: output.height, mipmapped: false)
        d.storageMode = .private
        d.usage = [.renderTarget, .shaderWrite]
        guard let target = MetalContext.shared.device.makeTexture(descriptor: d) else { fail("no target") }
        let base = ViewTransform(imageSize: CGSize(width: shownSize.width, height: shownSize.height),
                                 viewSize: CGSize(width: output.width, height: output.height), mode: .actual(1))

        print("| run | quiet: median / max ms | upload GPU / wall ms | during: median / max ms | late frames | longest gap ms | "
              + "frame GPU during: median / max ms | drawable wait max ms |")
        print("|---|---|---|---|---|---|---|---|")
        for r in 1...runs {
            if touch { touchAll(held) }
            let frames = Frames()
            let driver = Driver(renderer: renderer, image: shown, base: base, target: target, frames: frames)
            driver.start()
            try? await Task.sleep(for: .seconds(1))
            let uploadStart = CACurrentMediaTime()
            var swizzle: Task<Void, Never>?
            if let scratch {
                swizzle = Task.detached(priority: .high) { swapChannels(scratch, workers: workers) }
            }
            let fresh = TiledImage.empty(grid: TileGrid(imageSize: nextSize), colorSpace: next.colorSpace)
            let gpu = upload ? (try? await fresh.upload(LevelImage(image: next, level: 0), filter: Config().pyramidFilter)) ?? nil : nil
            await swizzle?.value
            let uploadEnd = CACurrentMediaTime()
            try? await Task.sleep(for: .milliseconds(500))
            driver.stop()
            try? await Task.sleep(for: .milliseconds(200))
            withExtendedLifetime(fresh) {}
            let all = frames.snapshot().filter { $0.done > 0 }
            let quiet = all.filter { $0.submit < uploadStart }.map { ($0.done - $0.submit) * 1000 }
            let during = all.filter { $0.done >= uploadStart && $0.submit <= uploadEnd + 0.1 }
            let latency = during.map { ($0.done - $0.submit) * 1000 }
            let late = latency.filter { $0 > period * 1000 }.count
            let dones = all.map(\.done).sorted()
            let gaps = zip(dones.dropFirst(), dones).map { ($0 - $1) * 1000 }
            let waited = all.map { $0.waited * 1000 }.max() ?? 0
            let frameGPU = during.map { $0.gpu * 1000 }
            print(String(format: "| %d | %.1f / %.1f | %.1f / %.1f | %.1f / %.1f | %d of %d | %.1f | %.1f / %.1f | %.1f |", r,
                         RenderBench.median(quiet), quiet.max() ?? 0, (gpu ?? 0) * 1000, (uploadEnd - uploadStart) * 1000,
                         RenderBench.median(latency), latency.max() ?? 0, late, latency.count, gaps.max() ?? 0,
                         RenderBench.median(frameGPU), frameGPU.max() ?? 0, waited))
        }
    }

    /// `gigabytes` of private GPU buffers in 256 MB pieces, each written once by the GPU (as the cache's other pyramids
    /// are: uploaded, then left alone), to see where the shown photo and the next one stop fitting beside them.
    private static func holdResident(gigabytes: Double) -> [MTLBuffer] {
        let device = MetalContext.shared.device, piece = 256 << 20
        var held: [MTLBuffer] = []
        while Double(held.count * piece) < gigabytes * 1e9 {
            guard let buffer = device.makeBuffer(length: piece, options: .storageModePrivate),
                  let commands = MetalContext.shared.uploadQueue.makeCommandBuffer(),
                  let blit = commands.makeBlitCommandEncoder() else { fail("cannot hold \(gigabytes) GB") }
            blit.fill(buffer: buffer, range: 0..<piece, value: UInt8(held.count & 0xFF))
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            held.append(buffer)
        }
        return held
    }

    /// Writes every held buffer once more on the GPU, as stepping through the folder brings the cache's other photos
    /// back: on a card whose memory they overfill, the driver must page them in and the shown photo out.
    private static func touchAll(_ held: [MTLBuffer]) {
        for (i, buffer) in held.enumerated() {
            guard let commands = MetalContext.shared.uploadQueue.makeCommandBuffer(),
                  let blit = commands.makeBlitCommandEncoder() else { fail("cannot touch the held buffers") }
            blit.fill(buffer: buffer, range: 0..<buffer.length, value: UInt8((i + 1) & 0xFF))
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
    }

    /// The decoder's channel swap over `image`'s buffer, twice (swapping twice restores it).
    private static func swapChannels(_ image: DecodedImage, workers: Int) {
        let bands = workers, height = image.pixelSize.height, width = image.pixelSize.width
        let rowsPerBand = (height + bands - 1) / bands
        for _ in 0..<2 {
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let start = band * rowsPerBand, end = min(height, start + rowsPerBand)
                guard start < end else { return }
                for y in start..<end {
                    let row = (image.buffer.bytes + y * image.bytesPerRow).assumingMemoryBound(to: UInt32.self)
                    for x in 0..<width { let p = row[x]; row[x] = (p & 0xFF00_FF00) | (p & 0xFF) << 16 | (p >> 16) & 0xFF }
                }
            }
        }
    }

    final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Frame] = []
        func add(_ f: Frame) -> Int { lock.withLock { frames.append(f); return frames.count - 1 } }
        func finish(_ i: Int, done: Double, gpu: Double) { lock.withLock { frames[i].done = done; frames[i].gpu = gpu } }
        func snapshot() -> [Frame] { lock.withLock { frames } }
    }

    /// Submits a frame every period on its own thread (as RenderLoop's display-link thread does), at most three in flight.
    final class Driver: @unchecked Sendable {
        let renderer: TileRenderer, image: TiledImage, base: ViewTransform, target: MTLTexture, frames: Frames
        private let inFlight = DispatchSemaphore(value: 3)
        private let lock = NSLock()
        private var running = true

        init(renderer: TileRenderer, image: TiledImage, base: ViewTransform, target: MTLTexture, frames: Frames) {
            self.renderer = renderer; self.image = image; self.base = base; self.target = target; self.frames = frames
        }

        func start() {
            let thread = Thread { [self] in loop() }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func stop() { lock.withLock { running = false } }

        private func loop() {
            let queue = MetalContext.shared.queue
            var deadline = CACurrentMediaTime(), n = 0
            while lock.withLock({ running }) {
                deadline += PanLoadBench.period
                let wait = deadline - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let t0 = CACurrentMediaTime()
                inFlight.wait()
                let submit = CACurrentMediaTime()
                let index = frames.add(Frame(submit: submit, waited: submit - t0))
                n += 1
                // A brisk drag: 12 view px a frame, back and forth.
                let dx = Double((n / 120) % 2 == 0 ? 12 : -12)
                let transform = base.panned(by: CGVector(dx: dx * Double(n % 120), dy: 0))
                guard let commands = queue.makeCommandBuffer() else { fail("no command buffer") }
                MetalContext.shared.frames.track(commands)
                renderer.encode(image: image, transform: transform, into: commands, target: target)
                commands.addCompletedHandler { [frames, inFlight] cb in
                    frames.finish(index, done: CACurrentMediaTime(), gpu: cb.gpuEndTime - cb.gpuStartTime)
                    inFlight.signal()
                }
                commands.commit()
            }
        }
    }
}
