import Foundation
import Synchronization

/// The check of which recent paths can be reached (Home spec §3.3); the grid itself is HomeScreenKit's.
public enum HomeGrid {
    // At most half the physical cores, capped at four utility calls. On Mac16,6 (14 physical cores),
    // three batches of 24 checks, 20 ms deadlines and 400 ms work left 72 workers before this gate,
    // four afterwards (2026-11-05). The same bounded budget is reused across refreshes.
    static let workerLimit = min(4, max(1, Machine.physicalCores / 2))
    private static let checks = BlockingChecks(limit: workerLimit)

    /// Whether each path exists: nil when it cannot answer within the batch's deadline. Checks waiting for
    /// admission are cancelled at that deadline; an already blocked kernel call keeps its slot until it returns.
    public static func availability(of paths: [String], timeout: Duration,
                                    check: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        async -> [String: Bool?] {
        await availability(of: paths, timeout: timeout, checks: checks, check: check)
    }

    static func availability(of paths: [String], timeout: Duration, checks: BlockingChecks,
                             check: @escaping @Sendable (String) -> Bool) async -> [String: Bool?] {
        var seen: Set<String> = []
        let paths = paths.filter { seen.insert($0).inserted }
        let deadline = ContinuousClock.now + timeout
        return await withTaskGroup(of: (String, Bool?).self) { group in
            var result = Dictionary(uniqueKeysWithValues: paths.map { ($0, Bool?.none) })
            var next = 0
            func enqueue() {
                guard next < paths.count, !Task.isCancelled else { return }
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { return }
                let path = paths[next]
                next += 1
                group.addTask {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    return (path, await checks.value(key: path, within: remaining) { check(path) })
                }
            }
            for _ in 0..<min(checks.limit, paths.count) { enqueue() }
            for await (path, answer) in group {
                result[path] = .some(answer)
                enqueue()
            }
            return result
        }
    }

    /// Bounded utility work, or nil at its deadline/cancellation. The deadline never waits for blocking work.
    public static func value<T: Sendable>(within timeout: Duration, _ work: @escaping @Sendable () -> T) async -> T? {
        await checks.value(within: timeout, work)
    }
}

/// Shares admission across Home checks and free-space queries. A timed-out path stays reserved until its
/// actual blocking call returns, so repeated refreshes cannot multiply workers stuck on the same path.
final class BlockingChecks: Sendable {
    private let pool: DecodePool
    private let paths = Mutex<Set<String>>([])

    var limit: Int { pool.slotCount }

    init(limit: Int) { pool = DecodePool(slots: limit, reserved: 0, qos: .utility) }

    func value<T: Sendable>(key: String? = nil, within timeout: Duration,
                            _ work: @escaping @Sendable () -> T) async -> T? {
        guard !Task.isCancelled, timeout > .zero else { return nil }
        let deadline = ContinuousClock.now + timeout
        if let key, !paths.withLock({ $0.insert(key).inserted }) { return nil }
        let answer = CheckAnswer<T>()
        // This task can outlive its waiter only while a kernel call owns a bounded slot. Cancelling it
        // removes pending admission immediately; a started call releases its slot only after returning.
        // Detached utility work is intentional: the bounded blocking call may outlive its waiter;
        // this method explicitly propagates cancellation and never inherits a UI caller's actor.
        let worker = Task.detached(priority: .utility) { [self] in
            defer { if let key { _ = paths.withLock { $0.remove(key) } } }
            do {
                let value = try await pool.run(forCurrent: false, rank: 0) {
                    answer.isFinished || ContinuousClock.now >= deadline ? nil : work()
                }
                answer.finish(ContinuousClock.now < deadline ? value : nil)
            }
            catch { answer.finish(nil) }
        }
        // The independent timer shares the explicit lifetime and cannot be held behind blocking I/O.
        let timer = Task.detached(priority: .utility) {
            guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
            answer.finish(nil)
        }
        return await withTaskCancellationHandler {
            let value = await answer.value()
            worker.cancel()
            timer.cancel()
            return value
        } onCancel: {
            answer.finish(nil)
            worker.cancel()
            timer.cancel()
        }
    }
}

/// Publishes exactly once without holding the caller open until a blocking call completes.
private final class CheckAnswer<T: Sendable>: Sendable {
    private struct State: Sendable {
        var finished = false
        var result: T?
        var waiter: CheckedContinuation<T?, Never>?
    }
    private let state = Mutex(State())

    var isFinished: Bool { state.withLock { $0.finished } }

    func finish(_ result: T?) {
        let waiter = state.withLock { state -> CheckedContinuation<T?, Never>? in
            guard !state.finished else { return nil }
            state.finished = true
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: result)
    }

    func value() async -> T? {
        await withCheckedContinuation { continuation in
            let completed = state.withLock { state -> Bool in
                guard !state.finished else { return true }
                state.waiter = continuation
                return false
            }
            if completed { continuation.resume(returning: state.withLock { $0.result }) }
        }
    }
}
