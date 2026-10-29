import Foundation
import LoupeCore
import LoupeRender
import Metal
import os
import QuartzCore

/// Finds the subjects of the photos for one viewer window (smart zoom spec §5), off the main thread, one photo at a
/// time, in the order of `SubjectQueue` (the photo on screen first, then up to `aheadLimit` ahead; nothing while the
/// photo on screen is decoding, which the window says with `setForegroundBusy`):
/// 1. the catalog first (`Loupe.db` keeps the boxes of photos seen before);
/// 2. else the photo drawn whole, oriented, by a `TileRenderer` of its own into a proxy of at most `proxySide` px from
///    the pyramid already on the GPU (any format, no second decode), as the subject-mask spike's `SubjectMasker` does;
/// 3. `SubjectDetector` (Vision) on it, on the finder's own serial queue; the boxes into the memory every window shares
///    and, from a proxy of at least `minimumProxy` px, into the catalog.
/// Quiet at rest: nothing polls; with nothing asked for it does nothing.
final class SubjectFinder: @unchecked Sendable {
    /// The proxy's long side: Vision's detectors work at about 1 K, and a face of 2 % of the photo's height keeps ~30 px.
    static let proxySide = 1536
    /// Boxes from a smaller proxy (a coarse level was all that was in) stay in memory only and are looked for again
    /// once a finer level is in.
    static let minimumProxy = 1024
    /// Photos analysed ahead of the one on screen. Vision on an Intel Mac runs on the CPU, several times slower, so it
    /// looks one photo ahead there (docs/bench/2026-10-28-smart-zoom.md: 11 ms a photo on M4 Max, Intel not measured).
    #if arch(x86_64)
    static let aheadLimit = 1
    #else
    static let aheadLimit = 3
    #endif
    /// Boxes kept in memory: a few dozen bytes each.
    static let cacheLimit = 64

    /// The boxes found, for every window: a lock and a short scan.
    private static let memory = OSAllocatedUnfairLock<[(url: URL, boxes: SubjectBoxes)]>(initialState: [])

    private static func searched(_ setup: DetectorSetup) -> [SubjectKind] {
        SubjectKind.vision + (setup.detects ? setup.kinds : [])
    }
    static func boxes(for url: URL, applied: Bool, setup: DetectorSetup) -> SubjectBoxes? {
        memory.withLock { m in m.last { $0.url == url && $0.boxes.analysisID == setup.analysisID
            && $0.boxes.applied == applied }?.boxes }
    }

    private struct Job: SubjectJob {
        let url: URL
        let image: TiledImage
        let orientation: ImageOrientation
        let applied: Bool
        let setup: DetectorSetup
        var ahead: Bool
        var urgent: Bool
        var done: [@MainActor (SubjectBoxes?) -> Void]

        mutating func merge(_ other: Job) {
            guard setup.analysisID == other.setup.analysisID else { self = other; return }
            ahead = ahead && other.ahead
            urgent = urgent || other.urgent
            done += other.done
        }
    }

    /// The catalog's boxes for a photo, and keeping found ones there (the thumbnail store).
    private let stored: @Sendable (URL) async -> SubjectBoxes?
    private let keep: @Sendable (URL, SubjectBoxes) async -> Void
    private struct State {
        var queue = SubjectQueue<Job>(aheadLimit: SubjectFinder.aheadLimit)
        /// The photo being analysed, and the asks that came for it meanwhile.
        var runningURL: URL?
        var runningID: String?
        var runningDone: [@MainActor (SubjectBoxes?) -> Void] = []
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    /// Vision and the proxy's drawing block their thread: a queue of their own, not the cooperative pool.
    private let work = DispatchQueue(label: "Loupe subjects", qos: .utility)
    private let context = MetalContext.shared
    private lazy var renderer = TileRenderer(context: context, pixelFormat: .bgra8Unorm_srgb)   // on `work` only
    private lazy var commands = context.device.makeCommandQueue()

    init(stored: @escaping @Sendable (URL) async -> SubjectBoxes?, keep: @escaping @Sendable (URL, SubjectBoxes) async -> Void) {
        self.stored = stored
        self.keep = keep
    }

    /// Asks for the subjects of `url`, drawn from `image` (`applied`: `exif-orientation`). Boxes known and good enough
    /// for what `image` holds come back at once (`done` on main); else the photo waits in the queue.
    func request(_ url: URL, image: TiledImage, orientation: ImageOrientation, applied: Bool,
                 setup: DetectorSetup, ahead: Bool, urgent: Bool = false, done: @escaping @MainActor (SubjectBoxes?) -> Void) {
        guard let side = Self.side(image) else { return }
        if let known = Self.boxes(for: url, applied: applied, setup: setup),
           known.proxySide >= min(Self.minimumProxy, side) {
            DispatchQueue.main.async { done(known) }
            return
        }
        let job = Job(url: url, image: image, orientation: orientation, applied: applied, setup: setup, ahead: ahead,
                      urgent: urgent, done: [done])
        // The photo being analysed now: this ask waits for that answer.
        let joined = state.withLockUnchecked { s -> Bool in
            guard s.runningURL == url && s.runningID == setup.analysisID else { s.queue.ask(job, ahead: ahead); return false }
            s.runningDone.append(done)
            return true
        }
        if !joined { next() }
    }

    /// The crop check's asks: only the latest runs (a zoom that moved on leaves the ones before it).
    private let cropGeneration = OSAllocatedUnfairLock(initialState: 0)

    /// The crop check (`SubjectCrop`): Vision on `region` of the photo, drawn from what the pyramid holds there at up
    /// to `proxySide` px; the boxes come back in the whole photo's space and are kept nowhere. An ask replaces the one
    /// waiting; on the finder's own queue, at `.utility`, after whatever runs there.
    func requestCrop(image: TiledImage, orientation: ImageOrientation, region: CGRect, setup: DetectorSetup,
                     done: @escaping @MainActor (SubjectBoxes?) -> Void) {
        let generation = cropGeneration.withLock { $0 += 1; return $0 }
        work.async { [self] in
            guard cropGeneration.withLock({ $0 }) == generation else { return }
            let t0 = CACurrentMediaTime()
            let oriented = orientation.orientedSize(image.grid.imageSize)
            let size = CGSize(width: oriented.width, height: oriented.height)
            let proxy = SubjectCrop.proxySize(region, imageSize: size, side: Self.proxySide)
            let transform = SubjectCrop.proxyTransform(region, imageSize: size, proxy: proxy)
            var boxes = drawProxy(image, orientation: orientation, transform: transform,
                                  width: Int(proxy.width), height: Int(proxy.height))
                .flatMap { SubjectDetector.boxes(from: $0, chain: Self.searched(setup), detector: setup.detects ? setup : nil) }
            boxes?.analysisID = setup.analysisID
            boxes?.proxySide = Int(max(proxy.width, proxy.height))
            let result = boxes.map { SubjectCrop.inPhoto($0, region: region) }
            DebugLog.log(String(format: "subjects crop %.2f×%.2f: %.0f ms", region.width, region.height,
                                (CACurrentMediaTime() - t0) * 1000))
            DispatchQueue.main.async { done(result) }
        }
    }

    /// The photo on screen is still decoding (the window says so on every change): nothing starts meanwhile; freeing it
    /// starts the next job.
    func setForegroundBusy(_ busy: Bool) {
        state.withLockUnchecked { $0.queue.busy = busy }
        if !busy { next() }
    }

    /// Drops the waiting photos not in `urls` (a step left them behind, the analysis was turned off).
    func keepOnly(_ urls: Set<URL>) {
        state.withLockUnchecked { $0.queue.keepOnly(urls) }
    }

    /// Starts the next job unless one runs, the foreground is busy or nothing waits.
    private func next() {
        guard let job = state.withLockUnchecked({ s -> Job? in
            guard let job = s.queue.take() else { return nil }
            s.runningURL = job.url
            s.runningID = job.setup.analysisID
            return job
        }) else { return }
        Task.detached(priority: job.urgent ? .userInitiated : .utility) { [self] in
            let t0 = CACurrentMediaTime()
            var boxes = await stored(job.url)
            let fromCatalog = boxes != nil && boxes?.analysisID == job.setup.analysisID && boxes?.searched == Self.searched(job.setup) && boxes?.applied == job.applied
            if !fromCatalog {
                boxes = await withCheckedContinuation { continuation in
                    work.async(qos: job.urgent ? .userInitiated : .utility) { continuation.resume(returning: self.analyse(job)) }
                }
            }
            if let boxes {
                Self.memory.withLock { m in
                    m.removeAll { $0.url == job.url && $0.boxes.analysisID == job.setup.analysisID }
                    m.append((job.url, boxes))
                    if m.count > Self.cacheLimit { m.removeFirst(m.count - Self.cacheLimit) }
                }
                if !fromCatalog, boxes.proxySide >= Self.minimumProxy || boxes.proxySide >= Self.fullSide(job) {
                    await keep(job.url, boxes)
                }
            }
            DebugLog.log(String(format: "subjects %@%@: %.0f ms, %@", job.url.lastPathComponent, job.ahead ? " (ahead)" : "",
                                (CACurrentMediaTime() - t0) * 1000,
                                fromCatalog ? "catalog" : boxes.map { "\($0.proxySide) px" } ?? "failed"))
            let result = boxes
            let done = state.withLockUnchecked { s -> [@MainActor (SubjectBoxes?) -> Void] in
                defer { s.runningURL = nil; s.runningID = nil; s.runningDone = []; s.queue.finish() }
                return job.done + s.runningDone
            }
            await MainActor.run { for d in done { d(result) } }
            next()
        }
    }

    /// The proxy's side for what `image` holds now: the finest resident level's long side, at most `proxySide`.
    private static func side(_ image: TiledImage) -> Int? {
        guard let level = image.finestResidentLevel else { return nil }
        let size = image.grid.levelSize(level)
        return min(proxySide, max(size.width, size.height))
    }

    /// The photo's own long side, at most `proxySide`: a small photo's proxy is all there is.
    private static func fullSide(_ job: Job) -> Int {
        min(proxySide, max(job.image.grid.imageSize.width, job.image.grid.imageSize.height))
    }

    /// The proxy drawn and looked at; nil when it cannot be drawn or Vision failed.
    private func analyse(_ job: Job) -> SubjectBoxes? {
        guard let side = Self.side(job.image) else { return nil }
        let oriented = job.orientation.orientedSize(job.image.grid.imageSize)
        let k = min(1, Double(side) / Double(max(oriented.width, oriented.height)))
        let w = max(1, Int((Double(oriented.width) * k).rounded())), h = max(1, Int((Double(oriented.height) * k).rounded()))
        let transform = ViewTransform(imageSize: CGSize(width: oriented.width, height: oriented.height),
                                      viewSize: CGSize(width: w, height: h))
        guard let cg = drawProxy(job.image, orientation: job.orientation, transform: transform, width: w, height: h),
              var boxes = SubjectDetector.boxes(from: cg, chain: Self.searched(job.setup), detector: job.setup.detects ? job.setup : nil) else { return nil }
        boxes.analysisID = job.setup.analysisID
        boxes.applied = job.applied
        boxes.proxySide = max(w, h)
        return boxes
    }

    /// The photo, oriented, fitted into `width`×`height`, by the same paths as the screen, read back as a `CGImage`
    /// (a texture the CPU can read: shared on Apple silicon, managed and synchronised on an Intel Mac).
    private func drawProxy(_ image: TiledImage, orientation: ImageOrientation, transform: ViewTransform,
                           width: Int, height: Int) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        #if arch(x86_64)
        d.storageMode = .managed
        #else
        d.storageMode = .shared
        #endif
        guard let target = context.device.makeTexture(descriptor: d), let commandBuffer = commands?.makeCommandBuffer() else {
            return nil
        }
        renderer.encode(image: image, transform: transform, orientation: orientation, into: commandBuffer, target: target)
        #if arch(x86_64)
        if let blit = commandBuffer.makeBlitCommandEncoder() { blit.synchronize(resource: target); blit.endEncoding() }
        #endif
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        let bytesPerRow = width * 4
        guard let data = CFDataCreateMutable(nil, bytesPerRow * height) else { return nil }
        CFDataSetLength(data, bytesPerRow * height)
        target.getBytes(CFDataGetMutableBytePtr(data), bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0)
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
