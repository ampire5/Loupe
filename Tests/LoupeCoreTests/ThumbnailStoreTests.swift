import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

/// A latch a read parks on until the test opens it; cancelling the reading task ends the wait with
/// `CancellationError`, as cancelling a real `FileReader` read does.
final class HoldGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelled: Set<UUID> = []

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if opened {
                    lock.unlock()
                    c.resume()
                } else if cancelled.contains(id) {
                    lock.unlock()
                    c.resume(throwing: CancellationError())
                } else {
                    waiters[id] = c
                    lock.unlock()
                }
            }
        } onCancel: {
            let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                cancelled.insert(id)
                return waiters.removeValue(forKey: id)
            }
            c?.resume(throwing: CancellationError())
        }
    }

    func open() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            opened = true
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        all.forEach { $0.resume() }
    }
}

/// Serves real JPEG bytes from memory and records what was asked. `readPrefix` stops in 512-byte steps
/// as soon as `isEnough` accepts, like `FileReader` on a share.
final class ThumbReader: FileReading, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [URL: Data] = [:]
    private var failing: Set<URL> = []
    private var holds: [URL: HoldGate] = [:]
    private var log: [URL] = []
    private var fullLog: [URL] = []
    private var cancelledLog: [URL] = []
    private var priorityLog: Set<Int> = []
    private var running = 0
    private var peak = 0
    private var latency: Duration = .zero

    func add(_ url: URL, _ data: Data) { lock.withLock { contents[url] = data } }
    func fail(_ url: URL) { lock.withLock { _ = failing.insert(url) } }
    func setLatency(_ d: Duration) { lock.withLock { latency = d } }
    /// Reads of `url` park on the returned gate until it opens (or the read is cancelled).
    func hold(_ url: URL) -> HoldGate { lock.withLock { let g = HoldGate(); holds[url] = g; return g } }

    func stamp(of url: URL) -> FileStamp {
        FileStamp(modified: Date(timeIntervalSinceReferenceDate: 700_000_000.5),
                  size: lock.withLock { contents[url]?.count ?? 0 })
    }
    var stamps: [URL: FileStamp] { Dictionary(uniqueKeysWithValues: lock.withLock { Array(contents.keys) }.map { ($0, stamp(of: $0)) }) }
    func data(_ url: URL) -> Data? { lock.withLock { contents[url] } }

    /// Every read asked for (prefix or whole), in order.
    var reads: [URL] { lock.withLock { log } }
    /// Whole-file `read` calls only.
    var fullReads: [URL] { lock.withLock { fullLog } }
    var cancelled: [URL] { lock.withLock { cancelledLog } }
    var priorities: Set<Int> { lock.withLock { priorityLog } }
    var peakConcurrent: Int { lock.withLock { peak } }
    func readCount(_ url: URL) -> Int { reads.filter { $0 == url }.count }

    private func serve(_ url: URL, priority: ReadPriority, full: Bool) async throws -> Data {
        let (gate, wait) = lock.withLock { () -> (HoldGate?, Duration) in
            log.append(url)
            if full { fullLog.append(url) }
            priorityLog.insert(priority.value)
            running += 1
            peak = max(peak, running)
            return (holds[url], latency)
        }
        defer { lock.withLock { running -= 1 } }
        do {
            if wait > .zero { try await Task.sleep(for: wait) }
            try await gate?.wait()
        } catch {
            lock.withLock { cancelledLog.append(url) }
            throw error
        }
        let (data, fails) = lock.withLock { (contents[url], failing.contains(url)) }
        guard let data, !fails else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }

    func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes {
        FileBytes(data: try await serve(url, priority: priority, full: true), stamp: stamp(of: url))
    }

    func readPrefix(_ url: URL, priority: ReadPriority, isEnough: @escaping @Sendable (Data) -> Bool) async throws -> FileBytes {
        let data = try await serve(url, priority: priority, full: false)
        for n in stride(from: 512, to: data.count, by: 512) where isEnough(data.prefix(n)) {
            return FileBytes(data: Data(data.prefix(n)), stamp: stamp(of: url))
        }
        return FileBytes(data: data, stamp: stamp(of: url))
    }

    func stamp(_ url: URL, priority: Int) async throws -> FileStamp { stamp(of: url) }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    var get: T { lock.withLock { value } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
}

@Suite struct ThumbnailStoreTests {
    private let fm = FileManager.default

    private func tempDir() -> URL {
        fm.temporaryDirectory.appendingPathComponent("loupe-thumbstore-\(UUID().uuidString)")
    }

    /// `count` small JPEGs in `folder`, each a few pixels wider than the last so they differ.
    private func photos(_ count: Int, folder: String = "/photos/a", in reader: ThumbReader,
                        progressive: Bool = false, width: Int = 40) -> [URL] {
        (0..<count).map { i in
            let url = URL(fileURLWithPath: "\(folder)/\(i).jpg")
            reader.add(url, TestJPEGs.gradient(width: width + i % 8, height: 30, progressive: progressive))
            return url
        }
    }

    private static let testLocate: @Sendable (URL) -> ThumbnailLocation? = { url in
        ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
    }

    private func store(_ reader: ThumbReader, dir: URL?, limit: Int = 1 << 30, thumbSize: Int = 32,
                       idleDelay: Duration = .zero, commitDelay: Duration = .seconds(3600), decodes: Int = 1,
                       decoder: @escaping @Sendable (Data) -> any ImageDecoder = DecoderRegistry.decoder(for:),
                       cachedBytes: @escaping @Sendable (URL, FileStamp) async -> Data? = { _, _ in nil },
                       locate: @escaping @Sendable (URL) -> ThumbnailLocation? = testLocate,
                       memoryCap: Int = ThumbnailStore.defaultMemoryCap,
                       log: (@Sendable (String) -> Void)? = nil) -> ThumbnailStore {
        ThumbnailStore(directory: dir, reader: reader, thumbSize: thumbSize, limitBytes: limit,
                       decoder: decoder, cachedBytes: cachedBytes, locate: locate, idleDelay: idleDelay,
                       commitDelay: commitDelay, decodes: decodes, memoryCap: memoryCap, log: log)
    }

    private func request(_ files: [URL], current: Int = 0, visible: [Int] = [], isKey: Bool = true) -> ThumbnailRequest {
        ThumbnailRequest(files: files, current: current, visible: visible, isKey: isKey)
    }

    /// Polls `condition` every 2 ms until it holds or `timeout` passes.
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    /// Checked on the store's actor in one go: asked file by file, the answers could straddle a change (a database
    /// made anew between two files), and add up to a state the store was never in.
    private func allReady(_ store: ThumbnailStore, _ files: [URL]) async -> Bool {
        await Self.allReady(store, files)
    }

    private static func allReady(_ store: isolated ThumbnailStore, _ files: [URL]) -> Bool {
        files.allSatisfy { store.status($0) == .ready }
    }

    /// Everything generated is ready and written to the database, at one moment.
    private func settled(_ store: ThumbnailStore, _ files: [URL]) async -> Bool {
        await Self.settled(store, files)
    }

    private static func settled(_ store: isolated ThumbnailStore, _ files: [URL]) -> Bool {
        allReady(store, files) && store.pendingWrites == 0
    }

    // MARK: - Gating

    @Test func generatesWhenIdleOnly() async throws {
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        let store = store(reader, dir: nil)
        await store.setViewerActivity(.neighbours)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        try await Task.sleep(for: .milliseconds(50))
        #expect(reader.reads.isEmpty)
        #expect(await store.status(files[0]) == .pending)

        await store.setViewerActivity(.idle)
        #expect(await eventually { await allReady(store, files) })
        #expect(reader.priorities == [1_000_000])
    }

    @Test func idleMustHoldBeforeReading() async throws {
        let reader = ThumbReader()
        let files = photos(1, in: reader)
        let store = store(reader, dir: nil, idleDelay: .milliseconds(300))
        await store.setViewerActivity(.neighbours)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        let idleAt = ContinuousClock.now
        await store.setViewerActivity(.idle)
        try await Task.sleep(for: .milliseconds(30))
        #expect(reader.reads.isEmpty)
        #expect(await eventually { !reader.reads.isEmpty })
        #expect(ContinuousClock.now - idleAt >= .milliseconds(300))
    }

    @Test func currentCancelsAll() async throws {
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        let gates = files.map { reader.hold($0) }
        let store = store(reader, dir: nil)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { reader.reads.count == 2 })

        await store.setViewerActivity(.current)
        #expect(await eventually { Set(reader.cancelled) == Set(files[..<2]) })
        #expect(await store.status(files[0]) == .pending)
        #expect(await store.status(files[1]) == .pending)
        try await Task.sleep(for: .milliseconds(30))
        #expect(reader.reads.count == 2)          // nothing new while the viewer reads

        gates.forEach { $0.open() }
        await store.setViewerActivity(.idle)
        #expect(await eventually { await allReady(store, files) })
        #expect(reader.readCount(files[0]) == 2 && reader.readCount(files[1]) == 2)   // re-queued, read again
        #expect(reader.readCount(files[2]) == 1)
    }

    @Test func neighboursStopNewReadsOnly() async throws {
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        let gates = files[..<2].map { reader.hold($0) }
        let store = store(reader, dir: nil)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { reader.reads.count == 2 })
        await store.setViewerActivity(.neighbours)
        gates.forEach { $0.open() }
        #expect(await eventually { await allReady(store, Array(files[..<2])) })   // the reads in flight finished
        try await Task.sleep(for: .milliseconds(30))
        #expect(reader.readCount(files[2]) == 0)
        #expect(reader.cancelled.isEmpty)
    }

    @Test func twoReadsInFlight() async throws {
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        let gates = files.map { reader.hold($0) }
        let store = store(reader, dir: nil)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { reader.reads.count == 2 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(Set(reader.reads) == Set(files[..<2]))   // the third waits
        gates[0].open()
        #expect(await eventually { reader.reads.count == 3 })
        #expect(reader.reads.last == files[2])
        gates.forEach { $0.open() }
        #expect(await eventually { await allReady(store, files) })
        #expect(reader.peakConcurrent == 2)
    }

    @Test func neverMoreThanTwoReads() async throws {
        let reader = ThumbReader()
        reader.setLatency(.milliseconds(3))
        let files = photos(8, in: reader)
        let store = store(reader, dir: nil)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        await store.setRequest(window: 2, request(Array(files.reversed()), isKey: false), stamps: reader.stamps)
        #expect(await eventually { await allReady(store, files) })
        #expect(reader.peakConcurrent <= 2)
        for url in files { #expect(reader.readCount(url) == 1) }
    }

    /// The decode of a finished read does not hold up the next read; but at most one job beyond the two reads,
    /// so the bytes waiting for a decode stay bounded.
    @Test func decodeOverlapsNextRead() async throws {
        let reader = ThumbReader()
        let files = photos(5, in: reader)
        let readGates = files[1...].map { reader.hold($0) }
        let decodeGate = BlockingGate()
        defer { decodeGate.open() }
        let gated = Set([reader.data(files[0])!, reader.data(files[1])!])
        let store = store(reader, dir: nil, decoder: { data in
            if gated.contains(data) { decodeGate.wait() }
            return DecoderRegistry.decoder(for: data)
        })
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        // files[0] is read and stuck in its decode; files[1] and files[2] are read meanwhile.
        #expect(await eventually { reader.reads.count == 3 })
        #expect(Set(reader.reads) == Set(files[..<3]))
        #expect(await store.status(files[0]) == .pending)

        readGates[0].open()   // files[1] read: its decode waits for the one decode, three jobs in all: no files[3]
        try await Task.sleep(for: .milliseconds(40))
        #expect(reader.reads.count == 3)

        decodeGate.open()
        readGates.forEach { $0.open() }
        #expect(await eventually { await allReady(store, files) })
        #expect(reader.peakConcurrent <= 2)
    }

    /// With one decode slot the second finished read waits for the first decode.
    @Test func oneDecodeAtATime() async throws {
        let reader = ThumbReader()
        let files = photos(2, in: reader)
        let decodeGate = BlockingGate()
        defer { decodeGate.open() }
        let entered = Locked(0)
        let store = store(reader, dir: nil, decoder: { data in
            entered.update { $0 += 1 }
            decodeGate.wait()
            return DecoderRegistry.decoder(for: data)
        })
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { reader.reads.count == 2 })
        #expect(await eventually { await store.readsInFlight == 0 })   // both read
        #expect(await eventually { entered.get == 1 })
        try await Task.sleep(for: .milliseconds(40))
        #expect(entered.get == 1)   // the other decode waits for the slot
        decodeGate.open()
        #expect(await eventually { await allReady(store, files) })
    }

    /// Half the physical cores less one, 1 to 4.
    @Test func decodesFollowTheCores() {
        #expect([2, 4, 6, 8, 10, 12, 24].map { ThumbnailStore.decodes(physicalCores: $0) } == [1, 1, 2, 3, 4, 4, 4])
    }

    /// With reads that cost nothing (a local disk) the decodes are the limit: `decodes` of them run side by side, and
    /// one job more holds its bytes, read, until a slot frees.
    @Test func decodesSideBySide() async throws {
        let reader = ThumbReader()
        let files = photos(6, in: reader)
        let decodeGate = BlockingGate()
        defer { decodeGate.open() }
        let entered = Locked(0)
        let store = store(reader, dir: nil, decodes: 3, decoder: { data in
            entered.update { $0 += 1 }
            decodeGate.wait()
            return DecoderRegistry.decoder(for: data)
        })
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { entered.get == 3 })
        #expect(await eventually { reader.reads.count == 4 })
        try await Task.sleep(for: .milliseconds(40))
        #expect(entered.get == 3)
        #expect(reader.reads.count == 4)
        decodeGate.open()
        #expect(await eventually { await allReady(store, files) })
    }

    /// `.current` cancels the reads, not the decodes: a file already read is made, not read again, even while its
    /// decode still waits for the decode slot.
    @Test func currentLetsDecodesFinish() async throws {
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        let second = reader.hold(files[1])
        let gate = reader.hold(files[2])
        let decodeGate = BlockingGate()
        defer { decodeGate.open() }
        let first = reader.data(files[0])!
        let decoding = Locked(false)
        let store = store(reader, dir: nil, decoder: { data in
            if data == first {
                decoding.update { $0 = true }
                decodeGate.wait()
            }
            return DecoderRegistry.decoder(for: data)
        })
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        // files[0] decoding, files[1] read and waiting for the decode slot, files[2] reading.
        #expect(await eventually { reader.reads.count == 3 && decoding.get })
        second.open()
        #expect(await eventually { await store.readsInFlight == 1 })
        await store.setViewerActivity(.current)
        #expect(await eventually { reader.cancelled == [files[2]] })
        decodeGate.open()
        #expect(await eventually { await allReady(store, Array(files[..<2])) })
        #expect(reader.readCount(files[0]) == 1 && reader.readCount(files[1]) == 1)
        gate.open()
        await store.setViewerActivity(.idle)
        #expect(await eventually { await allReady(store, files) })
    }

    /// A prefix whose decode ends while the current photo needs I/O does not go on to read the whole file.
    @Test func coarsePrefixDuringCurrentDoesNotReadOn() async throws {
        let reader = ThumbReader()
        let coarse = photos(1, folder: "/photos/a/p", in: reader, progressive: true, width: 160)   // below 8 x 32
        let whole = reader.data(coarse[0])!.count
        let decodeGate = BlockingGate()
        defer { decodeGate.open() }
        let entered = Locked(0)
        let store = store(reader, dir: nil, decoder: { data in
            if data.count < whole {   // the prefix
                entered.update { $0 += 1 }
                decodeGate.wait()
            }
            return DecoderRegistry.decoder(for: data)
        })
        await store.setRequest(window: 1, request(coarse), stamps: reader.stamps)
        #expect(await eventually { entered.get == 1 })
        await store.setViewerActivity(.current)
        decodeGate.open()
        try await Task.sleep(for: .milliseconds(40))
        #expect(reader.fullReads.isEmpty)
        #expect(await store.status(coarse[0]) == .pending)
        await store.setViewerActivity(.idle)
        #expect(await eventually { await allReady(store, coarse) })
        #expect(reader.fullReads == coarse)
    }

    /// A job parked for its whole-file read (after a coarse prefix) is cancelled by `.current` like a reading one,
    /// and made later from a new read.
    @Test func currentCancelsAParkedRead() async throws {
        let reader = ThumbReader()
        let coarse = photos(1, folder: "/photos/a/p", in: reader, progressive: true, width: 160)   // below 8 x 32
        let others = photos(2, in: reader)
        let gates = others.map { reader.hold($0) }
        let files = coarse + others
        let store = store(reader, dir: nil)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { reader.reads.count == 3 })   // the prefix, then both others; the full read waits
        #expect(await eventually { await store.readWaiters.count == 1 })
        await store.setViewerActivity(.current)
        #expect(await eventually { Set(reader.cancelled) == Set(others) })
        gates.forEach { $0.open() }                              // reads freed: the parked one must not go now
        try await Task.sleep(for: .milliseconds(40))
        #expect(reader.fullReads.isEmpty)
        #expect(reader.reads.count == 3)
        #expect(await store.status(coarse[0]) == .pending)

        await store.setViewerActivity(.idle)
        #expect(await eventually { await allReady(store, files) })
        #expect(reader.fullReads == coarse)
        #expect(reader.readCount(coarse[0]) == 3)   // prefix, prefix again, whole file
    }

    /// A new thumbnail size cancels both jobs in flight; their files are made again at the new size.
    @Test func sizeChangeCancelsBothJobs() async throws {
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        let gates = files[..<2].map { reader.hold($0) }
        let store = store(reader, dir: tempDir(), commitDelay: .zero)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { reader.reads.count == 2 })
        await store.setSettings(thumbSize: 16, limitBytes: 1 << 30)
        #expect(await eventually { Set(reader.cancelled) == Set(files[..<2]) })
        gates.forEach { $0.open() }
        #expect(await eventually { await settled(store, files) })
        for url in files {
            let image = try #require(await store.image(url))
            #expect(max(image.width, image.height) == 16)
        }
        #expect(reader.readCount(files[0]) == 2 && reader.readCount(files[1]) == 2)
    }

    /// The whole-file read after a coarse progressive prefix is a read like any other: it waits for a free one.
    @Test func secondReadWaitsForAFreeRead() async throws {
        let reader = ThumbReader()
        let coarse = photos(1, folder: "/photos/a/p", in: reader, progressive: true, width: 160)   // below 8 x 32
        let others = photos(2, in: reader)
        let gates = others.map { reader.hold($0) }
        let files = coarse + others
        let store = store(reader, dir: nil)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { reader.reads.count == 3 })   // the prefix, then both others
        try await Task.sleep(for: .milliseconds(30))
        #expect(reader.fullReads.isEmpty)
        gates[0].open()
        #expect(await eventually { reader.fullReads == coarse })
        gates[1].open()
        #expect(await eventually { await allReady(store, files) })
        #expect(reader.peakConcurrent == 2)
    }

    @Test func logsEachFile() async throws {
        let reader = ThumbReader()
        let prefix = photos(1, folder: "/photos/p", in: reader, progressive: true, width: 400)
        let full = photos(1, in: reader)
        let lines = Locked<[String]>([])
        let store = store(reader, dir: nil, log: { line in lines.update { $0.append(line) } })
        await store.setRequest(window: 1, request(prefix + full), stamps: reader.stamps)
        #expect(await eventually { await allReady(store, prefix + full) })
        let all = lines.get.sorted()
        #expect(all.count == 2)
        #expect(all.allSatisfy { $0.hasPrefix("thumb 0.jpg: read ") && $0.contains("), decode ") && $0.hasSuffix(" ms") })
        #expect(all.contains { $0.contains(" ms (prefix), ") })
        #expect(all.contains { $0.contains(" ms (full), ") })
    }

    @Test func unstampedFilesWaitForTheListing() async throws {
        let reader = ThumbReader()
        let files = photos(2, in: reader)
        let store = store(reader, dir: tempDir())
        await store.setRequest(window: 1, request([files[0]]), stamps: [:])   // the interim one-file playlist
        try await Task.sleep(for: .milliseconds(40))
        #expect(reader.reads.isEmpty)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await allReady(store, files) })
    }

    // MARK: - Sources

    @Test func secondOpenComesFromDB() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        let first = store(reader, dir: dir, commitDelay: .milliseconds(5))
        await first.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(first, files) })

        let again = ThumbReader()
        for url in files { again.add(url, reader.data(url)!) }
        let second = store(again, dir: dir)
        await second.setRequest(window: 1, request(files), stamps: again.stamps)
        for url in files {
            #expect(await second.status(url) == .ready)
            let cell = try #require(await second.cell(url, maxPixel: 16))
            #expect(max(cell.width, cell.height) == 16)
            let image = try #require(await second.image(url))
            #expect(max(image.width, image.height) == 32)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(again.reads.isEmpty)
    }

    @Test func cachedBytesSourceSkipsRead() async throws {
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        let cached = reader.data(files[1])!
        let target = files[1]
        let store = store(reader, dir: nil, cachedBytes: { url, _ in url == target ? cached : nil })
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await allReady(store, files) })
        #expect(reader.readCount(files[1]) == 0)
        #expect(reader.readCount(files[0]) == 1 && reader.readCount(files[2]) == 1)
    }

    /// A photo re-saved since the viewer read it: the viewer cache still holds its old bytes under the old stamp,
    /// and the new listing has another one. The thumbnail comes from a read of the new file, not the old bytes,
    /// and that is what the database keeps under the new stamp.
    @Test func resavedPhotoIsMadeFromTheNewFileNotTheViewersOldBytes() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let url = URL(fileURLWithPath: "/photos/a/0.jpg")
        let oldBytes = TestJPEGs.gradient(width: 40, height: 30)
        let reader = ThumbReader()
        reader.add(url, oldBytes)
        let oldStamp = reader.stamp(of: url)
        let first = store(reader, dir: dir, commitDelay: .milliseconds(5))
        await first.setRequest(window: 1, request([url]), stamps: reader.stamps)
        #expect(await eventually { await settled(first, [url]) })

        let resaved = ThumbReader()
        resaved.add(url, TestJPEGs.gradient(width: 30, height: 40))   // portrait now, another size
        #expect(resaved.stamp(of: url) != oldStamp)
        // Hands out bytes only for the stamp they were read at, as `ImageCache.cachedBytes(_:stamp:)` does.
        let cache: @Sendable (URL, FileStamp) async -> Data? = { u, stamp in u == url && stamp == oldStamp ? oldBytes : nil }
        let second = store(resaved, dir: dir, commitDelay: .milliseconds(5), cachedBytes: cache)
        await second.setRequest(window: 1, request([url]), stamps: resaved.stamps)
        #expect(await eventually { await settled(second, [url]) })
        #expect(resaved.readCount(url) == 1)
        let made = try #require(await second.image(url))
        #expect(made.height > made.width)

        let again = ThumbReader()
        again.add(url, resaved.data(url)!)
        let third = store(again, dir: dir, cachedBytes: cache)
        await third.setRequest(window: 1, request([url]), stamps: again.stamps)
        #expect(await third.status(url) == .ready)
        let stored = try #require(await third.image(url))
        #expect(stored.height > stored.width)
        #expect(again.reads.isEmpty)
    }

    @Test func progressivePrefixReadsOnlyTheStart() async throws {
        let reader = ThumbReader()
        let files = photos(1, in: reader, progressive: true, width: 400)   // long side >= 8 x 32
        let store = store(reader, dir: nil)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await allReady(store, files) })
        #expect(reader.reads == files)
        #expect(reader.fullReads.isEmpty)
        let image = try #require(await store.image(files[0]))
        #expect(max(image.width, image.height) == 32)
    }

    /// A big transcoded JPEG in JXL: its thumbnail comes from the start of the file, up to its DC image.
    @Test(.enabled(if: TestJXL.available)) func jxlPrefixReadsOnlyTheStart() async throws {
        let reader = ThumbReader()
        let url = URL(fileURLWithPath: "/photos/a/0.jxl")
        let data = try TestJXL.encode(TestJPEGs.gradient(width: 2400, height: 1800), inputName: "in.jpg")
        reader.add(url, data)
        let lines = Locked<[String]>([])
        let store = store(reader, dir: nil, log: { line in lines.update { $0.append(line) } })
        await store.setRequest(window: 1, request([url]), stamps: reader.stamps)
        #expect(await eventually { await allReady(store, [url]) })
        #expect(reader.fullReads.isEmpty)
        #expect(lines.get.contains { $0.contains("(prefix)") }, "\(lines.get)")
        let image = try #require(await store.image(url))
        #expect(max(image.width, image.height) == 32)
    }

    @Test func coarsePrefixReadsTheWholeFile() async throws {
        let reader = ThumbReader()
        let files = photos(1, in: reader, progressive: true, width: 160)   // below 8 x 32: DC alone is soft
        let store = store(reader, dir: nil)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await allReady(store, files) })
        #expect(reader.fullReads == files)
    }

    // MARK: - Windows and order

    @Test func twoWindowsOneRead() async throws {
        let reader = ThumbReader()
        let files = photos(5, in: reader)
        let store = store(reader, dir: tempDir())
        await store.setViewerActivity(.neighbours)
        await store.setRequest(window: 1, request(files, current: 0), stamps: reader.stamps)
        await store.setRequest(window: 2, request(files, current: 4, isKey: false), stamps: reader.stamps)
        await store.setViewerActivity(.idle)
        #expect(await eventually { await allReady(store, files) })
        for url in files { #expect(reader.readCount(url) == 1) }
    }

    @Test func keyWindowFirst() async throws {
        let reader = ThumbReader()
        let back = photos(3, folder: "/photos/back", in: reader)
        let front = photos(3, folder: "/photos/front", in: reader)
        let expected = [front[2], front[1], front[0]] + back
        let gates = Dictionary(uniqueKeysWithValues: expected.map { ($0, reader.hold($0)) })
        let store = store(reader, dir: tempDir())
        await store.setViewerActivity(.neighbours)
        await store.setRequest(window: 1, request(back, isKey: false), stamps: reader.stamps)
        await store.setRequest(window: 2, request(front, current: 1, visible: [2], isKey: true), stamps: reader.stamps)
        await store.setViewerActivity(.idle)
        // Two reads start together; after that each finished one lets exactly the next file in.
        #expect(await eventually { reader.reads.count == 2 })
        #expect(Set(reader.reads) == Set(expected[..<2]))
        for i in 0..<4 {
            gates[expected[i]]!.open()
            #expect(await eventually { reader.reads.count == i + 3 })
            #expect(reader.reads.last == expected[i + 2])
        }
        gates.values.forEach { $0.open() }
        #expect(await eventually { await allReady(store, back + front) })
    }

    @Test func replacedFolderDropsStaleQueue() async throws {
        let reader = ThumbReader()
        let files = photos(6, in: reader)
        let stale = Array(files[0..<3]), fresh = Array(files[3...])
        for url in stale[..<2] { _ = reader.hold(url) }   // never opened: the folder is replaced while these are parked
        let store = store(reader, dir: tempDir())
        await store.setRequest(window: 1, request(stale), stamps: reader.stamps)
        #expect(await eventually { reader.reads.count == 2 })

        await store.setRequest(window: 1, request(fresh), stamps: reader.stamps)
        #expect(await eventually { Set(reader.cancelled) == Set(stale[..<2]) })
        #expect(await eventually { await allReady(store, fresh) })
        try await Task.sleep(for: .milliseconds(20))
        #expect(reader.readCount(stale[0]) == 1 && reader.readCount(stale[1]) == 1)
        #expect(reader.readCount(stale[2]) == 0)
    }

    // MARK: - Errors

    @Test func failedReadMarksOnlyThatFile() async throws {
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        reader.fail(files[1])
        let store = store(reader, dir: tempDir())
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await allReady(store, [files[0], files[2]]) })
        #expect(await store.status(files[1]) == .unavailable)
        #expect(await store.cell(files[1], maxPixel: 16) == nil)
        // The colour corrector learns it in the same answer as the miss, and stops waiting.
        let miss = await store.imageOrStatus(files[1])
        #expect(miss.image == nil && miss.status == .unavailable)
        let hit = await store.imageOrStatus(files[0])
        #expect(hit.image != nil && hit.status == .ready)
        try await Task.sleep(for: .milliseconds(20))
        #expect(reader.readCount(files[1]) == 1)   // not retried in this session
    }

    @Test func failuresNotPersisted() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        reader.fail(files[1])
        let first = store(reader, dir: dir, commitDelay: .milliseconds(5))
        await first.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(first, [files[0], files[2]]) })
        #expect(await first.status(files[1]) == .unavailable)

        let second = store(reader, dir: dir)
        await second.setViewerActivity(.neighbours)
        await second.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await second.status(files[1]) == .pending)
        #expect(await second.status(files[0]) == .ready)
    }

    // MARK: - Database

    @Test func batchCommitsByCount() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(101, in: reader)
        let first = store(reader, dir: dir)   // the 1 s timer never fires within the test
        await first.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await allReady(first, files) })
        #expect(await first.commitCount == 1)
        #expect(await first.pendingWrites == 1)

        let second = store(reader, dir: dir)
        await second.setViewerActivity(.neighbours)
        await second.setRequest(window: 1, request(files), stamps: reader.stamps)
        // Which 100: the first finished, and with two reads in flight that need not be the first in the queue.
        var ready = 0
        for url in files where await second.status(url) == .ready { ready += 1 }
        #expect(ready == 100)
    }

    /// Folder cards: summaries go with the thumbnails' batch, but a summary that cannot be written never costs the
    /// thumbnails theirs.
    @Test func summaryWriteFailureLeavesThumbnailsWritten() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(2, in: reader)
        let first = store(reader, dir: dir)   // the 1 s timer never fires within the test
        await first.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await allReady(first, files) })
        #expect(await first.pendingWrites == 2)
        await first.queueSummary(FolderSummary(photos: 2, folders: 0),
                                 at: ThumbnailLocation(volume: "test", folder: "/photos/a", name: "_"))
        // Another connection drops the table: the summaries' write fails ("no such table"), not as damage.
        let other = try SQLiteConnection(path: dir.appendingPathComponent("Catalog.db").path, pragmas: [])
        try other.execute("DROP TABLE folder_summaries")
        await first.commit()
        #expect(await first.pendingWrites == 0)
        #expect(await first.storedBytes > 0)
        let second = store(reader, dir: dir)
        await second.setViewerActivity(.neighbours)
        await second.setRequest(window: 1, request(files), stamps: reader.stamps)
        for url in files { #expect(await second.status(url) == .ready) }
    }

    @Test func batchCommitsByTime() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(2, in: reader)
        let first = store(reader, dir: dir, commitDelay: .milliseconds(50))
        await first.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await allReady(first, files) })
        #expect(await eventually { await first.pendingWrites == 0 })
        #expect(await first.commitCount == 1)   // both thumbnails in the one batch the timer closed
    }

    @Test func memoryOnlyWritesNothing() async throws {
        let dir = tempDir()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        for store in [store(reader, dir: dir, limit: 0, commitDelay: .zero), store(reader, dir: nil, commitDelay: .zero)] {
            await store.setRequest(window: 1, request(files), stamps: reader.stamps)
            #expect(await eventually { await allReady(store, files) })
            #expect(await store.cell(files[0], maxPixel: 16) != nil)
            await store.setRequest(window: 1, nil, stamps: [:])            // folder closed: memory still has them
            #expect(await store.cell(files[0], maxPixel: 20) != nil)
        }
        #expect(try fm.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    /// One picture in every file of `name`, so every thumbnail weighs the same.
    private func sameSizedFolder(_ name: String, _ reader: ThumbReader, _ count: Int = 3) -> [URL] {
        let jpeg = TestJPEGs.gradient(width: 40, height: 30)
        return (0..<count).map { i in
            let url = URL(fileURLWithPath: "/photos/\(name)/\(i).jpg")
            reader.add(url, jpeg)
            return url
        }
    }

    /// The bytes of one `sameSizedFolder` thumbnail.
    private func sameSizedThumbnailBytes() async -> Int {
        let probe = ThumbReader()
        let one = sameSizedFolder("probe", probe, 1)
        let sizer = store(probe, dir: nil)
        await sizer.setRequest(window: 1, request(one), stamps: probe.stamps)
        _ = await eventually { await allReady(sizer, one) }
        return await sizer.madeBytes
    }

    /// Memory only, the thumbnails of folders walked through stay under `memoryCap`, down to 90 % of it at a time:
    /// those of folders no window shows go first, least recently made or shown first; then the shown folder's,
    /// farthest from the current photo first, and those are not made again until the folder is opened again.
    @Test func memoryOnlyThumbnailsStayUnderTheCap() async throws {
        func folder(_ name: String, _ reader: ThumbReader, _ count: Int = 3) -> [URL] { sameSizedFolder(name, reader, count) }
        let size = await sameSizedThumbnailBytes()
        #expect(size > 0)

        let reader = ThumbReader()
        let a = folder("a", reader), b = folder("b", reader), c = folder("c", reader)
        let cap = size * 13 / 2                                   // 6.5 thumbnails: 7 go down to 5 (90 %)
        let store = store(reader, dir: nil, memoryCap: cap)
        for (files, shownLater) in [(a, a[0]), (b, a[0]), (c, a[0])] {
            await store.setRequest(window: 1, request(files), stamps: reader.stamps)
            #expect(await eventually { await allReady(store, files) })
            #expect(await store.madeBytes <= cap)
            if files == b { #expect(await store.cell(shownLater, maxPixel: 16) != nil) }   // a[0] used again
        }
        // Nine made, two evictions of two: a[1], a[2] (oldest), then the two oldest of b; a[0] was shown since.
        #expect(await store.status(a[0]) == .ready)
        #expect(await Self.count(store, [a[1], a[2]], .pending) == 2)
        #expect(await Self.count(store, b, .ready) == 1)
        #expect(await store.made.count == 5)
        #expect(await store.madeBytes == 5 * size)

        // A shown folder bigger than the cap, current photo 0: the five of closed folders go first, then its own
        // farthest from photo 0. Each file made once, none again in circles: every file ends up made or evicted,
        // with no job left.
        let big = folder("big", reader, 9)
        await store.setRequest(window: 1, request(big), stamps: reader.stamps)
        #expect(await eventually { await Self.madeOrEvicted(store, big) })
        #expect(big.allSatisfy { reader.readCount($0) == 1 })
        #expect(await Self.count(store, a + b + c, .ready) == 0)
        #expect(await Self.count(store, Array(big[..<5]), .ready) == 5)   // the nearest always stay
        #expect(await Self.count(store, big, .ready) == 6)
        let evicted = await store.evicted
        #expect(evicted.count == 3 && evicted.isSubset(of: Set(big[5...])))
    }

    /// The key window's visible cells are never dropped by the cap, however far from the current photo, and the
    /// photos around the current one stay before farther ones.
    @Test func memoryCapKeepsTheVisibleCellsAndTheCurrentPhotosNeighbours() async throws {
        let size = await sameSizedThumbnailBytes()
        let reader = ThumbReader()
        let files = sameSizedFolder("d", reader, 12)
        let store = store(reader, dir: nil, memoryCap: size * 13 / 2)
        await store.setRequest(window: 1, request(files, current: 6, visible: [0, 11]), stamps: reader.stamps)
        #expect(await eventually { await Self.madeOrEvicted(store, files) })
        #expect(files.allSatisfy { reader.readCount($0) == 1 })
        #expect(await Self.count(store, [files[0], files[11], files[6], files[5], files[7]], .ready) == 5)
        #expect(await store.madeBytes <= size * 13 / 2)
        let evicted = await store.evicted
        #expect(!evicted.isEmpty && evicted.isDisjoint(with: [files[0], files[11], files[5], files[6], files[7]]))
    }

    private static func count(_ store: isolated ThumbnailStore, _ files: [URL], _ status: ThumbnailStatus) -> Int {
        files.filter { store.status($0) == status }.count
    }

    private static func madeOrEvicted(_ store: isolated ThumbnailStore, _ files: [URL]) -> Bool {
        store.jobs.isEmpty && files.allSatisfy { store.made[$0] != nil || store.evicted.contains($0) }
    }

    @Test func deletedDBRecreatedOnNextBatch() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(2, in: reader)
        let gate = reader.hold(files[1])
        let first = store(reader, dir: dir, commitDelay: .milliseconds(5))
        await first.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(first, [files[0]]) })
        #expect(await first.commitCount == 1)

        try fm.removeItem(at: dir)        // the user empties Caches/Loupe while the app runs
        gate.open()
        // The batch with files[1] finds the catalog gone: both are made again and stored in the new one.
        #expect(await eventually { await settled(first, files) })
        #expect(await first.commitCount >= 2)
        #expect(reader.readCount(files[0]) == 2)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("Catalog.db").path))

        let again = ThumbReader()
        for url in files { again.add(url, reader.data(url)!) }
        let second = store(again, dir: dir)
        await second.setViewerActivity(.neighbours)
        await second.setRequest(window: 1, request(files), stamps: again.stamps)
        #expect(await allReady(second, files))
    }

    @Test func limitEvictsOldestAndDoesNotRemakeThem() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(12, in: reader)
        let store = store(reader, dir: dir, limit: 3000, commitDelay: .zero)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { reader.reads.count == files.count })
        #expect(await eventually { await store.pendingWrites == 0 })
        try await Task.sleep(for: .milliseconds(30))
        for url in files { #expect(reader.readCount(url) == 1) }   // evicted ones wait for the next open
        var ready = 0
        for url in files where await store.status(url) == .ready { ready += 1 }
        #expect(ready > 0 && ready < files.count)
        let db = try ThumbnailDatabase(directory: dir, thumbSize: 32)
        #expect(try db.storedBytes() <= 3000)
        #expect(try db.storedBytes() > 0)
    }

    @Test func clearEmptiesEverything() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        let store = store(reader, dir: dir, commitDelay: .zero)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(store, files) })
        await store.setViewerActivity(.neighbours)
        await store.clear()
        for url in files { #expect(await store.status(url) == .pending) }
        #expect(try ThumbnailDatabase(directory: dir, thumbSize: 32).storedBytes() == 0)
        await store.setViewerActivity(.idle)
        #expect(await eventually { await settled(store, files) })
    }

    @Test func sizeChangeMakesThemAgain() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(2, in: reader)
        let store = store(reader, dir: dir, commitDelay: .zero)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(store, files) })
        await store.setSettings(thumbSize: 16, limitBytes: 1 << 30)
        #expect(await eventually { await settled(store, files) })
        let image = try #require(await store.image(files[0]))
        #expect(max(image.width, image.height) == 16)
        #expect(reader.readCount(files[0]) == 2)
    }

    @Test func cleanUpForgetsDeletedFiles() async throws {
        let dir = tempDir()
        let photosDir = tempDir()
        try fm.createDirectory(at: photosDir, withIntermediateDirectories: true)
        let reader = ThumbReader()
        let files = photos(3, folder: photosDir.path, in: reader)
        for url in files { try reader.data(url)!.write(to: url) }
        let store = store(reader, dir: dir, commitDelay: .zero, locate: { ThumbnailLocation.resolve($0) })
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(store, files) })

        try fm.removeItem(at: files[1])
        await store.setViewerActivity(.neighbours)
        await store.cleanUp()
        #expect(await store.status(files[1]) == .pending)
        #expect(await store.status(files[0]) == .ready)
        #expect(await store.status(files[2]) == .ready)
    }

    /// `exif-orientation=no`: the strip's cell and aspect of a turned photo are the stored ones (thumbnails are made
    /// turned), and the two settings do not share cached cells.
    @Test func cellAndAspectFollowExifOrientation() async throws {
        let reader = ThumbReader()
        let url = URL(fileURLWithPath: "/photos/a/turned.jpg")
        reader.add(url, TestJPEGs.pattern(cellsWide: 3, cellsHigh: 2, cell: 16, orientation: 6))   // stored 48 x 32
        let store = store(reader, dir: tempDir(), commitDelay: .zero)
        await store.setRequest(window: 1, request([url]), stamps: reader.stamps)
        #expect(await eventually { await settled(store, [url]) })

        let turned = try #require(await store.cell(url, maxPixel: 64))
        #expect(turned.height > turned.width)
        #expect(await store.aspects([url]) == [url: 32.0 / 48.0])
        let stored = try #require(await store.cell(url, maxPixel: 64, applyingOrientation: false))
        #expect(stored.width > stored.height && (stored.width, stored.height) == (turned.height, turned.width))
        #expect(await store.aspects([url], applyingOrientation: false) == [url: 48.0 / 32.0])
        let again = try #require(await store.cell(url, maxPixel: 64))
        #expect((again.width, again.height) == (turned.width, turned.height))
    }

    @Test func changedFileIsMadeAgain() async throws {
        let reader = ThumbReader()
        let files = photos(1, in: reader)
        let store = store(reader, dir: tempDir(), commitDelay: .zero)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(store, files) })
        #expect(try #require(await store.cell(files[0], maxPixel: 64)).height == 24)   // 40 x 30, cached now

        reader.add(files[0], TestJPEGs.gradient(width: 60, height: 30))   // edited: the new listing says so
        await store.setViewerActivity(.neighbours)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await store.status(files[0]) == .pending)
        #expect(await store.cell(files[0], maxPixel: 64) == nil)          // not the old picture
        await store.setViewerActivity(.idle)
        #expect(await eventually { await settled(store, files) })
        #expect(reader.readCount(files[0]) == 2)
        #expect(try #require(await store.cell(files[0], maxPixel: 64)).height == 16)
    }

    @Test func fileChangedAfterItsListingStaysInMemory() async throws {
        let reader = ThumbReader()
        let files = photos(1, in: reader)
        let listing = reader.stamps
        reader.add(files[0], TestJPEGs.gradient(width: 44, height: 30))   // changed after the listing
        let store = store(reader, dir: tempDir(), commitDelay: .zero)
        await store.setRequest(window: 1, request(files), stamps: listing)
        #expect(await eventually { await store.status(files[0]) == .ready })
        try await Task.sleep(for: .milliseconds(20))
        #expect(await store.pendingWrites == 0)
        #expect(await store.commitCount == 0)                              // `put` would skip it anyway
        #expect(await store.cell(files[0], maxPixel: 16) != nil)
        #expect(reader.readCount(files[0]) == 1)
    }

    @Test func limitZeroDeletesThumbsAndBackReopens() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        let thumbs = dir.appendingPathComponent("Thumbs.db").path
        let catalog = dir.appendingPathComponent("Catalog.db").path
        let store = store(reader, dir: dir, commitDelay: .zero)
        await store.setRequest(window: 1, request(Array(files[..<2])), stamps: reader.stamps)
        #expect(await eventually { await settled(store, Array(files[..<2])) })
        #expect(fm.fileExists(atPath: thumbs))

        await store.setSettings(thumbSize: 32, limitBytes: 0)        // "no traces"
        for path in [thumbs, catalog] {
            for suffix in ["", "-wal", "-shm"] { #expect(!fm.fileExists(atPath: path + suffix)) }
        }
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await allReady(store, files) })
        #expect(await store.cell(files[2], maxPixel: 16) != nil)     // memory serves them
        try await Task.sleep(for: .milliseconds(20))
        #expect(try fm.contentsOfDirectory(atPath: dir.path).isEmpty)

        await store.setSettings(thumbSize: 32, limitBytes: 1 << 30)  // back: new databases get what memory has
        #expect(await eventually { await settled(store, files) })
        #expect(fm.fileExists(atPath: thumbs) && fm.fileExists(atPath: catalog))
        let again = ThumbReader()
        let second = self.store(again, dir: dir)
        await second.setViewerActivity(.neighbours)
        await second.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await allReady(second, files))                    // made while memory only, stored now
    }

    @Test func limitZeroAtLaunchDeletesExistingDatabases() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(2, in: reader)
        let first = store(reader, dir: dir, commitDelay: .zero)
        await first.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(first, files) })
        #expect(!(try fm.contentsOfDirectory(atPath: dir.path)).isEmpty)
        try Data("old".utf8).write(to: dir.appendingPathComponent("Thumbs.db.broken-1000"))   // set aside once

        let again = ThumbReader()
        for url in files { again.add(url, reader.data(url)!) }
        let second = store(again, dir: dir, limit: 0, commitDelay: .zero)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).isEmpty)
        await second.setRequest(window: 1, request(files), stamps: again.stamps)
        #expect(await eventually { await allReady(second, files) })   // made again, in memory
        #expect(again.reads.count == files.count)
        #expect(await second.cell(files[0], maxPixel: 16) != nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(try fm.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func leftFolderStopsBeforeTheNewOneIsLocated() async throws {
        let reader = ThumbReader()
        let old = photos(3, folder: "/photos/old", in: reader)
        let new = photos(2, folder: "/photos/new", in: reader)
        for url in old[..<2] { _ = reader.hold(url) }
        let gate = BlockingGate()
        let store = store(reader, dir: tempDir(), locate: { url in
            if url.path.hasPrefix("/photos/new") { gate.wait() }
            return Self.testLocate(url)
        })
        await store.setRequest(window: 1, request(old), stamps: reader.stamps)
        #expect(await eventually { reader.reads.count == 2 })

        let switching = Task { await store.setRequest(window: 1, request(new), stamps: reader.stamps) }
        #expect(await eventually { Set(reader.cancelled) == Set(old[..<2]) })   // while the new folder is still being located
        try await Task.sleep(for: .milliseconds(20))
        #expect(reader.readCount(old[2]) == 0)
        gate.open()
        await switching.value
        #expect(await eventually { await allReady(store, new) })
    }

    @Test func damagedDBUnderALiveStoreIsSetAside() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(2, in: reader)
        let gate = reader.hold(files[1])
        let store = store(reader, dir: dir, commitDelay: .milliseconds(5))
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(store, [files[0]]) })

        // Move everything into the main file, then overwrite all but its first page with garbage, in place.
        let path = dir.appendingPathComponent("Thumbs.db").path
        let other = try SQLiteConnection(path: path, pragmas: [])
        try other.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        other.close()
        let size = try #require(fm.attributesOfItem(atPath: path)[.size] as? Int)
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seek(toOffset: 16384)
        try handle.write(contentsOf: Data(repeating: 0x5A, count: size - 16384))
        try handle.close()

        gate.open()   // the batch with files[1] hits the damage
        #expect(await eventually { await settled(store, files) })
        #expect(try fm.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("Thumbs.db.broken-") })
        #expect(await store.cell(files[1], maxPixel: 16) != nil)
        #expect(reader.readCount(files[0]) == 2)   // the new Thumbs.db is empty: made again

        let second = self.store(ThumbReader(), dir: dir)
        await second.setViewerActivity(.neighbours)
        await second.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await allReady(second, files))
    }

    // MARK: - Memory and notifications

    @Test func cellsComeFromMemory() async throws {
        let reader = ThumbReader()
        let files = photos(1, in: reader)
        let store = store(reader, dir: tempDir(), commitDelay: .zero)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(store, files) })
        let a = try #require(await store.cell(files[0], maxPixel: 16))
        let b = try #require(await store.cell(files[0], maxPixel: 16))
        #expect(a === b)
        let c = try #require(await store.cell(files[0], maxPixel: 24))
        #expect(max(c.width, c.height) == 24)
    }

    @Test func notifiesOnThumbnail() async throws {
        let reader = ThumbReader()
        let files = photos(4, in: reader)
        reader.fail(files[2])   // unavailable is news too: the strip swaps its placeholder
        let seen = Locked<[URL]>([])
        let store = store(reader, dir: tempDir())
        await store.setOnThumbnail { url in seen.update { $0.append(url) } }
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { Set(seen.get) == Set(files) })
        #expect(seen.get.count == files.count)
        #expect(await store.status(files[2]) == .unavailable)
    }

    @Test func notifiesWhenAMissedCellTurnsUpInTheDB() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(1, in: reader)
        let first = store(reader, dir: dir, commitDelay: .zero)
        await first.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(first, files) })

        let seen = Locked<[URL]>([])
        let second = store(reader, dir: dir)
        await second.setOnThumbnail { url in seen.update { $0.append(url) } }
        #expect(await second.cell(files[0], maxPixel: 16) == nil)   // asked before the folder synced
        await second.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(seen.get == files)
        #expect(await second.cell(files[0], maxPixel: 16) != nil)
    }

    /// The colour corrector reads `image` with the strip hidden (no cell asked): its miss is announced the same way.
    @Test func notifiesWhenAMissedImageTurnsUpInTheDB() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(1, in: reader)
        let first = store(reader, dir: dir, commitDelay: .zero)
        await first.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(first, files) })

        let seen = Locked<[URL]>([])
        let second = store(reader, dir: dir)
        await second.setOnThumbnail { url in seen.update { $0.append(url) } }
        #expect(await second.image(files[0]) == nil)   // asked before the folder synced
        await second.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(seen.get == files)
        #expect(await second.image(files[0]) != nil)
    }

    // MARK: - Seeding

    /// The jump's first picture comes from the thumbnail and the `ImageInfo` stored with it, in memory or in the
    /// database, never from the photo: 1200×900 at `thumb-size` 512 seeds level 2 (300×225).
    @Test func seedComesFromTheStoredThumbnail() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let url = URL(fileURLWithPath: "/photos/a/big.jpg")
        reader.add(url, TestJPEGs.gradient(width: 1200, height: 900))
        let first = store(reader, dir: dir, thumbSize: 512, commitDelay: .seconds(3600))
        #expect(await first.seed(url) == nil)   // not made yet
        await first.setRequest(window: 1, request([url]), stamps: reader.stamps)
        #expect(await eventually { await first.status(url) == .ready })
        #expect(await first.pendingWrites == 1)   // so this one is from memory
        let reads = reader.reads.count
        let fromMemory = try #require(await first.seed(url))
        #expect(fromMemory.info.pixelSize == PixelSize(width: 1200, height: 900))
        #expect(fromMemory.level.level == 2)
        #expect(fromMemory.level.image.pixelSize == PixelSize(width: 300, height: 225))
        #expect(reader.reads.count == reads)
        await first.commit()

        let again = ThumbReader()
        again.add(url, reader.data(url)!)
        let second = store(again, dir: dir, thumbSize: 512)
        await second.setRequest(window: 1, request([url]), stamps: again.stamps)
        // Ready from the database, so the generator has nothing to read for it either.
        #expect(await second.status(url) == .ready)
        let fromDB = try #require(await second.seed(url))
        #expect(fromDB.info == fromMemory.info)
        #expect(fromDB.level.level == 2)
        #expect(again.reads.isEmpty)
        #expect(await second.seed(URL(fileURLWithPath: "/photos/a/none.jpg")) == nil)
    }

    // MARK: - Aspects

    /// Width / height of the source (as `ImageInfo` has it), from the made thumbnails in memory and, in a
    /// later session, from the catalog; files without a thumbnail are left out.
    @Test func aspectsFromCatalogAndMemory() async throws {
        let dir = tempDir()
        let reader = ThumbReader()
        let files = photos(3, in: reader)   // 40, 41, 42 × 30
        let first = store(reader, dir: dir, commitDelay: .milliseconds(5))
        await first.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(first, files) })

        let again = ThumbReader()
        for url in files { again.add(url, reader.data(url)!) }
        let portrait = URL(fileURLWithPath: "/photos/a/portrait.jpg")
        again.add(portrait, TestJPEGs.gradient(width: 30, height: 60))
        let gate = again.hold(portrait)
        let second = store(again, dir: dir)
        let all = files + [portrait]
        await second.setRequest(window: 1, request(all), stamps: again.stamps)
        let fromCatalog = await second.aspects(all)
        let expected: [URL: Double] = [files[0]: 40.0 / 30, files[1]: 41.0 / 30, files[2]: 42.0 / 30]
        #expect(fromCatalog == expected)
        #expect(again.reads.allSatisfy { $0 == portrait })

        gate.open()
        #expect(await eventually { await second.status(portrait) == .ready })
        #expect(await second.pendingWrites == 1)   // in memory only: the batch is an hour away
        let withMemory = await second.aspects(all)
        #expect(withMemory[portrait] == 0.5)
        #expect(withMemory.count == 4)
        #expect(await second.aspects([]) == [:])
    }

    // MARK: - Thumbs ahead (stage 5)

    /// "Refresh cover": the folder's summary goes from the batch and the catalog and its pick from memory, so its next
    /// card lists it again.
    @Test func refreshCoverForgetsSummaryAndPick() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let names = photos(6, folder: "/photos/p", in: reader).map(\.lastPathComponent)
        let listings = Locked(0)
        let store = store(reader, dir: dir)
        await store.setCoverListing { _, _, _ in
            listings.update { $0 += 1 }
            return CoverNames(files: names, folders: [])
        }
        await store.setCoverVolumes { _ in false }
        let folder = URL(fileURLWithPath: "/photos/p")
        let location = ThumbnailLocation(volume: "test", folder: "/photos/p", name: "_")
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        _ = await store.folderCard(folder, archive: false, in: location, maxPixel: 16, modified: date)
        #expect(listings.get == 1)
        #expect(await store.folderSummary(at: location)?.photos == 6)
        #expect(await store.coverPicks.keys.contains { $0.hasPrefix("/photos/p") })
        await store.commit()
        await store.forgetSummaryAndPick(of: location, folder: folder)
        #expect(await store.folderSummary(at: location) == nil)
        #expect(!(await store.coverPicks.keys.contains { $0.hasPrefix("/photos/p") }))
        // The pictures from the catalog at once, the summary listed on the call after (as a card's).
        var card = try #require(await store.folderCard(folder, archive: false, in: location, maxPixel: 16,
                                                       modified: date))
        if card.summaryPending {
            card = try #require(await store.folderCard(folder, archive: false, in: location, maxPixel: 16,
                                                       modified: date))
        }
        #expect(listings.get == 2)
        #expect(card.summary?.photos == 6)

        // A zip's memos are keyed by its path the same way (`memoKey`: the path, or the path, NUL and its date).
        let zip = URL(fileURLWithPath: "/photos/z.zip")
        let zipLocation = ThumbnailLocation(volume: "test", folder: "/photos/z.zip", name: "_")
        _ = await store.folderCard(zip, archive: true, in: zipLocation, maxPixel: 16, modified: date)
        #expect(await store.coverPicks.keys.contains { $0.hasPrefix("/photos/z.zip") })
        await store.forgetSummaryAndPick(of: zipLocation, folder: zip)
        #expect(!(await store.coverPicks.keys.contains { $0.hasPrefix("/photos/z.zip") }))
    }

    /// A walk window of a folder's first stamped photos (more to come) leaves the catalog's rows of the others alone.
    @Test func walkChunkKeepsTheFolderCatalog() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let files = photos(4, in: reader)
        let first = store(reader, dir: dir, commitDelay: .milliseconds(5))
        await first.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await eventually { await settled(first, files) })

        let second = store(reader, dir: dir)
        let chunk = Array(files.prefix(2))
        await second.setWalkWindow(ThumbnailRequest(files: chunk, current: 0, visible: [], isKey: false),
                                   stamps: reader.stamps, complete: false)
        #expect(await allReady(second, chunk))
        await second.setWalkWindow(nil, stamps: [:])
        let reads = reader.reads.count
        await second.setRequest(window: 1, request(files), stamps: reader.stamps)
        #expect(await allReady(second, files))
        #expect(reader.reads.count == reads)
    }

    /// A walk folder a window also shows is that window's to make; when the window closes before, the walk window
    /// keeps the folder open and its photos are still made.
    @Test func walkFolderOutlivesTheWindowThatShowedIt() async throws {
        let reader = ThumbReader()
        let files = photos(3, in: reader)
        let gates = files.map { reader.hold($0) }
        let store = store(reader, dir: nil)
        await store.setRequest(window: 1, request(files), stamps: reader.stamps)
        await store.setWalkWindow(ThumbnailRequest(files: files, current: 0, visible: [], isKey: false),
                                  stamps: reader.stamps)
        await store.setRequest(window: 1, nil, stamps: [:])
        gates.forEach { $0.open() }
        #expect(await eventually { await allReady(store, files) })
        #expect(await store.walkPending.isEmpty)
    }
}
