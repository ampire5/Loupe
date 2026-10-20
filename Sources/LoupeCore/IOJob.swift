import Foundation

// Jobs and volume identity for `IOPool`, kept apart so the pool file is just the scheduling.

/// Which volume a file lives on, so new reads from a share that already ate threads can be refused.
struct VolumeKey: @unchecked Sendable {
    /// `URLResourceValues.volumeIdentifier`; resolved on a pool thread because it can hang on SMB.
    var identifier: NSObjectProtocol?
    /// `/Volumes/<name>`: known without any I/O, the fallback when there is no identifier.
    var mountPath: String?

    init(url: URL) {
        let parts = url.standardizedFileURL.pathComponents      // ["/", "Volumes", "Share", ...]
        mountPath = parts.count > 2 && parts[1] == "Volumes" ? "/Volumes/" + parts[2] : nil
    }

    func sameVolume(as other: VolumeKey) -> Bool {
        if let a = identifier, let b = other.identifier { return a.isEqual(b) }
        if let a = mountPath, let b = other.mountPath { return a == b }
        return false
    }
}

/// One queued read or stat. The pool sees it untyped; `TypedJob` carries the caller's continuation.
class IOJob: @unchecked Sendable {
    let url: URL
    /// The parent directory: the cache key that lets a later job's volume be known without I/O.
    let directory: String
    /// Guarded by the pool lock.
    var volume: VolumeKey
    /// Guarded by the pool lock: the watchdog wrote this job's thread off.
    var lost = false
    /// Guarded by the pool lock: running in the background share (`ReadPriority.isBackground`).
    var background = false
    /// Queued jobs start lowest value first; the caller may move it at any time (the pool reads it when it picks).
    let priority: ReadPriority

    private let lock = NSLock()
    private var progressAt: UInt64 = 0
    private var cancelled = false

    init(url: URL, priority: ReadPriority) {
        self.url = url
        self.priority = priority
        directory = url.standardizedFileURL.deletingLastPathComponent().path
        volume = VolumeKey(url: url)
    }

    /// Records that bytes arrived; the watchdog only fails jobs that stop making progress.
    func touch() { lock.withLock { progressAt = DispatchTime.now().uptimeNanoseconds } }
    var lastProgress: UInt64 { lock.withLock { progressAt } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func markCancelled() { lock.withLock { cancelled = true } }

    /// Runs the work on the calling pool thread and returns the delivery of its result, so the pool
    /// can finish its bookkeeping before the caller resumes.
    func perform() -> () -> Void { fatalError("abstract") }
    /// Resolves the caller with `error` unless it was already resolved.
    func fail(_ error: Error) { fatalError("abstract") }
}

/// Bridges a job to a checked continuation that is resumed exactly once: completion, timeout or
/// cancellation, whichever comes first; the others become no-ops.
final class TypedJob<T: Sendable>: IOJob, @unchecked Sendable {
    private let work: @Sendable (IOJob) throws -> T
    private let resolveLock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?       // resolved before the continuation was attached
    private var resolved = false

    init(url: URL, priority: ReadPriority, work: @escaping @Sendable (IOJob) throws -> T) {
        self.work = work
        super.init(url: url, priority: priority)
    }

    /// Returns false (resuming `c` at once) when the job was already resolved, e.g. cancelled
    /// before it was attached; then it must not be queued.
    func attach(_ c: CheckedContinuation<T, Error>) -> Bool {
        resolveLock.lock()
        if resolved, let result = pending {
            pending = nil
            resolveLock.unlock()
            c.resume(with: result)
            return false
        }
        continuation = c
        resolveLock.unlock()
        return true
    }

    func resolve(_ result: Result<T, Error>) {
        resolveLock.lock()
        guard !resolved else { resolveLock.unlock(); return }
        resolved = true
        let c = continuation
        continuation = nil
        if c == nil { pending = result }
        resolveLock.unlock()
        c?.resume(with: result)
    }

    override func perform() -> () -> Void {
        let result = Result { try work(self) }
        return { self.resolve(result) }
    }

    override func fail(_ error: Error) { resolve(.failure(error)) }
}
