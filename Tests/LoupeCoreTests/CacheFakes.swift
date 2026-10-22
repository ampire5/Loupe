import CoreGraphics
import Foundation
@testable import LoupeCore

// Fakes for ImageCache: a reader, a decoder and a GPU loader that do no real I/O, decoding or Metal work.
// A file's bytes are its name, so the decoder knows which photo it is decoding. Decoded images carry the
// level's real pixel size but a one-page buffer (nothing reads the pixels), so 147 MP photos cost nothing.

/// A latch an async caller parks on until the test opens it, with a value or an error.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func wait() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let outcome {
                lock.unlock()
                c.resume(with: outcome)
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }

    func open(_ result: Result<Void, Error> = .success(())) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let all = waiters
        waiters = []
        lock.unlock()
        all.forEach { $0.resume(with: result) }
    }
}

/// A latch a blocking call parks its (pool) thread on until the test opens it.
final class BlockingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let sem = DispatchSemaphore(value: 0)
    private var opened = false

    func wait() {
        sem.wait()
        sem.signal()   // let every other waiter through as well
    }

    func open() {
        lock.lock(); defer { lock.unlock() }
        if opened { return }
        opened = true
        sem.signal()
    }
}

func fileURL(_ i: Int) -> URL { URL(fileURLWithPath: "/fake/\(i).jpg") }
func fileURLs(_ n: Int) -> [URL] { (0..<n).map(fileURL) }

final class FakeReader: FileReading, @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [URL: FileStamp] = [:]
    private var reads: [URL: Int] = [:]
    private var order: [URL] = []
    private var priorities: [URL: [Int]] = [:]
    private var hangs: [URL: AsyncGate] = [:]
    private var latencies: [URL: Duration] = [:]
    private var padding: [URL: Int] = [:]
    private var stampPriorityLog: [Int] = []

    /// The priorities stamp checks were queued with, in order.
    var stampPriorities: [Int] { lock.withLock { stampPriorityLog } }

    /// Reads of `url` park on `gate` until the test opens it (with an error, a timed-out read).
    func hang(_ url: URL, on gate: AsyncGate) { lock.withLock { hangs[url] = gate } }
    func setLatency(_ url: URL, _ d: Duration) { lock.withLock { latencies[url] = d } }
    func setStamp(_ url: URL, _ s: FileStamp) { lock.withLock { stamps[url] = s } }
    /// `url`'s bytes are its name followed by `bytes` zeros (the decoder stops at the first zero), so the compressed
    /// file weighs something in `usedBytes`.
    func pad(_ url: URL, _ bytes: Int) { lock.withLock { padding[url] = bytes } }
    func readCount(_ url: URL) -> Int { lock.withLock { reads[url] ?? 0 } }
    /// Every URL a read was asked for, in order (repeats included).
    var readOrder: [URL] { lock.withLock { order } }
    /// The priorities `url`'s reads were submitted with.
    func priorities(_ url: URL) -> [Int] { lock.withLock { priorities[url] ?? [] } }

    private func currentStamp(_ url: URL) -> FileStamp {
        lock.withLock { stamps[url] ?? FileStamp(modified: Date(timeIntervalSince1970: 1), size: 1000) }
    }

    func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes {
        let (gate, latency, pad) = lock.withLock { () -> (AsyncGate?, Duration?, Int) in
            reads[url, default: 0] += 1
            order.append(url)
            priorities[url, default: []].append(priority.value)
            return (hangs[url], latencies[url], padding[url] ?? 0)
        }
        if let latency { try await Task.sleep(for: latency) }
        if let gate { try await gate.wait() }
        return FileBytes(data: Data(url.lastPathComponent.utf8) + Data(count: pad), stamp: currentStamp(url))
    }

    func stamp(_ url: URL, priority: Int) async throws -> FileStamp {
        lock.withLock { stampPriorityLog.append(priority) }
        return currentStamp(url)
    }
}

/// A reader with `slots` concurrent reads and a priority queue like FileReader's: queued reads start lowest
/// priority value first (FIFO among equals, the value read when a slot frees up, so moving a read's priority box moves it). A started read of a held URL parks
/// until the test releases it.
final class QueueReader: FileReading, @unchecked Sendable {
    private struct Waiter {
        let url: URL
        let priority: ReadPriority
        let seq: Int
        let id: UUID
        let c: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private let slots: Int
    private var running = 0
    private var seq = 0
    private var queue: [Waiter] = []
    private var startOrder: [URL] = []
    private var held: [URL: AsyncGate] = [:]
    private var delayed: [URL: AsyncGate] = [:]
    private var arrived: Set<URL> = []

    init(slots: Int) { self.slots = slots }

    /// Reads of `url` park on the returned gate before they join the queue, like FileReader's hop from the caller
    /// to the pool: the gap in which a reprioritisation finds nothing queued.
    func delaySubmit(_ url: URL) -> AsyncGate { lock.withLock { let g = AsyncGate(); delayed[url] = g; return g } }
    /// Whether a read of `url` reached `read` (and, if delayed, is parked before the queue).
    func hasArrived(_ url: URL) -> Bool { lock.withLock { arrived.contains(url) } }

    /// Reads of `url` that start park until `release(url)`.
    func hold(_ url: URL) { lock.withLock { held[url] = AsyncGate() } }
    func release(_ url: URL) { lock.withLock { held[url] }?.open() }
    /// URLs in the order their reads got a slot.
    var started: [URL] { lock.withLock { startOrder } }
    var queuedCount: Int { lock.withLock { queue.count } }
    func queuedPriority(_ url: URL) -> Int? { lock.withLock { queue.first { $0.url == url }?.priority.value } }

    func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes {
        let id = UUID()
        if let gate = lock.withLock({ () -> AsyncGate? in arrived.insert(url); return delayed[url] }) {
            try await gate.wait()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                seq += 1
                if running < slots {
                    running += 1
                    startOrder.append(url)
                    lock.unlock()
                    c.resume()
                } else {
                    queue.append(Waiter(url: url, priority: priority, seq: seq, id: id, c: c))
                    lock.unlock()
                }
            }
        } onCancel: {
            let w = lock.withLock { () -> Waiter? in
                guard let i = queue.firstIndex(where: { $0.id == id }) else { return nil }
                return queue.remove(at: i)
            }
            w?.c.resume(throwing: CancellationError())
        }
        defer { finished() }
        if let gate = lock.withLock({ held[url] }) { try await gate.wait() }
        return FileBytes(data: Data(url.lastPathComponent.utf8), stamp: FileStamp(modified: Date(timeIntervalSince1970: 1), size: 1000))
    }

    private func finished() {
        let next = lock.withLock { () -> Waiter? in
            guard let i = queue.indices.min(by: { (queue[$0].priority.value, queue[$0].seq) < (queue[$1].priority.value, queue[$1].seq) }) else {
                running -= 1
                return nil
            }
            let w = queue.remove(at: i)
            startOrder.append(w.url)
            return w
        }
        next?.c.resume()
    }

    func stamp(_ url: URL, priority: Int) async throws -> FileStamp { FileStamp(modified: Date(timeIntervalSince1970: 1), size: 1000) }
}

/// One call the decoder received.
struct DecoderCall: Equatable {
    enum Kind: Equatable { case probe, firstLook, preview(Int), full }
    let name: String
    let kind: Kind
}

final class FakeDecoder: ImageDecoder, @unchecked Sendable {
    let name = "Fake"
    private let lock = NSLock()
    private var sizes: [String: PixelSize] = [:]
    private var latencies: [String: TimeInterval] = [:]
    private var failOnce: Set<String> = []
    private var log: [DecoderCall] = []
    private var finished: [String: Date] = [:]
    private var probeGates: [String: BlockingGate] = [:]
    private var decodeGates: [String: BlockingGate] = [:]
    private var fullGates: [String: BlockingGate] = [:]
    private var allDecodesGate: BlockingGate?
    private var progressive: Set<String> = []
    private var fullPreviews: Set<String> = []
    private var fullsRunning = 0
    private var fullsPeak = 0
    let defaultSize: PixelSize
    /// Previews come back at level 0, like PNG/WebP/JXL.
    var previewAtLevel0 = false
    /// When set, `firstLook` returns an image of this level; nil means the decoder has none.
    var firstLookLevel: Int?
    /// Full decodes come back in a buffer as long as the real one (64-byte-aligned rows × height), so a ready decode
    /// weighs in `usedSystemBytes` what it would in the app. Mapped and never touched, so it costs no memory.
    var fullSizedBuffers = false

    init(size: PixelSize) { defaultSize = size }

    func setSize(_ url: URL, _ s: PixelSize) { lock.withLock { sizes[url.lastPathComponent] = s } }
    /// Seconds each preview/full decode of `url` blocks its pool thread (simulated work).
    func setLatency(_ url: URL, _ t: TimeInterval) { lock.withLock { latencies[url.lastPathComponent] = t } }
    func setLatencyForAll(_ urls: [URL], _ t: TimeInterval) { urls.forEach { setLatency($0, t) } }
    /// `probe` reports `url` as a progressive JPEG.
    func setProgressive(_ url: URL) { lock.withLock { _ = progressive.insert(url.lastPathComponent) } }
    /// Previews of `url` decode the whole image first (`previewNeedsFullDecode`, like JXL without a DC image).
    func setPreviewNeedsFull(_ url: URL) { lock.withLock { _ = fullPreviews.insert(url.lastPathComponent) } }
    /// The most full decodes (full-decode previews included) that ever ran at the same time.
    var peakConcurrentFulls: Int { lock.withLock { fullsPeak } }
    func failOnce(_ url: URL) { lock.withLock { _ = failOnce.insert(url.lastPathComponent) } }
    /// `probe` of `url` blocks its pool thread on `gate` (after it is logged).
    func gateProbe(_ url: URL, _ gate: BlockingGate) { lock.withLock { probeGates[url.lastPathComponent] = gate } }
    /// Preview and full decodes of `url` block on `gate` (after they are logged).
    func gateDecodes(_ url: URL, _ gate: BlockingGate) { lock.withLock { decodeGates[url.lastPathComponent] = gate } }
    /// Full decodes of `url` (only) block on `gate`.
    func gateFull(_ url: URL, _ gate: BlockingGate) { lock.withLock { fullGates[url.lastPathComponent] = gate } }
    /// Every preview and full decode blocks on `gate`; nil lifts it for decodes not yet started.
    func gateAllDecodes(_ gate: BlockingGate?) { lock.withLock { allDecodesGate = gate } }

    var calls: [DecoderCall] { lock.withLock { log } }
    func calls(_ url: URL) -> [DecoderCall.Kind] { calls.filter { $0.name == url.lastPathComponent }.map(\.kind) }
    func finishedAt(_ url: URL) -> Date? { lock.withLock { finished[url.lastPathComponent] } }

    private func record(_ data: Data, _ kind: DecoderCall.Kind) -> String {
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        lock.withLock { log.append(DecoderCall(name: name, kind: kind)) }
        return name
    }

    private func work(_ name: String, full: Bool = false) throws {
        let (latency, fail, gates) = lock.withLock { () -> (TimeInterval, Bool, [BlockingGate]) in
            (latencies[name] ?? 0, failOnce.remove(name) != nil,
             [decodeGates[name], allDecodesGate, full ? fullGates[name] : nil].compactMap { $0 })
        }
        gates.forEach { $0.wait() }
        if latency > 0 { Thread.sleep(forTimeInterval: latency) }
        if fail { throw DecodeError.unreadable }
    }

    private func image(_ info: ImageInfo, level: Int) throws -> LevelImage {
        let size = TileGrid(imageSize: info.pixelSize).levelSize(level)
        let buffer = try PageAlignedBuffer(minimumLength: 1)
        let pixels = DecodedImage(pixelSize: size, bytesPerRow: size.width * 4, buffer: buffer,
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return LevelImage(image: pixels, level: level)
    }

    func probe(_ data: Data) throws -> ImageInfo {
        let name = record(data, .probe)
        let (size, gate, isProgressive) = lock.withLock { (sizes[name] ?? defaultSize, probeGates[name], progressive.contains(name)) }
        gate?.wait()
        return ImageInfo(pixelSize: size, typeIdentifier: "public.jpeg", isProgressive: isProgressive,
                         fileSize: data.count, colorSpaceName: nil)
    }

    func previewNeedsFullDecode(_ data: Data, info: ImageInfo, level: Int) -> Bool {
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return lock.withLock { fullPreviews.contains(name) }
    }

    func preview(_ data: Data, info: ImageInfo, level: Int) throws -> LevelImage {
        let name = record(data, .preview(level))
        let full = lock.withLock { fullPreviews.contains(name) }
        if full { lock.withLock { fullsRunning += 1; fullsPeak = max(fullsPeak, fullsRunning) } }
        defer { if full { lock.withLock { fullsRunning -= 1 } } }
        try work(name)
        defer { lock.withLock { finished[name] = Date() } }
        return try image(info, level: previewAtLevel0 ? 0 : level)
    }

    func decodeFull(_ data: Data, info: ImageInfo) throws -> DecodedImage {
        let name = record(data, .full)
        lock.withLock { fullsRunning += 1; fullsPeak = max(fullsPeak, fullsRunning) }
        defer { lock.withLock { fullsRunning -= 1 } }
        try work(name, full: true)
        defer { lock.withLock { finished[name] = Date() } }
        guard fullSizedBuffers else { return try image(info, level: 0).image }
        let size = info.pixelSize, rowBytes = (size.width * 4 + 63) / 64 * 64
        return DecodedImage(pixelSize: size, bytesPerRow: rowBytes,
                            buffer: try PageAlignedBuffer(minimumLength: rowBytes * size.height),
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    func firstLook(_ data: Data, info: ImageInfo) throws -> LevelImage? {
        guard let level = firstLookLevel else { return nil }
        _ = record(data, .firstLook)
        return try image(info, level: level)
    }
}

/// Resident levels as a set; like TiledImage, an upload of level L makes L and every coarser level resident.
final class FakePyramid: @unchecked Sendable {
    let grid: TileGrid
    /// The colour space the cache made it with.
    let colorSpace: CGColorSpace?
    private let lock = NSLock()
    private var resident: Set<Int> = []
    private var uploaded: [Int] = []

    var uploadedLevels: [Int] { lock.withLock { uploaded } }

    init(grid: TileGrid, colorSpace: CGColorSpace? = nil) {
        self.grid = grid
        self.colorSpace = colorSpace
    }

    var finest: Int? { lock.withLock { resident.min() } }
    func upload(_ level: Int) {
        lock.withLock {
            uploaded.append(level)
            resident.formUnion(level..<grid.levelCount)
        }
    }
    func evict(finerThan level: Int) { lock.withLock { resident = resident.filter { $0 >= level } } }
}

final class FakeLoader: PyramidLoader, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakePyramid] = []

    private var uploadGate: (width: Int, level: Int, gate: AsyncGate)?
    private var gatedUploadReached = false
    private var uploadsStarted = 0

    var pyramids: [FakePyramid] { lock.withLock { made } }
    /// Levels uploaded into every pyramid ever made for an image `width` px wide (tests give files distinct widths).
    func uploadedLevels(width: Int) -> [Int] {
        pyramids.filter { $0.grid.imageSize.width == width }.flatMap(\.uploadedLevels)
    }
    var startedUploads: Int { lock.withLock { uploadsStarted } }
    /// Whether the gated upload has started (and is parked on its gate).
    var gatedUploadStarted: Bool { lock.withLock { gatedUploadReached } }
    /// The next upload of `level` into an image `width` px wide parks on `gate` before its levels become resident.
    func gateNextUpload(width: Int, level: Int, _ gate: AsyncGate) { lock.withLock { uploadGate = (width, level, gate) } }

    func makePyramid(grid: TileGrid, colorSpace: CGColorSpace) -> FakePyramid {
        let p = FakePyramid(grid: grid, colorSpace: colorSpace)
        lock.withLock { made.append(p) }
        return p
    }

    func upload(_ image: LevelImage, into pyramid: FakePyramid) async throws {
        let gate = lock.withLock { () -> AsyncGate? in
            uploadsStarted += 1
            guard let g = uploadGate, g.level == image.level, g.width == pyramid.grid.imageSize.width else { return nil }
            uploadGate = nil
            gatedUploadReached = true
            return g.gate
        }
        if let gate { try await gate.wait() }
        await Task.yield()
        pyramid.upload(image.level)
    }

    func evict(finerThan level: Int, of pyramid: FakePyramid) { pyramid.evict(finerThan: level) }
    func finestResidentLevel(of pyramid: FakePyramid) -> Int? { pyramid.finest }
}

extension CacheLimits {
    /// The defaults with the 3 GB `cache-memory` the cache tests were worked out for: the default itself follows the
    /// Mac (`Machine.cacheMemory`, 1–4 GB), and a CI runner with little memory would get a smaller one.
    static var at3G: CacheLimits {
        var limits = CacheLimits()
        limits.memory = 3 << 30
        return limits
    }
}
