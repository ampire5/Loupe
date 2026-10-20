import Foundation
import Testing
@testable import LoupeCore

/// A path checked on a share that may not answer (Stash spec §2.2): yes, no, or nil after the timeout.
@Suite struct FileCheckTests {
    @Test func existsAndMissing() async {
        #expect(await FileCheck.exists(URL(fileURLWithPath: "/"), timeout: .seconds(2)) == true)
        #expect(await FileCheck.exists(URL(fileURLWithPath: "/no/such/\(UUID())"), timeout: .seconds(2)) == false)
    }

    @Test(.timeLimit(.minutes(1))) func hungCheckTimesOut() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let start = ContinuousClock.now
        let r = await FileCheck.exists(URL(fileURLWithPath: "/"), timeout: .milliseconds(200)) { _ in gate.wait(); return true }
        #expect(r == nil && ContinuousClock.now - start < .seconds(5))
    }
}
