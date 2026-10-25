import Foundation

// The pool behind `FileReader`: dedicated threads, a priority queue (FIFO among equal priorities), and a watchdog
// that writes off threads stuck in a read. Split out of FileReader.swift so the file-reading code stays readable;
// the jobs and `VolumeKey` live in IOJob.swift.
//
// Dedicated `Thread`s, not the cooperative pool: a read blocked on a hung SMB share must not
// take a thread away from decoding or the UI.

/// Where a written-off thread got stuck. The directory is the last-resort match when the
/// volume never resolved (no identifier yet, not under /Volumes): the loss still makes at least
/// that folder refusable.
private struct StuckMark {
    let key: VolumeKey
    let directory: String

    func matches(_ key: VolumeKey, directory: String) -> Bool {
        self.key.sameVolume(as: key) || self.directory == directory
    }
}

/// Worst case for a hung read: it fails `timeout` + one watchdog `tick` (0.5 s) after its last
/// progress, since the watchdog only looks twice a second.
///
/// The threads are shared out by class: background jobs (`ReadPriority.isBackground`, the thumbnail reads) run on at
/// most `threads - viewerThreads` of them (at least one), the others on at most `viewerThreads`; the priority value
/// orders jobs within a class. So with four threads the viewer keeps the two it always had, however many thumbnail
/// reads are queued or stuck, and the thumbnail reads get two of their own.
///
/// Within the viewer's share one thread is the current photo's (`ReadPriority.isCurrent`, read when a job is picked):
/// neighbour reads run on at most `viewerThreads - 1`, so a photo stepped to never waits for a free thread behind
/// neighbour reads already running (a running read is never preempted, and a share's reads can take seconds); when
/// the viewer's share is full all the same, a current read takes any idle thread of the pool. And
/// while a current read runs, running neighbour reads pause before their next chunk (`yieldToCurrent`), their bytes so
/// far kept, so the current read has the share's bandwidth to itself; they go on once no current read runs.
///
/// The shares count jobs on live threads: a job written off by the watchdog no longer counts, and its replacement
/// thread serves either class. Past `maxReplacements` write-offs no replacement comes (but for the last thread), so
/// the pool can run on fewer than `threads` and the viewer's two are no longer guaranteed; by then the stuck volume's
/// jobs are refused before any I/O, so only another volume hanging as well can take them.
final class IOPool: @unchecked Sendable {
    static let tick: DispatchTimeInterval = .milliseconds(500)
    /// Two, one of them the current photo's (`neighbourLimit`). Measured with `LoupeBench sharesim`
    /// (docs/bench/2026-10-23-current-first.md; i7-10700K, 8 cores, 64 GB, macOS 26): a share simulated on local JPEGs
    /// of 10–19 MiB at 100 MiB/s shared by all reads; three neighbour reads running, the current photo's read asked
    /// for 100 ms later had its bytes back after 471–818 ms with both viewer threads open to neighbours and no pause,
    /// after 128–266 ms (the file alone needs 100–186 ms) with a thread kept for it and the neighbours paused. On a
    /// local SSD (files are mapped: no thread is held), `replay --script jumpfar`: no change.
    static let viewerThreads = 2

    private let threads: Int
    private let foregroundLimit: Int
    /// Neighbour reads (the viewer's, not current) at once: one viewer thread stays the current photo's.
    private let neighbourLimit: Int
    private let backgroundLimit: Int
    private let timeoutNanos: UInt64
    private let maxReplacements: Int
    private let volumeIdentifier: @Sendable (URL) -> NSObjectProtocol?
    private let watchdog: DispatchSourceTimer

    // Everything below is guarded by `cond`.
    private let cond = NSCondition()
    /// Waiting jobs in submission order; a worker takes the lowest priority value (the first of equals). Small (a
    /// few dozen at most), so a linear scan is cheaper than keeping it sorted while priorities move.
    private var queue: [IOJob] = []
    private var running: [IOJob] = []
    private var live = 0
    /// Written-off threads that have not returned yet; up to `maxReplacements` of them are replaced.
    private var lost = 0
    /// Where the lost threads are stuck.
    private var stuck: [StuckMark] = []
    /// Directory → resolved volume, so the cheap checks need no I/O.
    private var volumes: [String: VolumeKey] = [:]
    private var watchdogArmed = false
    private var moves = 0
    private var shutDown = false

    /// `volumeIdentifier` is injectable so tests can simulate a volume whose identity never resolves.
    init(threads: Int, timeout: Duration, maxReplacements: Int,
         volumeIdentifier: @escaping @Sendable (URL) -> NSObjectProtocol? = IOPool.resolveVolumeIdentifier) {
        self.threads = max(1, threads)
        foregroundLimit = min(self.threads, Self.viewerThreads)
        neighbourLimit = max(1, foregroundLimit - 1)
        backgroundLimit = max(1, self.threads - Self.viewerThreads)
        let (seconds, attoseconds) = timeout.components
        timeoutNanos = UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds) / 1_000_000_000)
        self.maxReplacements = maxReplacements
        self.volumeIdentifier = volumeIdentifier
        watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Loupe I/O watchdog"))
        watchdog.setEventHandler { [weak self] in self?.checkProgress() }
        watchdog.schedule(deadline: .distantFuture)
        watchdog.activate()
        cond.lock()
        for _ in 0..<self.threads { spawnWorker() }
        cond.unlock()
    }

    @Sendable static func resolveVolumeIdentifier(_ url: URL) -> NSObjectProtocol? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
    }

    func submit(_ job: IOJob) {
        cond.lock()
        if shutDown { cond.unlock(); job.fail(CancellationError()); return }
        if isStuck(job) { cond.unlock(); job.fail(ReadError.volumeStuck); return }
        job.priority.observeMoves { [weak self] in self?.priorityMoved() }
        job.pool = self
        queue.append(job)
        cond.signal()
        cond.unlock()
    }

    /// Jobs waiting for a thread, for tests.
    var queuedCount: Int { cond.withLock { queue.count } }
    /// Priority moves heard of, for tests.
    var priorityMoves: Int { cond.withLock { moves } }

    /// Drops a cancelled job that has not started; a running one stops at its next chunk (a paused one at once).
    func withdraw(_ job: IOJob) {
        cond.lock()
        queue.removeAll { $0 === job }
        cond.broadcast()   // a paused job sees its cancellation
        cond.unlock()
    }

    /// Called by a running job before each chunk: a neighbour read (the viewer's, not current: the active window's or a
    /// keep set's, CLAUDE.md's background yielding to the foreground) waits here while a current read runs on another
    /// thread, then goes on (returning at once when cancelled, so its caller stops). The
    /// watchdog leaves a paused job alone: it reads nothing because it was told to wait, not because its volume hangs.
    func yieldToCurrent(_ job: IOJob) {
        cond.lock()
        defer { cond.unlock() }
        guard !job.background else { return }
        var paused = false
        while !job.isCancelled, !shutDown, !job.priority.isCurrent,
              running.contains(where: { $0 !== job && !$0.background && $0.priority.isCurrent }) {
            if !paused {
                paused = true
                job.paused = true
            }
            cond.wait()
        }
        guard paused else { return }
        job.paused = false
        job.touch()   // its timeout counts from here
    }

    /// Lets idle threads exit; queued callers get `CancellationError`. Lost threads that come back
    /// later only touch this object, which they keep alive.
    func shutdown() {
        cond.lock()
        shutDown = true
        let pending = queue
        queue = []
        cond.broadcast()
        cond.unlock()
        watchdog.cancel()
        for job in pending { job.fail(CancellationError()) }
    }

    /// Locked. The best key known without I/O: the job's own once resolved, else whatever an
    /// earlier job in the same directory resolved, else the `/Volumes/<name>` fallback.
    private func cheapKey(_ job: IOJob) -> VolumeKey {
        job.volume.identifier != nil ? job.volume : (volumes[job.directory] ?? job.volume)
    }

    /// Locked. Refuses a volume only once replacements ran out, so the remaining threads stay
    /// available for other volumes.
    private func isStuck(_ job: IOJob) -> Bool {
        guard lost > maxReplacements else { return false }
        let key = cheapKey(job)
        return stuck.contains { $0.matches(key, directory: job.directory) }
    }

    /// Locked. The lowest priority value as of now (callers move theirs at any time) among the jobs whose class has
    /// room on the threads; among equals the first, i.e. the earliest submitted (removals keep the order). Nil when
    /// none may start.
    private func nextIndex() -> (index: Int, background: Bool)? {
        let background = running.reduce(0) { $0 + ($1.background ? 1 : 0) }
        let neighbours = running.reduce(0) { $0 + (!$1.background && !$1.priority.isCurrent ? 1 : 0) }
        let foregroundRoom = running.count - background < foregroundLimit
        let neighbourRoom = foregroundRoom && neighbours < neighbourLimit
        // A current read may also take an idle thread of the background share: the viewer's two can both hold
        // non-current reads (a photo stepped to after a dwell, still reading when the user steps again, is the next
        // photo's neighbour now), and a running read is never preempted. The thumbnails' reads are cancelled while the
        // current photo reads (`ThumbnailStore.setViewerActivity`), so those threads are usually free; never more
        // threads than the pool has.
        let currentRoom = foregroundRoom || running.count < live
        let backgroundRoom = background < backgroundLimit
        var best: (index: Int, value: Int, background: Bool)?
        for (i, job) in queue.enumerated() {
            // A keep set's read (a window not in front) shares the neighbours' thread; its value is past theirs.
            let readClass = job.priority.readClass
            let room = switch readClass {
            case .background: backgroundRoom
            case .current: currentRoom
            case .foreground, .keep: neighbourRoom
            }
            guard room else { continue }
            let value = job.priority.value
            if best == nil || value < best!.value { best = (i, value, readClass == .background) }
        }
        return best.map { ($0.index, $0.background) }
    }

    /// A job's priority moved: idle workers look again (a neighbour that became current may start on the reserved
    /// thread), and paused neighbours check whether a current read still runs.
    private func priorityMoved() {
        cond.lock()
        moves += 1
        cond.broadcast()
        cond.unlock()
    }

    /// Locked.
    private func spawnWorker() {
        live += 1
        let thread = Thread { [self] in workerLoop() }
        thread.name = "Loupe I/O"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func workerLoop() {
        cond.lock()
        while true {
            var next = nextIndex()
            while next == nil && !shutDown {
                cond.wait()
                next = nextIndex()
            }
            guard let next else { live -= 1; cond.unlock(); return }   // shut down (the queue was emptied)
            let job = queue.remove(at: next.index)
            if job.isCancelled { continue }                  // its caller already has CancellationError
            job.touch()
            job.background = next.background
            running.append(job)
            armWatchdog()
            cond.unlock()

            let deliver = run(job)

            cond.lock()
            if job.lost {
                // A written-off thread came back: its result was already replaced by
                // `.notResponding`. The return is taken as proof that the volume answers again,
                // so all of its stuck marks are cleared, not just this job's. The thread rejoins
                // only if the pool is short of `threads`; otherwise its replacement has the slot.
                lost -= 1
                let key = cheapKey(job)
                stuck.removeAll { $0.matches(key, directory: job.directory) }
                if live >= threads || shutDown { cond.unlock(); return }
                live += 1
            } else {
                running.removeAll { $0 === job }
                cond.broadcast()                             // a share has room again: a waiting job of it may start
            }
            cond.unlock()
            deliver()
            cond.lock()
        }
    }

    private func run(_ job: IOJob) -> () -> Void {
        // Cheap check first: a job queued for a dead share before it was marked must not reach
        // the resource-value lookup below, which would hang this thread too.
        cond.lock()
        var refused = isStuck(job)
        cond.unlock()
        if refused { return { job.fail(ReadError.volumeStuck) } }

        // Volume identity can itself hang on a dead share, so it is looked up here, under the watchdog.
        let identifier = volumeIdentifier(job.url)
        cond.lock()
        if let identifier {
            job.volume.identifier = identifier
            if volumes.count >= 512 { volumes.removeAll() }
            volumes[job.directory] = job.volume
        }
        refused = isStuck(job)
        cond.unlock()
        if refused { return { job.fail(ReadError.volumeStuck) } }
        return job.perform()
    }

    /// Locked. The watchdog only runs while something is in flight: an idle viewer does not wake.
    private func armWatchdog() {
        guard !watchdogArmed, !shutDown else { return }
        watchdogArmed = true
        watchdog.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .milliseconds(50))
    }

    private func checkProgress() {
        let now = DispatchTime.now().uptimeNanoseconds
        var timedOut: [IOJob] = []
        var refused: [IOJob] = []
        cond.lock()
        running.removeAll { job in
            let last = job.lastProgress
            guard !job.paused, now > last, now - last > timeoutNanos else { return false }
            job.lost = true
            timedOut.append(job)
            return true
        }
        for job in timedOut {
            lost += 1
            live -= 1
            stuck.append(StuckMark(key: cheapKey(job), directory: job.directory))
            // Beyond `maxReplacements` a thread is still spawned when none would be left: jobs of
            // marked volumes are refused before any I/O, so the last thread serves other volumes.
            // Growth past the limit then needs a fresh hung volume each time.
            if (lost <= maxReplacements || live == 0) && !shutDown { spawnWorker() }
        }
        if !timedOut.isEmpty { cond.broadcast() }          // their shares have room again
        if !timedOut.isEmpty && lost > maxReplacements {
            // Jobs queued for a now-refused volume would only wait for a thread to hang on.
            refused = queue.filter { isStuck($0) }
            queue.removeAll { job in refused.contains { $0 === job } }
        }
        if running.isEmpty && watchdogArmed {
            watchdogArmed = false
            watchdog.schedule(deadline: .distantFuture)
        }
        cond.unlock()
        for job in timedOut { job.fail(ReadError.notResponding) }
        for job in refused { job.fail(ReadError.volumeStuck) }
    }
}
