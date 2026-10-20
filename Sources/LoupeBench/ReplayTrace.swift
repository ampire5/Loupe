import Darwin
import Foundation
import LoupeCore

// Stage tracing for `replay` (the jump scripts): where the landing photo's time goes after the user stops, from the
// I/O queue to the screen. The cache side comes from `ImageCache.setTrace`; the read side from `TracingReader`, a
// FileReading wrapper around the app's FileReader (same pool, same chunked SMB path), so the product code only
// gains a nil-by-default hook.

/// One traced moment: a cache stage boundary or a read stage.
struct TraceRecord {
    let url: URL
    let kind: String
    let goal: CacheGoal?
    let level: Int?
    var priority: Int? = nil
    let time: ContinuousClock.Instant
}

/// All trace records of a script run, from any thread.
final class TraceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [TraceRecord] = []

    func add(_ r: TraceRecord) { lock.withLock { records.append(r) } }

    func add(_ e: CacheTraceEvent) {
        add(TraceRecord(url: e.url, kind: e.kind.rawValue, goal: e.goal, level: e.level, priority: e.priority, time: e.time))
    }

    var all: [TraceRecord] { lock.withLock { records } }

    func events(for url: URL) -> [TraceRecord] { lock.withLock { records.filter { $0.url.path == url.path } } }
}

/// FileReader with read-stage tracing: `readSubmitted` when the cache asks (the job enters the FIFO I/O queue),
/// `readStarted` when a pool thread reads its first chunk, `readDone` when the bytes are back. Optionally reads with
/// `F_NOCACHE`, so every read goes to the SMB server as on a folder's first visit (the macOS client cache would
/// otherwise serve repeated runs from RAM). Counts queued and running reads for snapshots.
final class TracingReader: FileReading, @unchecked Sendable {
    private let inner: FileReader
    private let log: TraceLog
    private let lock = NSLock()
    private var submitted = 0
    private var started = 0
    private var finished = 0

    init(log: TraceLog, noCache: Bool) {
        self.log = log
        let box = StartBox()
        inner = FileReader(chunkReader: { fd, buffer, count, offset in
            if offset == 0 {
                if noCache { _ = fcntl(fd, F_NOCACHE, 1) }
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                if fcntl(fd, F_GETPATH, &path) != -1 { box.started?(String(cString: path)) }
            }
            return FileReader.pread(fd, buffer, count, offset)
        })
        box.started = { [weak self] path in self?.didStart(path) }
    }

    private func didStart(_ path: String) {
        lock.withLock { started += 1 }
        log.add(TraceRecord(url: URL(fileURLWithPath: path), kind: "readStarted", goal: nil, level: nil, time: .now))
    }

    /// Reads waiting in the FIFO queue, and reads a pool thread is on (local files, which skip the chunk reader,
    /// count as queued until done; the replay folders are all on SMB).
    var load: (queued: Int, running: Int) {
        lock.withLock { (submitted - started, started - finished) }
    }

    func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes {
        lock.withLock { submitted += 1 }
        log.add(TraceRecord(url: url, kind: "readSubmitted", goal: nil, level: nil, priority: priority.value, time: .now))
        do {
            let bytes = try await inner.read(url, priority: priority)
            finish(url, "readDone")
            return bytes
        } catch {
            finish(url, "readFailed")
            throw error
        }
    }

    /// A read that never reached a thread (cancelled while queued) leaves `started` behind: count it as started.
    private func finish(_ url: URL, _ kind: String) {
        let now = ContinuousClock.now
        let didStart = log.events(for: url).last { $0.kind == "readStarted" || $0.kind == "readSubmitted" }?.kind == "readStarted"
        lock.withLock {
            if !didStart { started += 1 }
            finished += 1
        }
        log.add(TraceRecord(url: url, kind: didStart ? kind : kind + "(never started)", goal: nil, level: nil, time: now))
    }

    func stamp(_ url: URL, priority: Int) async throws -> FileStamp { try await inner.stamp(url, priority: priority) }
}

private final class StartBox: @unchecked Sendable {
    var started: (@Sendable (String) -> Void)?
}

/// The cache, I/O and decode pool at one moment of a landing.
struct LoadSnapshot {
    let atMs: Double
    let ioQueued, ioRunning: Int
    let decodeWaiting, decodeRunning: Int
    let usedBytes, limitBytes: Int
}

/// A jump's landing photo: what was going on when the user stopped, and the photo's stages afterwards.
struct LandingRecord {
    let step: Int
    let index: Int
    let url: URL
    let stop: ContinuousClock.Instant
    /// Taken right after the stop's focus reached the cache.
    var atStop: LoadSnapshot?
    /// Entries current-3 … current+12 at the stop (offset, probe).
    var window: [(offset: Int, probe: CacheEntryProbe?)] = []
    /// Every 100 ms until the next step.
    var series: [LoadSnapshot] = []
    /// The landing photo's trace records since the previous landing (relative times are taken from `stop`).
    var events: [TraceRecord] = []
    /// Every read (any photo) submitted, started, finished or cancelled from 1 s before the stop to the next step,
    /// for the order of the I/O queue.
    var reads: [TraceRecord] = []
}
