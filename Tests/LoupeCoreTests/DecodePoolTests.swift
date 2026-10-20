import Foundation
import Testing
@testable import LoupeCore

// Every test releases its gates before it ends, so no pool thread stays blocked after the suite.
// Waiting is observed through the pool's own counters, never through sleeps.

private struct Boom: Error, Equatable {}

/// A latch a blocking job parks on until the test opens it.
private final class Gate: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false

    func wait() { sem.wait() }
    func open() {
        lock.lock(); defer { lock.unlock() }
        if opened { return }
        opened = true
        sem.signal()
    }
}

/// Records what ran, in order, and lets the test wait for a job to have started.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func started(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        items.append(name)
    }

    /// Waits (up to 10 s) until `name` has started; false on timeout. Polls instead of blocking on a semaphore: a
    /// blocked cooperative thread starves the pool's own tasks on a machine with few cores (CI runners have 3).
    func awaitStarted(_ name: String) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !has(name) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    var order: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func has(_ name: String) -> Bool { order.contains(name) }
}

/// Polls until `condition` holds (up to 10 s); no fixed sleeps in the passing path.
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

/// A job that records its start and parks on `gate`.
private func blocking(_ name: String, _ log: Log, _ gate: Gate) -> @Sendable () throws -> String {
    { log.started(name); gate.wait(); return name }
}

private func instant(_ name: String, _ log: Log) -> @Sendable () throws -> String {
    { log.started(name); return name }
}

@Suite struct DecodePoolTests {
    @Test func sharedJobsLeaveReservedSlot() async throws {
        let pool = DecodePool(slots: 3, reserved: 1)
        let log = Log()
        let g1 = Gate(), g2 = Gate()
        let n1 = Task { try await pool.run(forCurrent: false, rank: 1, blocking("n1", log, g1)) }
        let n2 = Task { try await pool.run(forCurrent: false, rank: 2, blocking("n2", log, g2)) }
        #expect(await log.awaitStarted("n1")); #expect(await log.awaitStarted("n2"))

        let n3 = Task { try await pool.run(forCurrent: false, rank: 3, instant("n3", log)) }
        #expect(await waitUntil { pool.waitingCount == 1 })

        // The current photo starts at once, on the reserved slot, while n3 keeps waiting.
        let value = try await pool.run(forCurrent: true, rank: 9, instant("cur", log))
        #expect(value == "cur")
        #expect(!log.has("n3"))
        #expect(pool.waitingCount == 1)

        g1.open()                      // a shared slot frees: n3 takes it
        #expect(try await n3.value == "n3")
        g2.open()
        _ = try await n1.value
        _ = try await n2.value
        #expect(pool.runningCount == 0)
    }

    @Test func currentJobsMayUseAnySlot() async throws {
        let pool = DecodePool(slots: 3, reserved: 1)
        let log = Log()
        let gates = [Gate(), Gate(), Gate()]
        let tasks = (0..<3).map { i in
            Task { try await pool.run(forCurrent: true, rank: i, blocking("c\(i)", log, gates[i])) }
        }
        for i in 0..<3 { #expect(await log.awaitStarted("c\(i)")) }
        #expect(pool.runningCount == 3)
        gates.forEach { $0.open() }
        for t in tasks { _ = try await t.value }
    }

    @Test func currentIsNeverStarvedByNeighbours() async throws {
        let pool = DecodePool(slots: 3, reserved: 1)
        let log = Log()
        let g1 = Gate(), g2 = Gate()
        let n1 = Task { try await pool.run(forCurrent: false, rank: 0, blocking("n1", log, g1)) }
        let n2 = Task { try await pool.run(forCurrent: false, rank: 0, blocking("n2", log, g2)) }
        #expect(await log.awaitStarted("n1")); #expect(await log.awaitStarted("n2"))

        // Two neighbours hold the shared slots and a third queues with the best rank; a current job
        // (worst rank) still starts at once on the reserved slot, and again after it finished.
        let n3 = Task { try await pool.run(forCurrent: false, rank: 0, instant("n3", log)) }
        #expect(await waitUntil { pool.waitingCount == 1 })
        _ = try await pool.run(forCurrent: true, rank: 100, instant("cur1", log))

        // And it again after the first current job finished: the reserved slot was released, not lost.
        _ = try await pool.run(forCurrent: true, rank: 100, instant("cur2", log))
        #expect(!log.has("n3"))

        g1.open(); g2.open()
        _ = try await n3.value; _ = try await n1.value; _ = try await n2.value
    }

    @Test func currentOutranksBetterRankedNeighbourWhenContested() async throws {
        let pool = DecodePool(slots: 3, reserved: 1)
        let log = Log()
        let gates = [Gate(), Gate(), Gate()]
        let busy = (0..<3).map { i in
            Task { try await pool.run(forCurrent: true, rank: i, blocking("busy\(i)", log, gates[i])) }
        }
        for i in 0..<3 { #expect(await log.awaitStarted("busy\(i)")) }

        let neighbour = Task { try await pool.run(forCurrent: false, rank: 0, instant("neighbour", log)) }
        #expect(await waitUntil { pool.waitingCount == 1 })
        let current = Task { try await pool.run(forCurrent: true, rank: 100, instant("current", log)) }
        #expect(await waitUntil { pool.waitingCount == 2 })

        gates[0].open()                // one slot frees: the current job takes it, not the rank-0 neighbour
        _ = try await current.value
        _ = try await neighbour.value
        #expect(Array(log.order.suffix(2)) == ["current", "neighbour"])

        gates[1].open(); gates[2].open()
        for t in busy { _ = try await t.value }
    }

    @Test func rankOrder() async throws {
        let pool = DecodePool(slots: 1, reserved: 0)
        let log = Log()
        let gate = Gate()
        let blocker = Task { try await pool.run(forCurrent: false, rank: 0, blocking("blocker", log, gate)) }
        #expect(await log.awaitStarted("blocker"))

        var tasks: [Task<String, Error>] = []
        for (i, rank) in [5, 1, 3].enumerated() {
            tasks.append(Task { try await pool.run(forCurrent: false, rank: rank, instant("r\(rank)", log)) })
            #expect(await waitUntil { pool.waitingCount == i + 1 })
        }
        gate.open()
        _ = try await blocker.value
        for t in tasks { _ = try await t.value }
        #expect(log.order == ["blocker", "r1", "r3", "r5"])
    }

    @Test func equalRanksStartInArrivalOrder() async throws {
        let pool = DecodePool(slots: 1, reserved: 0)
        let log = Log()
        let gate = Gate()
        let blocker = Task { try await pool.run(forCurrent: false, rank: 0, blocking("blocker", log, gate)) }
        #expect(await log.awaitStarted("blocker"))

        var tasks: [Task<String, Error>] = []
        for i in 0..<4 {
            tasks.append(Task { try await pool.run(forCurrent: false, rank: 7, instant("w\(i)", log)) })
            #expect(await waitUntil { pool.waitingCount == i + 1 })
        }
        gate.open()
        _ = try await blocker.value
        for t in tasks { _ = try await t.value }
        #expect(log.order == ["blocker", "w0", "w1", "w2", "w3"])
    }

    @Test func cancelWhileWaiting() async throws {
        let pool = DecodePool(slots: 1, reserved: 0)
        let log = Log()
        let gate = Gate()
        let blocker = Task { try await pool.run(forCurrent: false, rank: 0, blocking("blocker", log, gate)) }
        #expect(await log.awaitStarted("blocker"))

        let waiter = Task { try await pool.run(forCurrent: false, rank: 1, instant("waiter", log)) }
        #expect(await waitUntil { pool.waitingCount == 1 })
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(pool.waitingCount == 0)

        gate.open()
        _ = try await blocker.value
        // The slot is intact and the cancelled job never ran.
        _ = try await pool.run(forCurrent: false, rank: 0, instant("after", log))
        #expect(log.order == ["blocker", "after"])
        #expect(pool.runningCount == 0)
    }

    @Test func cancelBeforeEnqueueNeverRuns() async throws {
        let pool = DecodePool(slots: 3, reserved: 1)
        let log = Log()
        let task = Task {
            // Returns as soon as the task is cancelled; `run` then starts on an already-cancelled task.
            try? await Task.sleep(for: .seconds(60))
            return try await pool.run(forCurrent: true, rank: 0, instant("never", log))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!log.has("never"))
        #expect(pool.runningCount == 0 && pool.waitingCount == 0)
    }

    @Test func startedWorkRunsToCompletionAfterCancel() async throws {
        let pool = DecodePool()
        let log = Log()
        let gate = Gate()
        let task = Task { try await pool.run(forCurrent: true, rank: 0, blocking("job", log, gate)) }
        #expect(await log.awaitStarted("job"))
        task.cancel()
        gate.open()
        #expect(try await task.value == "job")
    }

    @Test func errorsPropagate() async throws {
        let pool = DecodePool()
        await #expect(throws: Boom.self) {
            try await pool.run(forCurrent: true, rank: 0) { () throws -> Int in throw Boom() }
        }
        // The slot was released by the failing job.
        #expect(pool.runningCount == 0)
        #expect(try await pool.run(forCurrent: false, rank: 0) { 42 } == 42)
    }

    @Test func manyJobsAllCompleteWithinTheSlotLimit() async throws {
        let pool = DecodePool(slots: 3, reserved: 1)
        let peak = Peak()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<60 {
                group.addTask {
                    try await pool.run(forCurrent: i % 7 == 0, rank: i % 5) {
                        peak.enter(); defer { peak.leave() }
                        usleep(200)
                        return i
                    }
                }
            }
            var all: [Int] = []
            for try await r in group { all.append(r) }
            return all
        }
        #expect(results.sorted() == Array(0..<60))
        #expect(peak.max <= 3)
        #expect(pool.runningCount == 0 && pool.waitingCount == 0)
    }
}

private final class Peak: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var max = 0
    func enter() { lock.lock(); now += 1; max = Swift.max(max, now); lock.unlock() }
    func leave() { lock.lock(); now -= 1; lock.unlock() }
}
