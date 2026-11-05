import Foundation
import Testing
import Synchronization
@testable import LoupeCore

@Suite struct HomeGridTests {
    @Test func existenceCheckReportsPresentAndMissingPaths() async {
        let checks = BlockingChecks(limit: 2)
        let result = await HomeGrid.availability(of: ["/here", "/gone"], timeout: .seconds(30), checks: checks) { path in
            path == "/here"
        }
        #expect(result["/here"] == .some(true))
        #expect(result["/gone"] == .some(false))
    }

    /// A share that does not answer must not hold Home. Deadline correctness is independent of whether
    /// unrelated quick callbacks receive utility execution time during a heavily parallel test run.
    @Test func existenceCheckTimesOut() async {
        let checks = BlockingChecks(limit: 1)
        let gate = BlockingGate()
        defer { gate.open() }
        let start = ContinuousClock.now
        let result = await HomeGrid.availability(of: ["/slow"], timeout: .seconds(1), checks: checks) { _ in
            gate.wait()
            return true
        }
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(result["/slow"] == .some(nil))
    }
}

@Suite struct HomeGridAdmissionTests {
    @Test func timeoutBatchesBoundOutstandingChecks() async {
        let checks = BlockingChecks(limit: 2)
        let gate = BlockingGate()
        let started = Mutex(0)
        let holders = (0..<2).map { _ in
            Task {
                await checks.value(within: .seconds(30)) {
                    started.withLock { $0 += 1 }
                    gate.wait()
                    return true
                }
            }
        }
        defer { holders.forEach { $0.cancel() }; gate.open() }
        #expect(await eventually { started.withLock { $0 } == 2 })
        let prefix = UUID().uuidString
        for round in 0..<3 {
            _ = await HomeGrid.availability(of: (0..<24).map { "\(prefix)-\(round)-\($0)" }, timeout: .milliseconds(20), checks: checks) { _ in
                started.withLock { $0 += 1 }
                return true
            }
        }
        #expect(started.withLock { $0 } == 2)
    }

    @Test func repeatedPathDoesNotStartAnotherHungCheck() async {
        let checks = BlockingChecks(limit: 2)
        let gate = BlockingGate()
        let started = Mutex(0)
        let path = UUID().uuidString
        let running = Task {
            await checks.value(key: path, within: .seconds(30)) {
                started.withLock { $0 += 1 }
                gate.wait()
                return true
            }
        }
        defer { running.cancel(); gate.open() }
        #expect(await eventually { started.withLock { $0 } == 1 })
        running.cancel()
        _ = await running.value
        for _ in 0..<3 {
            _ = await HomeGrid.availability(of: [path], timeout: .milliseconds(20), checks: checks) { _ in
                started.withLock { $0 += 1 }
                return true
            }
        }
        #expect(started.withLock { $0 } == 1)
    }

    @Test func alreadyCancelledCheckDoesNotStartBlockingWork() async {
        let started = Mutex(0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await HomeGrid.value(within: .seconds(10)) { started.withLock { $0 += 1 }; return true }
        }
        #expect(await task.value == nil)
        #expect(started.withLock { $0 } == 0)
    }
}

extension HomeGridAdmissionTests {
    @Test func cancellationRetainsTheRunningChecksSlotUntilItReturns() async {
        let checks = BlockingChecks(limit: 1)
        let gate = BlockingGate()
        defer { gate.open() }
        let started = Mutex(false)
        let waitingStarted = Mutex(false)
        let running = Task {
            await checks.value(within: .seconds(10)) {
                started.withLock { $0 = true }
                gate.wait()
                return true
            }
        }
        #expect(await eventually { started.withLock { $0 } })
        running.cancel()
        let start = ContinuousClock.now
        #expect(await running.value == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
        let waiting = await checks.value(within: .milliseconds(20)) {
            waitingStarted.withLock { $0 = true }
            return true
        }
        #expect(waiting == nil)
        gate.open()
        #expect(await eventually { await checks.value(within: .milliseconds(50)) { true } == true })
        #expect(!waitingStarted.withLock { $0 })
    }
}

extension HomeGridAdmissionTests {
    @Test func firstRecentGetsAdmissionBeforeOlderHungPaths() async {
        let checks = BlockingChecks(limit: 2)
        let gate = BlockingGate()
        defer { gate.open() }
        let paths = ["/local/latest"] + (0..<100).map { "/hung/\($0)" } + ["/local/latest"]
        let admitted = Mutex<Set<String>>([])
        let running = Task {
            await HomeGrid.availability(of: paths, timeout: .seconds(30), checks: checks) { path in
                admitted.withLock { _ = $0.insert(path) }
                if path == "/local/latest" { return true }
                gate.wait()
                return false
            }
        }
        defer { running.cancel() }
        #expect(await eventually { admitted.withLock { $0.count >= 2 } })
        #expect(admitted.withLock { $0.contains("/local/latest") })
        running.cancel()
        _ = await running.value
    }
}
