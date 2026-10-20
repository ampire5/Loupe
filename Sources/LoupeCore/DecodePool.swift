import Foundation

/// Decode slots with a reserved share for the current photo (design §4.3).
///
/// Decodes are blocking calls of up to ~0.5 s. Neighbour (prefetch) decodes may take at most
/// `slots - reserved` slots at once, so a stale neighbour decode can never keep the current photo
/// waiting: at least `reserved` slots stay free for `forCurrent` jobs, which may take any slot.
/// Waiting jobs start current before neighbour, then best rank first (lower `rank`), then in
/// arrival order: a freed slot never goes to a neighbour while a current job is waiting.
public final class DecodePool: @unchecked Sendable {
    private let slots: Int
    private let sharedSlots: Int

    private struct Waiter {
        let id: UInt64
        let forCurrent: Bool
        let rank: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Per-`run` cancellation state, shared between the waiting code and the cancellation handler.
    private final class Ticket: @unchecked Sendable {
        var cancelled = false
    }

    // Everything below is guarded by `lock`.
    private let lock = NSLock()
    /// In arrival order; `id` grows monotonically, so the array position is the FIFO tie-break.
    private var waiting: [Waiter] = []
    private var running = 0
    private var runningShared = 0
    private var nextID: UInt64 = 0

    /// `reserved` slots only ever serve current jobs; at least one slot is always shared so
    /// neighbours still make progress when there is no current job.
    public init(slots: Int = 3, reserved: Int = 1) {
        self.slots = max(1, slots)
        self.sharedSlots = max(1, self.slots - max(0, reserved))
    }

    /// Runs blocking `work` on a pool thread once a slot is free. `forCurrent` jobs may take any slot,
    /// others only the `slots - reserved` shared ones. Waiting jobs start current first, then by rank (lower first),
    /// then in arrival order.
    /// Cancelled while waiting → CancellationError without running; once started, work runs to completion.
    public func run<T: Sendable>(forCurrent: Bool, rank: Int, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await acquire(forCurrent: forCurrent, rank: rank)
        // Cancelled between the grant and the start: hand the slot back, don't begin the work.
        if Task.isCancelled {
            release(forCurrent: forCurrent)
            throw CancellationError()
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try work() }
                // Free the slot before the caller resumes, so a follow-up job sees it free.
                self.release(forCurrent: forCurrent)
                continuation.resume(with: result)
            }
        }
    }

    /// Takes a slot without running anything on it, for a pool used as an async limiter around work that runs
    /// elsewhere (the cache's one-progressive-full-decode-at-a-time gate). Same order and cancellation as `run`;
    /// every successful call must be paired with `releaseSlot(forCurrent:)` with the same `forCurrent`.
    func acquireSlot(forCurrent: Bool, rank: Int) async throws {
        try await acquire(forCurrent: forCurrent, rank: rank)
        if Task.isCancelled {
            release(forCurrent: forCurrent)
            throw CancellationError()
        }
    }

    func releaseSlot(forCurrent: Bool) { release(forCurrent: forCurrent) }

    // MARK: Test hooks

    var waitingCount: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }
    var runningCount: Int { lock.lock(); defer { lock.unlock() }; return running }

    // MARK: Slots

    /// Returns once the caller holds a slot (counted in `running`), or throws CancellationError without one.
    private func acquire(forCurrent: Bool, rank: Int) async throws {
        let ticket = Ticket()
        let id: UInt64 = lock.withLock { defer { nextID += 1 }; return nextID }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if ticket.cancelled {
                    // Cancelled before the entry existed: never enqueue.
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if waiting.isEmpty && hasFreeSlot(forCurrent: forCurrent) {
                    take(forCurrent: forCurrent)
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting.append(Waiter(id: id, forCurrent: forCurrent, rank: rank, continuation: continuation))
                    let granted = grantWaiters()
                    lock.unlock()
                    granted.forEach { $0.resume() }
                }
            }
        } onCancel: {
            lock.lock()
            ticket.cancelled = true
            let index = waiting.firstIndex { $0.id == id }
            let waiter = index.map { waiting.remove(at: $0) }
            lock.unlock()
            // Already granted (or running): not in the queue any more, nothing to undo.
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    private func release(forCurrent: Bool) {
        lock.lock()
        running -= 1
        if !forCurrent { runningShared -= 1 }
        let granted = grantWaiters()
        lock.unlock()
        granted.forEach { $0.resume() }
    }

    // The helpers below require `lock` to be held.

    private func hasFreeSlot(forCurrent: Bool) -> Bool {
        running < slots && (forCurrent || runningShared < sharedSlots)
    }

    private func take(forCurrent: Bool) {
        running += 1
        if !forCurrent { runningShared += 1 }
    }

    /// Hands free slots to the best eligible waiters; the caller resumes the returned continuations
    /// after unlocking. A waiter blocked by the shared limit is skipped, not allowed to hold up
    /// a lower-priority waiter that is eligible (a current job behind a neighbour, say).
    private func grantWaiters() -> [CheckedContinuation<Void, Error>] {
        var granted: [CheckedContinuation<Void, Error>] = []
        while running < slots {
            var best: Int?
            for (i, w) in waiting.enumerated() where hasFreeSlot(forCurrent: w.forCurrent) {
                guard let b = best else { best = i; continue }
                let o = waiting[b]
                // Strictly better only: ties keep the earlier arrival (array order).
                if w.forCurrent != o.forCurrent ? w.forCurrent : w.rank < o.rank { best = i }
            }
            guard let i = best else { break }
            let w = waiting.remove(at: i)
            take(forCurrent: w.forCurrent)
            granted.append(w.continuation)
        }
        return granted
    }
}
