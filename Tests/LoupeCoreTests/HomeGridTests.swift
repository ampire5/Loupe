import Foundation
import Testing
@testable import LoupeCore

@Suite struct HomeGridTests {
    /// Review Focus 1: a share that does not answer must not hold Home: the check gives up after `timeout` (nil).
    @Test func existenceCheckTimesOut() async {
        let start = ContinuousClock.now
        let result = await HomeGrid.availability(of: ["/slow", "/here", "/gone"], timeout: .seconds(1)) { path in
            if path == "/slow" { Thread.sleep(forTimeInterval: 6) }
            return path == "/here"
        }
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(result["/slow"] == .some(nil))
        #expect(result["/here"] == .some(true))
        #expect(result["/gone"] == .some(false))
    }
}
