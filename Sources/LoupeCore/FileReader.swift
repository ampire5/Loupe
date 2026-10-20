import Foundation

/// The file's modification time and size when it was read: a changed stamp means the cached
/// entry is stale.
public struct FileStamp: Equatable, Sendable {
    public let modified: Date
    public let size: Int

    public init(modified: Date, size: Int) {
        self.modified = modified
        self.size = size
    }

    /// The mtime is built the way Foundation builds `contentModificationDate` (seconds since the 2001
    /// reference date, then the nanoseconds), not from the 1970 epoch: the two roundings differ by an ulp
    /// on about half of all files, and a stamp from a folder listing must equal one from `stat` exactly.
    init(_ st: stat) {
        let referenceOffset: TimeInterval = 978_307_200   // 1970 to 2001
        modified = Date(timeIntervalSinceReferenceDate: TimeInterval(st.st_mtimespec.tv_sec) - referenceOffset
                        + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        size = Int(st.st_size)
    }

    /// The stamp of a directory listing entry requested with `.fileSizeKey` and `.contentModificationDateKey`;
    /// nil when either is missing. Equal to the `stat` stamp of the same file.
    init?(_ values: URLResourceValues) {
        guard let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        self.init(modified: modified, size: size)
    }

    /// Resource keys a listing must request for `init?(_: URLResourceValues)`.
    static let listingKeys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
}

public struct FileBytes: Sendable {
    public let data: Data
    public let stamp: FileStamp
}

public enum ReadError: Error, Equatable {
    /// No bytes arrived for the whole timeout; the thread doing the read was written off.
    case notResponding
    /// The volume already ate every replacement thread; reads from it fail at once until one returns.
    case volumeStuck
}

/// A read's place in the queue, shared by the caller and the queue: the caller moves it whenever its plan changes,
/// and the queue reads it each time it picks the next job. Being shared from the moment the read is asked for,
/// a move made before the read reaches the queue is not lost.
public final class ReadPriority: @unchecked Sendable {
    /// The value the thumbnail generator reads at, behind every planned viewer read.
    public static let background = 1_000_000

    /// A background read (the thumbnail generator's): `FileReader` keeps those to the threads beyond the viewer's two,
    /// so the viewer never waits behind them, even when they hang on a dead share. Fixed at creation: the value only
    /// orders reads within their class (a viewer read that left the cache's plan is at `Int.max`, still the viewer's).
    public let isBackground: Bool

    private let lock = NSLock()
    private var current: Int
    private var onMove: (@Sendable () -> Void)?

    public init(_ value: Int, isBackground: Bool = false) {
        current = value
        self.isBackground = isBackground
    }

    /// Lower values start first. A move tells the pool the read is queued in, so it picks with the new order.
    public var value: Int {
        get { lock.withLock { current } }
        set {
            let moved = lock.withLock { () -> (@Sendable () -> Void)? in
                let changed = current != newValue
                current = newValue
                return changed ? onMove : nil
            }
            moved?()
        }
    }

    /// Set by the pool when the read is queued (one pool per reader, so one observer is enough).
    func observeMoves(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onMove = handler }
    }
}

public protocol FileReading: Sendable {
    /// Reads the whole file. Queued reads start lowest `priority.value` first (read when a thread frees up), FIFO
    /// among equals; a read already on a thread runs on whatever its priority becomes.
    func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes
    /// Reads from the start of the file only until `isEnough` accepts the bytes so far (a progressive JPEG's DC
    /// scans are enough for a thumbnail, and the rest of a multi-megabyte file would cross the network for nothing).
    /// Queued like `read`. `FileBytes.data` is that prefix, or the whole file when the predicate never accepted
    /// (or the reader does not read in steps); `stamp` is always the whole file's. `isEnough` runs on the reading
    /// thread and its `Data` is only valid during the call: it must not keep it.
    func readPrefix(_ url: URL, priority: ReadPriority, isEnough: @escaping @Sendable (Data) -> Bool) async throws -> FileBytes
    /// The file's stamp, queued like a read at `priority` (1: behind the current photo's read).
    func stamp(_ url: URL, priority: Int) async throws -> FileStamp
}

extension FileReading {
    /// Readers with no steps to stop between (fakes, mapped files) just read it all.
    public func readPrefix(_ url: URL, priority: ReadPriority, isEnough: @escaping @Sendable (Data) -> Bool) async throws -> FileBytes {
        try await read(url, priority: priority)
    }

    /// A read whose priority never moves.
    public func read(_ url: URL, priority: Int) async throws -> FileBytes {
        try await read(url, priority: ReadPriority(priority))
    }
}

/// Reads whole files on its own small thread pool (see `IOPool`), so a hung SMB share costs at
/// most a few written-off threads, never the UI or the decoders.
///
/// Local volumes are memory-mapped. Network volumes are copied in 1 MiB chunks instead: mmap
/// on SMB turns a vanished file into SIGBUS, and chunks give the watchdog progress to see and
/// cancellation a place to stop. Prefix reads use those same chunks to stop early; a mapped file is mapped whole.
public final class FileReader: FileReading, @unchecked Sendable {
    static let chunkSize = 1 << 20

    private let pool: IOPool
    private let isLocal: @Sendable (URL) -> Bool
    private let chunkReader: @Sendable (Int32, UnsafeMutableRawPointer, Int, Int) -> Int

    /// `chunkReader` is injectable for tests: reads up to `count` bytes at `offset` from an open fd (default `pread`).
    /// A hung read fails with `.notResponding` between `timeout` and `timeout` + 0.5 s (the
    /// watchdog tick) after its last progress.
    public convenience init(threads: Int = 2, timeout: Duration = .seconds(10), maxReplacements: Int = 4,
                            isLocal: @escaping @Sendable (URL) -> Bool = FileReader.volumeIsLocal,
                            chunkReader: @escaping @Sendable (Int32, UnsafeMutableRawPointer, Int, Int) -> Int = FileReader.pread) {
        self.init(threads: threads, timeout: timeout, maxReplacements: maxReplacements, isLocal: isLocal,
                  chunkReader: chunkReader, volumeIdentifier: IOPool.resolveVolumeIdentifier)
    }

    /// Tests also inject `volumeIdentifier`, to simulate a volume whose identity never resolves.
    init(threads: Int, timeout: Duration, maxReplacements: Int,
         isLocal: @escaping @Sendable (URL) -> Bool,
         chunkReader: @escaping @Sendable (Int32, UnsafeMutableRawPointer, Int, Int) -> Int,
         volumeIdentifier: @escaping @Sendable (URL) -> NSObjectProtocol?) {
        pool = IOPool(threads: threads, timeout: timeout, maxReplacements: maxReplacements,
                      volumeIdentifier: volumeIdentifier)
        self.isLocal = isLocal
        self.chunkReader = chunkReader
    }

    deinit { pool.shutdown() }

    /// `URLResourceValues.volumeIsLocal`; false on error, so an unknown volume gets the safe chunked path.
    @Sendable public static func volumeIsLocal(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? false
    }

    @Sendable public static func pread(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, _ offset: Int) -> Int {
        Darwin.pread(fd, buffer, count, off_t(offset))
    }

    public func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes {
        try await read(url, priority: priority, isEnough: nil)
    }

    /// Local files are mapped whole (mapping costs nothing until the pages are touched); network ones stop after the
    /// first chunk that `isEnough` accepts.
    public func readPrefix(_ url: URL, priority: ReadPriority, isEnough: @escaping @Sendable (Data) -> Bool) async throws -> FileBytes {
        try await read(url, priority: priority, isEnough: isEnough)
    }

    private func read(_ url: URL, priority: ReadPriority, isEnough: (@Sendable (Data) -> Bool)?) async throws -> FileBytes {
        let isLocal = self.isLocal, chunkReader = self.chunkReader
        if ArchivePath.split(url) != nil {
            // An entry of a zip (Stash spec §2.4): ranged reads of the archive in the same pool job, so the queue,
            // cancellation and the watchdog work as for a file; a prefix read gives the whole entry.
            return try await submit(url, priority: priority) { job in
                try ArchiveReader.shared.read(url, io: ArchiveReader.IO(chunkReader) {
                    if job.isCancelled { throw CancellationError() }
                    job.touch()
                })
            }
        }
        return try await submit(url, priority: priority) { job in
            // Even `volumeIsLocal` can hang on SMB, so it is asked on the pool thread.
            isLocal(url) ? try Self.readMapped(url)
                         : try Self.readChunked(url, job: job, chunkReader: chunkReader, isEnough: isEnough)
        }
    }

    /// A read at priority 0 (the front of the queue), for tests with no queue to rank against.
    func read(_ url: URL) async throws -> FileBytes { try await read(url, priority: 0) }

    /// A stamp at priority 0, for tests.
    func stamp(_ url: URL) async throws -> FileStamp { try await stamp(url, priority: 0) }

    /// Jobs waiting for a thread, for tests.
    var queuedCount: Int { pool.queuedCount }
    /// Priority moves the pool heard of, for tests.
    var priorityMoves: Int { pool.priorityMoves }

    /// `stat` on the pool: it hangs on a dead share just like a read.
    public func stamp(_ url: URL, priority: Int) async throws -> FileStamp {
        try await submit(url, priority: ReadPriority(priority)) { _ in
            if ArchivePath.split(url) != nil { return try ArchiveReader.shared.stamp(url) }
            var st = stat()
            guard stat(url.path, &st) == 0 else { throw Self.posixError() }
            return FileStamp(st)
        }
    }

    private func submit<T: Sendable>(_ url: URL, priority: ReadPriority,
                                     work: @escaping @Sendable (IOJob) throws -> T) async throws -> T {
        let job = TypedJob(url: url, priority: priority, work: work)
        let pool = self.pool
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                if job.attach(c) { pool.submit(job) }
            }
        } onCancel: {
            job.markCancelled()
            pool.withdraw(job)
            job.fail(CancellationError())
        }
    }

    private static func readMapped(_ url: URL) throws -> FileBytes {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw posixError() }
        return FileBytes(data: try Data(contentsOf: url, options: .mappedIfSafe), stamp: FileStamp(st))
    }

    /// Allocates once at the size `fstat` reported (no zero fill) and fills it chunk by chunk. A
    /// file that changes meanwhile yields what was read up to EOF or that size; the stamp is
    /// the one from open. If the file shrank, the `Data` covers only the bytes read but still
    /// owns (and frees) the whole fstat-sized allocation: the slack is temporary and rare, and
    /// trimming it would cost a copy. An early stop (`isEnough`) leaves the same slack, by design.
    ///
    /// `isEnough` is asked after every chunk that leaves the file unfinished, with a non-owning view of the filled
    /// part of the buffer (no copy per call; the buffer outlives the call and is not touched during it).
    private static func readChunked(_ url: URL, job: IOJob,
                                    chunkReader: (Int32, UnsafeMutableRawPointer, Int, Int) -> Int,
                                    isEnough: (@Sendable (Data) -> Bool)? = nil) throws -> FileBytes {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw posixError() }
        let stamp = FileStamp(st)
        let size = Int(st.st_size)
        guard size > 0 else { return FileBytes(data: Data(), stamp: stamp) }
        guard let buffer = malloc(size) else { throw POSIXError(.ENOMEM) }

        var filled = 0
        while filled < size {
            if job.isCancelled { free(buffer); throw CancellationError() }
            let n = chunkReader(fd, buffer + filled, min(chunkSize, size - filled), filled)
            if n < 0 {
                if errno == EINTR { continue }
                let error = posixError()
                free(buffer)
                throw error
            }
            if n == 0 { break }                              // shrank under us
            filled += n
            job.touch()
            if let isEnough, filled < size,
               isEnough(Data(bytesNoCopy: buffer, count: filled, deallocator: .none)) { break }
        }
        guard filled > 0 else { free(buffer); return FileBytes(data: Data(), stamp: stamp) }
        return FileBytes(data: Data(bytesNoCopy: buffer, count: filled, deallocator: .free), stamp: stamp)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
