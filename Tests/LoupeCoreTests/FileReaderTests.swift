import Foundation
import Testing
@testable import LoupeCore

// FileReader is exercised against real temp files; `isLocal: { _ in false }` forces the chunked
// (network) path, and the injected chunk reader simulates slow or hung SMB reads. Every test
// releases its gates before it ends, so no pool thread stays blocked after the suite.

private let mib = 1 << 20

/// A temp directory per test with files of patterned bytes (all on one volume).
private final class TempFiles {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    func make(_ name: String, size: Int) throws -> (URL, Data) {
        // A 64 KiB pattern, stamped with its block index so misplaced chunks show up.
        let block = (0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }
        var data = Data(capacity: size)
        var index: UInt8 = 0
        while data.count < size {
            var b = block[0..<min(block.count, size - data.count)]
            b[b.startIndex] = index; index &+= 1
            data.append(contentsOf: b)
        }
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return (url, data)
    }
}

/// The file name behind an open descriptor, so a chunk reader can single out one file.
private func fileName(_ fd: Int32) -> String {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &buf) != -1 else { return "" }
    return URL(fileURLWithPath: String(cString: buf)).lastPathComponent
}

private func realPread(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int, _ offset: Int) -> Int {
    Darwin.pread(fd, buf, count, off_t(offset))
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Blocks reads of chosen files until released; `entered` signals once per blocked read.
private final class Gates: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [String: DispatchSemaphore] = [:]
    let entered = DispatchSemaphore(value: 0)

    func block(_ name: String) { lock.lock(); gates[name] = DispatchSemaphore(value: 0); lock.unlock() }
    /// Opens one file's gate for good.
    func release(_ name: String) {
        lock.lock(); let g = gates.removeValue(forKey: name); lock.unlock()
        if let g { for _ in 0..<64 { g.signal() } }
    }
    func gate(for name: String) -> DispatchSemaphore? { lock.lock(); defer { lock.unlock() }; return gates[name] }
    /// Opens every gate for good (generously signalled, so repeated reads also pass).
    func releaseAll() {
        lock.lock(); let all = gates.values; gates = [:]; lock.unlock()
        for g in all { for _ in 0..<64 { g.signal() } }
    }

    var reader: @Sendable (Int32, UnsafeMutableRawPointer, Int, Int) -> Int {
        { fd, buf, count, offset in
            if let g = self.gate(for: fileName(fd)) { self.entered.signal(); g.wait() }
            return realPread(fd, buf, count, offset)
        }
    }
}

/// Waits for `entered` without blocking the cooperative pool.
private func waitEntered(_ gates: Gates) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async { gates.entered.wait(); c.resume() }
    }
}

/// Runs `op`, giving up after `limit` (nil) so a regression fails fast instead of hanging.
private func within<T: Sendable>(_ limit: Duration, _ op: @escaping @Sendable () async throws -> T) async -> Result<T, Error>? {
    await withTaskGroup(of: Result<T, Error>?.self) { group in
        group.addTask { do { return .success(try await op()) } catch { return .failure(error) } }
        group.addTask { try? await Task.sleep(for: limit); return nil }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
}

private func failure<T>(_ r: Result<T, Error>?) -> ReadError? {
    if case .failure(let e)? = r { return e as? ReadError }
    return nil
}

private func readError(_ op: () async throws -> some Sendable) async -> Error? {
    do { _ = try await op(); return nil } catch { return error }
}

@Test func readsWholeFile() async throws {
    let files = try TempFiles()
    let (url, data) = try files.make("a.bin", size: 3 * mib + mib / 2)
    let reader = FileReader(isLocal: { _ in false })
    let bytes = try await reader.read(url)
    #expect(bytes.data == data)
    #expect(bytes.stamp.size == data.count)
}

@Test func localReadMatchesAndStampAgrees() async throws {
    let files = try TempFiles()
    let (url, data) = try files.make("a.bin", size: mib + 123)
    let reader = FileReader(isLocal: { _ in true })
    let bytes = try await reader.read(url)
    #expect(bytes.data == data)
    let stamp = try await reader.stamp(url)
    #expect(stamp == bytes.stamp)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(stamp.size == data.count)
    #expect(abs(stamp.modified.timeIntervalSince(attrs[.modificationDate] as! Date)) < 0.001)
}

@Test func missingFileThrows() async throws {
    let files = try TempFiles()
    let url = files.dir.appendingPathComponent("nope.bin")
    let reader = FileReader(isLocal: { _ in false })
    #expect(await readError { try await reader.read(url) } != nil)
    #expect(await readError { try await reader.stamp(url) } != nil)
}

@Test func networkReadNotMapped() async throws {
    let files = try TempFiles()
    let (url, data) = try files.make("a.bin", size: 3 * mib + mib / 2)
    let calls = Counter()
    let reader = FileReader(isLocal: { _ in false }, chunkReader: { fd, buf, count, offset in
        calls.bump()
        return realPread(fd, buf, count, offset)
    })
    let bytes = try await reader.read(url)
    #expect(bytes.data == data)
    #expect(calls.value >= 4)
}

/// The chunk reader hands out at most 1 KiB per call (the reader's own chunk size is fixed at 1 MiB), so the
/// predicate sees the file grow in 1 KiB steps and the read stops at the first step that satisfies it.
@Test func prefixReadStopsWhenEnough() async throws {
    let files = try TempFiles()
    let (url, data) = try files.make("a.bin", size: 10 * 1024)
    let reader = FileReader(isLocal: { _ in false }, chunkReader: { fd, buf, count, offset in
        realPread(fd, buf, min(count, 1024), offset)
    })
    let bytes = try await reader.readPrefix(url, priority: ReadPriority(0)) { $0.count >= 3000 }
    #expect(bytes.data.count >= 3072 && bytes.data.count <= 4096)
    #expect(bytes.data == data.prefix(bytes.data.count))
    #expect(bytes.stamp.size == 10 * 1024)
}

/// A predicate that never accepts yields the whole file; the last chunk is not offered to it.
@Test func prefixReadWithoutEnoughReadsWholeFile() async throws {
    let files = try TempFiles()
    let (url, data) = try files.make("a.bin", size: 5 * 1024)
    let asked = Counter()
    let reader = FileReader(isLocal: { _ in false }, chunkReader: { fd, buf, count, offset in
        realPread(fd, buf, min(count, 1024), offset)
    })
    let bytes = try await reader.readPrefix(url, priority: ReadPriority(0)) { _ in asked.bump(); return false }
    #expect(bytes.data == data)
    #expect(asked.value == 4)
}

/// A mapped (local) file is mapped whole; the predicate is not consulted.
@Test func prefixReadOfLocalFileIsWhole() async throws {
    let files = try TempFiles()
    let (url, data) = try files.make("a.bin", size: 10 * 1024)
    let reader = FileReader(isLocal: { _ in true })
    let bytes = try await reader.readPrefix(url, priority: ReadPriority(0)) { _ in true }
    #expect(bytes.data == data)
}

@Test(.timeLimit(.minutes(1))) func stuckReadTimesOut() async throws {
    let files = try TempFiles()
    let (a, _) = try files.make("a.bin", size: mib)
    let (b, bData) = try files.make("b.bin", size: mib)
    let gates = Gates()
    gates.block("a.bin")
    defer { gates.releaseAll() }
    let reader = FileReader(threads: 2, timeout: .milliseconds(300), isLocal: { _ in false },
                            chunkReader: gates.reader)
    let start = ContinuousClock.now
    let stuck = Task { await readError { try await reader.read(a) } }
    await waitEntered(gates)
    let other = try await reader.read(b)                    // the second thread is free
    #expect(other.data == bData)
    let error = await stuck.value
    #expect(error as? ReadError == .notResponding)
    // The gate never opens before the end of the test, so any return at all is the 300 ms timeout firing; the
    // bound only has to tell that from a hang, and stays generous so a loaded machine does not fail it.
    #expect(ContinuousClock.now - start < .seconds(5))
}

@Test(.timeLimit(.minutes(1))) func stuckThreadsAreReplaced() async throws {
    let files = try TempFiles()
    var urls: [String: URL] = [:]
    for name in ["a", "b", "c", "d", "e"] { urls[name] = try files.make("\(name).bin", size: mib / 4).0 }
    let gates = Gates()
    gates.block("a.bin"); gates.block("c.bin")
    defer { gates.releaseAll() }
    let reader = FileReader(threads: 1, timeout: .milliseconds(300), maxReplacements: 1,
                            isLocal: { _ in false }, chunkReader: gates.reader)

    let a = Task { await readError { try await reader.read(urls["a"]!) } }
    await waitEntered(gates)
    _ = try await reader.read(urls["b"]!)                   // runs on the replacement thread
    #expect(await a.value as? ReadError == .notResponding)

    let c = Task { await readError { try await reader.read(urls["c"]!) } }
    await waitEntered(gates)
    #expect(await c.value as? ReadError == .notResponding) // no replacement left

    let start = ContinuousClock.now
    let d = await readError { try await reader.read(urls["d"]!) }
    #expect(d as? ReadError == .volumeStuck)
    #expect(ContinuousClock.now - start < .milliseconds(100))

    gates.releaseAll()                                      // the lost threads come back
    var result: FileBytes?
    let deadline = ContinuousClock.now + .seconds(2)
    while result == nil, ContinuousClock.now < deadline {
        do { result = try await reader.read(urls["e"]!) } catch ReadError.volumeStuck {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    #expect(result?.data.count == mib / 4)
    #expect(try await reader.stamp(urls["d"]!).size == mib / 4)
}

/// Cancelling mid-read stops the worker at the next chunk boundary. Driven by the chunk reader itself, not by
/// wall-clock sleeps: the second chunk waits until the test has cancelled, so the read is provably in the middle.
@Test(.timeLimit(.minutes(1))) func cancellationStopsBetweenChunks() async throws {
    let files = try TempFiles()
    let chunks = 16
    let (url, _) = try files.make("a.bin", size: chunks * mib)
    let calls = Counter()
    let midRead = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
    let reader = FileReader(isLocal: { _ in false }, chunkReader: { fd, buf, count, offset in
        calls.bump()
        if calls.value == 2 {
            midRead.signal()
            cancelled.wait()
        }
        return realPread(fd, buf, count, offset)
    })
    let task = Task { await readError { try await reader.read(url) } }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async { midRead.wait(); c.resume() }
    }
    task.cancel()
    cancelled.signal()
    let error = await task.value
    #expect(error is CancellationError)
    // The worker may finish the chunk in hand; it must not go on to the rest. Give a runaway read every chance to
    // show up (polling, not a fixed sleep) before checking.
    let deadline = ContinuousClock.now + .milliseconds(500)
    while ContinuousClock.now < deadline && calls.value < chunks { try await Task.sleep(for: .milliseconds(10)) }
    #expect(calls.value <= 3, "\(calls.value) chunks read after the cancel")
}

@Test(.timeLimit(.minutes(1))) func queuedJobsForStuckVolumeAreRefused() async throws {
    let files = try TempFiles()
    let (a, _) = try files.make("a.bin", size: mib / 4)
    let (a2, _) = try files.make("a2.bin", size: mib / 4)
    let other = URL(fileURLWithPath: "/dev/null")               // devfs: another volume
    let gates = Gates()
    gates.block("a.bin")
    defer { gates.releaseAll() }
    // Looking up a2's volume would hang like the share itself: a2 must be refused before that.
    let hang = DispatchSemaphore(value: 0)
    defer { for _ in 0..<4 { hang.signal() } }
    let reader = FileReader(threads: 1, timeout: .milliseconds(300), maxReplacements: 0,
                            isLocal: { _ in false }, chunkReader: gates.reader, volumeIdentifier: { url in
        if url.lastPathComponent == "a2.bin" { hang.wait() }
        return IOPool.resolveVolumeIdentifier(url)
    })
    let stuck = Task { await within(.seconds(3)) { try await reader.read(a) } }
    await waitEntered(gates)
    let queued = Task { await within(.seconds(3)) { try await reader.read(a2) } }
    try await Task.sleep(for: .milliseconds(20))               // a2 is queued ahead of the other volume
    let b = await within(.seconds(3)) { try await reader.read(other) }
    #expect(failure(await stuck.value) == .notResponding)
    #expect(failure(await queued.value) == .volumeStuck)       // never got a thread to hang on
    #expect(try b?.get().data.isEmpty == true)                 // the last thread serves another volume
}

/// Volume identity that never resolves for the chosen file names.
private func unresolved(_ names: Set<String>) -> @Sendable (URL) -> NSObjectProtocol? {
    { url in names.contains(url.lastPathComponent) ? nil : IOPool.resolveVolumeIdentifier(url) }
}

@Test(.timeLimit(.minutes(1))) func keylessLossMarksItsDirectory() async throws {
    let files = try TempFiles()
    let (a, _) = try files.make("a.bin", size: mib / 4)
    let (c, _) = try files.make("c.bin", size: mib / 4)
    let gates = Gates()
    gates.block("a.bin")
    defer { gates.releaseAll() }
    let reader = FileReader(threads: 1, timeout: .milliseconds(300), maxReplacements: 0,
                            isLocal: { _ in false }, chunkReader: gates.reader,
                            volumeIdentifier: { _ in nil })     // no identifier, not under /Volumes
    let stuck = Task { await within(.seconds(3)) { try await reader.read(a) } }
    await waitEntered(gates)
    #expect(failure(await stuck.value) == .notResponding)
    let start = ContinuousClock.now
    #expect(failure(await within(.seconds(3)) { try await reader.read(c) }) == .volumeStuck)
    #expect(ContinuousClock.now - start < .milliseconds(100))
}

@Test(.timeLimit(.minutes(1))) func keylessLossUsesCachedVolume() async throws {
    let files = try TempFiles()
    let (a, _) = try files.make("one/a.bin", size: mib / 4)
    let (b, _) = try files.make("one/b.bin", size: mib / 4)
    let (x, _) = try files.make("two/x.bin", size: mib / 4)
    let (y, _) = try files.make("two/y.bin", size: mib / 4)
    let gates = Gates()
    gates.block("a.bin")
    defer { gates.releaseAll() }
    let reader = FileReader(threads: 1, timeout: .milliseconds(300), maxReplacements: 0,
                            isLocal: { _ in false }, chunkReader: gates.reader,
                            volumeIdentifier: unresolved(["a.bin"]))
    _ = try await reader.read(b)                               // both folders' volume is now known
    _ = try await reader.read(x)
    let stuck = Task { await within(.seconds(3)) { try await reader.read(a) } }
    await waitEntered(gates)
    #expect(failure(await stuck.value) == .notResponding)
    // a.bin never resolved, yet its folder's cached volume is marked: another folder on it is refused.
    #expect(failure(await within(.seconds(3)) { try await reader.read(y) }) == .volumeStuck)
}

/// Tracks how many burst reads run at once.
private final class Concurrency: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var peak = 0
    func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
    func leave() { lock.lock(); now -= 1; lock.unlock() }
}

@Test(.timeLimit(.minutes(1))) func returnedThreadsDoNotGrowThePool() async throws {
    let files = try TempFiles()
    let (a1, _) = try files.make("a1.bin", size: mib / 4)
    let (a2, _) = try files.make("a2.bin", size: mib / 4)
    var burst: [URL] = []
    for i in 0..<8 { burst.append(try files.make("burst\(i).bin", size: mib / 4).0) }
    let gates = Gates()
    gates.block("a1.bin"); gates.block("a2.bin")
    defer { gates.releaseAll() }
    let active = Concurrency()
    let reader = FileReader(threads: 2, timeout: .milliseconds(300), maxReplacements: 2,
                            isLocal: { _ in false }, chunkReader: { fd, buf, count, offset in
        if fileName(fd).hasPrefix("burst") {
            active.enter(); defer { active.leave() }
            usleep(20_000)
            return realPread(fd, buf, count, offset)
        }
        return gates.reader(fd, buf, count, offset)
    })
    let s1 = Task { await readError { try await reader.read(a1) } }
    let s2 = Task { await readError { try await reader.read(a2) } }
    await waitEntered(gates); await waitEntered(gates)
    #expect(await s1.value as? ReadError == .notResponding)
    #expect(await s2.value as? ReadError == .notResponding)    // both threads replaced
    gates.releaseAll()                                          // the lost threads come back...
    try await Task.sleep(for: .milliseconds(100))               // ...and must leave, not rejoin
    try await withThrowingTaskGroup(of: Void.self) { group in
        for url in burst { group.addTask { _ = try await reader.read(url) } }
        try await group.waitForAll()
    }
    #expect(active.peak <= 2)
}

/// Records the order in which reads reach their first chunk.
private final class StartOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    var value: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

/// Polls until `reader` has `count` jobs queued (not yet on a thread).
private func waitQueued(_ reader: FileReader, _ count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while reader.queuedCount < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(reader.queuedCount == count)
}

/// One thread, held by the first read: queued jobs start lowest priority value first, FIFO among equals.
@Test(.timeLimit(.minutes(1))) func priorityOrder() async throws {
    let files = try TempFiles()
    var urls: [String: URL] = [:]
    for name in ["a", "p5", "p1", "p3", "p1b"] { urls[name] = try files.make("\(name).bin", size: mib / 4).0 }
    let gates = Gates()
    gates.block("a.bin")
    defer { gates.releaseAll() }
    let order = StartOrder()
    let reader = FileReader(threads: 1, timeout: .seconds(10), isLocal: { _ in false }, chunkReader: { fd, buf, count, offset in
        if offset == 0 { order.add(fileName(fd)) }
        return gates.reader(fd, buf, count, offset)
    })
    let first = Task { try await reader.read(urls["a"]!, priority: 0) }
    await waitEntered(gates)
    var reads: [Task<FileBytes, Error>] = []
    for (name, p) in [("p5", 5), ("p1", 1), ("p3", 3), ("p1b", 1)] {
        reads.append(Task { try await reader.read(urls[name]!, priority: p) })
        try await waitQueued(reader, reads.count)
    }
    gates.releaseAll()
    _ = try await first.value
    for r in reads { _ = try await r.value }
    #expect(order.value == ["a.bin", "p1.bin", "p1b.bin", "p3.bin", "p5.bin"])
}

/// A queued read whose priority box is moved ahead starts before the ones it now outranks; a running one is unaffected.
@Test(.timeLimit(.minutes(1))) func movedPriorityReordersQueuedJob() async throws {
    let files = try TempFiles()
    var urls: [String: URL] = [:]
    for name in ["a", "b", "c", "d"] { urls[name] = try files.make("\(name).bin", size: mib / 4).0 }
    let gates = Gates()
    gates.block("a.bin")
    defer { gates.releaseAll() }
    let order = StartOrder()
    let reader = FileReader(threads: 1, timeout: .seconds(10), isLocal: { _ in false }, chunkReader: { fd, buf, count, offset in
        if offset == 0 { order.add(fileName(fd)) }
        return gates.reader(fd, buf, count, offset)
    })
    let boxes = ["a": 7, "b": 1, "c": 2, "d": 9].mapValues { ReadPriority($0) }
    let first = Task { try await reader.read(urls["a"]!, priority: boxes["a"]!) }
    await waitEntered(gates)
    var reads: [Task<FileBytes, Error>] = []
    for name in ["b", "c", "d"] {
        reads.append(Task { try await reader.read(urls[name]!, priority: boxes[name]!) })
        try await waitQueued(reader, reads.count)
    }
    boxes["d"]!.value = 0
    boxes["b"]!.value = 5
    boxes["a"]!.value = 100          // running: nothing to move
    gates.releaseAll()
    _ = try await first.value
    for r in reads { _ = try await r.value }
    #expect(order.value == ["a.bin", "d.bin", "c.bin", "b.bin"])
}

/// Background reads (thumbnails, `ReadPriority.isBackground`) take at most `threads - 2` threads: with
/// two of them stuck, the viewer's reads still start at once, and a third background read waits.
@Test(.timeLimit(.minutes(1))) func backgroundReadsLeaveTheViewerTwoThreads() async throws {
    let files = try TempFiles()
    var urls: [String: URL] = [:]
    for name in ["bg1", "bg2", "bg3", "v1", "v2"] { urls[name] = try files.make("\(name).bin", size: mib / 4).0 }
    let gates = Gates()
    for name in ["bg1", "bg2", "bg3"] { gates.block("\(name).bin") }
    defer { gates.releaseAll() }
    let order = StartOrder()
    let reader = FileReader(threads: 4, timeout: .seconds(10), isLocal: { _ in false }, chunkReader: { fd, buf, count, offset in
        if offset == 0 { order.add(fileName(fd)) }
        return gates.reader(fd, buf, count, offset)
    })
    let background = ReadPriority.background
    let stuck = ["bg1", "bg2"].map { name in
        Task { try await reader.read(urls[name]!, priority: ReadPriority(background, isBackground: true)) }
    }
    await waitEntered(gates)
    await waitEntered(gates)
    let third = Task { try await reader.read(urls["bg3"]!, priority: ReadPriority(background + 5, isBackground: true)) }
    try await waitQueued(reader, 1)

    // Both viewer reads together: each has a thread of its own, neither waits for the stuck ones.
    let v1 = urls["v1"]!, v2 = urls["v2"]!
    let viewer = await within(.seconds(5)) {
        async let a = reader.read(v1, priority: 0)
        async let b = reader.read(v2, priority: 1)
        return try await [a, b].map(\.data.count)
    }
    #expect(viewer.flatMap { try? $0.get() } == [mib / 4, mib / 4])
    #expect(reader.queuedCount == 1)
    #expect(!order.value.contains("bg3.bin"))

    gates.releaseAll()
    for task in stuck { _ = try await task.value }
    #expect(try await third.value.data.count == mib / 4)
}

/// The viewer's own reads keep to two threads, as before the thumbnails' threads were added: a third waits even
/// with threads idle, while a background read still finds one.
@Test(.timeLimit(.minutes(1))) func viewerReadsUseTwoThreads() async throws {
    let files = try TempFiles()
    var urls: [String: URL] = [:]
    for name in ["v1", "v2", "v3", "bg"] { urls[name] = try files.make("\(name).bin", size: mib / 4).0 }
    let gates = Gates()
    for name in ["v1", "v2"] { gates.block("\(name).bin") }
    defer { gates.releaseAll() }
    let reader = FileReader(threads: 4, timeout: .seconds(10), isLocal: { _ in false }, chunkReader: gates.reader)
    // Current reads (a pair's two pages): neighbours keep to one thread (`currentReadGetsTheReservedThread`).
    func current() -> ReadPriority { let p = ReadPriority(0); p.isCurrent = true; return p }
    let held = ["v1", "v2"].map { name in Task { try await reader.read(urls[name]!, priority: current()) } }
    await waitEntered(gates)
    await waitEntered(gates)
    let third = Task { try await reader.read(urls["v3"]!, priority: current()) }
    try await waitQueued(reader, 1)

    let bg = urls["bg"]!
    let thumb = await within(.seconds(5)) {
        try await reader.read(bg, priority: ReadPriority(ReadPriority.background, isBackground: true)).data.count
    }
    #expect(thumb.flatMap { try? $0.get() } == mib / 4)
    #expect(reader.queuedCount == 1)

    gates.releaseAll()
    for task in held { _ = try await task.value }
    #expect(try await third.value.data.count == mib / 4)
}

/// The class is the read's, not its value's: a viewer read that left the cache's plan (`Int.max`, past every
/// background value) is still the viewer's, and runs at once while two background reads hold their threads.
@Test(.timeLimit(.minutes(1))) func unplannedViewerReadIsNotBackground() async throws {
    let files = try TempFiles()
    var urls: [String: URL] = [:]
    for name in ["bg1", "bg2", "bg3", "v"] { urls[name] = try files.make("\(name).bin", size: mib / 4).0 }
    let gates = Gates()
    for name in ["bg1", "bg2", "bg3"] { gates.block("\(name).bin") }
    defer { gates.releaseAll() }
    let reader = FileReader(threads: 4, timeout: .seconds(10), isLocal: { _ in false }, chunkReader: gates.reader)
    let stuck = ["bg1", "bg2", "bg3"].map { name in
        Task { try await reader.read(urls[name]!, priority: ReadPriority(ReadPriority.background, isBackground: true)) }
    }
    await waitEntered(gates)
    await waitEntered(gates)
    try await waitQueued(reader, 1)   // the third background read waits for its share

    let v = urls["v"]!
    let unplanned = ReadPriority(Int.max)
    let viewer = await within(.seconds(5)) { try await reader.read(v, priority: unplanned).data.count }
    #expect(viewer.flatMap { try? $0.get() } == mib / 4)

    // Moved back into the plan while queued behind nothing: still the viewer's, still runs.
    let moved = ReadPriority(Int.max)
    let again = Task { try await reader.read(v, priority: moved) }
    moved.value = 3
    #expect(try await again.value.data.count == mib / 4)
    #expect(reader.queuedCount == 1)

    gates.releaseAll()
    for task in stuck { _ = try await task.value }
}

/// A move of a queued read's priority reaches the pool it is queued in, which has its idle workers look again;
/// setting the same value does not. (With the class fixed at creation, no move can let a waiting job start that
/// could not before, so there is no wait to observe: the test sees the notification itself.)
@Test(.timeLimit(.minutes(1))) func priorityMovesReachThePool() async throws {
    let files = try TempFiles()
    let (a, _) = try files.make("a.bin", size: mib / 4)
    let (b, _) = try files.make("b.bin", size: mib / 4)
    let gates = Gates()
    gates.block("a.bin")
    defer { gates.releaseAll() }
    let reader = FileReader(threads: 1, timeout: .seconds(10), isLocal: { _ in false }, chunkReader: gates.reader)
    let first = Task { try await reader.read(a, priority: 0) }
    await waitEntered(gates)
    let box = ReadPriority(5)
    let queued = Task { try await reader.read(b, priority: box) }
    try await waitQueued(reader, 1)

    box.value = 5
    #expect(reader.priorityMoves == 0)
    box.value = 2
    #expect(reader.priorityMoves == 1)

    gates.releaseAll()
    _ = try await first.value
    _ = try await queued.value
}

// MARK: - The current photo first (V7)

/// Neighbour reads (viewer reads not flagged current) take at most `viewerThreads − 1` threads: with two of them
/// blocked in a read, the second waits, and the current photo's read still gets a thread and its first chunk.
@Test(.timeLimit(.minutes(1))) func currentReadGetsTheReservedThread() async throws {
    let files = try TempFiles()
    var urls: [String: URL] = [:]
    for name in ["n1", "n2", "cur"] { urls[name] = try files.make("\(name).bin", size: mib / 4).0 }
    let gates = Gates()
    for name in ["n1", "n2"] { gates.block("\(name).bin") }
    defer { gates.releaseAll() }
    let reader = FileReader(threads: 4, timeout: .seconds(10), isLocal: { _ in false }, chunkReader: gates.reader)
    let neighbours = ["n1", "n2"].map { name in Task { try await reader.read(urls[name]!, priority: ReadPriority(3)) } }
    await waitEntered(gates)
    try await waitQueued(reader, 1)   // the second neighbour waits: the other viewer thread is the current photo's

    let current = ReadPriority(0)
    current.isCurrent = true
    let cur = urls["cur"]!
    let read = await within(.seconds(5)) { try await reader.read(cur, priority: current).data.count }
    #expect(read.flatMap { try? $0.get() } == mib / 4)

    gates.releaseAll()
    for task in neighbours { #expect(try await task.value.data.count == mib / 4) }
}

/// While a current read runs, a running neighbour read issues no further chunk (its bytes so far are kept), and goes
/// on to the end once the current read is done.
@Test(.timeLimit(.minutes(1))) func neighbourPausesWhileCurrentReads() async throws {
    let files = try TempFiles()
    let (n, nData) = try files.make("n.bin", size: 4 * mib)
    let (c, _) = try files.make("c.bin", size: mib / 4)
    let gates = Gates()
    gates.block("n.bin")
    gates.block("c.bin")
    defer { gates.releaseAll() }
    let chunks = Counter()
    let reader = FileReader(threads: 4, timeout: .seconds(10), isLocal: { _ in false }, chunkReader: { fd, buf, count, offset in
        if fileName(fd) == "n.bin" { chunks.bump() }
        return gates.reader(fd, buf, count, offset)
    })
    let neighbour = Task { try await reader.read(n, priority: ReadPriority(3)) }
    await waitEntered(gates)                 // the neighbour is in its first chunk
    let current = ReadPriority(0)
    current.isCurrent = true
    let cur = Task { try await reader.read(c, priority: current) }
    await waitEntered(gates)                 // the current read is in its first chunk
    gates.release("n.bin")                   // the neighbour's first chunk ends while the current read runs
    try await Task.sleep(for: .milliseconds(300))
    #expect(chunks.value == 1)

    gates.release("c.bin")
    #expect(try await cur.value.data.count == mib / 4)
    #expect(try await neighbour.value.data == nData)
    #expect(chunks.value == 4)
}

/// A neighbour paused for longer than the timeout is not written off as hung: it read nothing because it was told to
/// wait, not because the share stopped answering.
@Test(.timeLimit(.minutes(1))) func pausedNeighbourIsNotHung() async throws {
    let files = try TempFiles()
    let (n, nData) = try files.make("n.bin", size: 2 * mib)
    let (c, _) = try files.make("c.bin", size: 8 * mib)
    let reader = FileReader(threads: 4, timeout: .seconds(1), isLocal: { _ in false }, chunkReader: { fd, buf, count, offset in
        if fileName(fd) == "c.bin" { usleep(200_000) }   // a slow but steady current read: 1.6 s in all
        return realPread(fd, buf, count, offset)
    })
    let current = ReadPriority(0)
    current.isCurrent = true
    let cur = Task { try await reader.read(c, priority: current) }
    try await Task.sleep(for: .milliseconds(50))
    let neighbour = Task { try await reader.read(n, priority: ReadPriority(3)) }
    #expect(try await cur.value.data.count == 8 * mib)
    #expect(try await neighbour.value.data == nData)
}

/// A paused neighbour that is cancelled stops at once, without waiting for the current read.
@Test(.timeLimit(.minutes(1))) func pausedNeighbourCancels() async throws {
    let files = try TempFiles()
    let (n, _) = try files.make("n.bin", size: 4 * mib)
    let (c, _) = try files.make("c.bin", size: mib / 4)
    let gates = Gates()
    gates.block("n.bin")
    gates.block("c.bin")
    defer { gates.releaseAll() }
    let reader = FileReader(threads: 4, timeout: .seconds(10), isLocal: { _ in false }, chunkReader: gates.reader)
    let neighbour = Task { try await reader.read(n, priority: ReadPriority(3)) }
    await waitEntered(gates)
    let current = ReadPriority(0)
    current.isCurrent = true
    let cur = Task { try await reader.read(c, priority: current) }
    await waitEntered(gates)
    gates.release("n.bin")
    try await Task.sleep(for: .milliseconds(100))   // paused before its second chunk
    neighbour.cancel()
    let outcome = await within(.seconds(2)) { try await neighbour.value }
    #expect(outcome.map { if case .failure(let e) = $0 { e is CancellationError } else { false } } == true)
    gates.release("c.bin")
    _ = try await cur.value
}
