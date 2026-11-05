import Foundation
import Synchronization
import Testing
@testable import LoupeCore

/// Deliberately not Sendable: callers must use a model through its cache owner.
private final class NeutralModel {
    private let active = Mutex(0)
    func predictionOverlaps() -> Bool {
        let overlaps = active.withLock { count in count += 1; return count > 1 }
        Thread.sleep(forTimeInterval: 0.02)
        active.withLock { $0 -= 1 }
        return overlaps
    }
}

@Suite struct SerialModelAccessTests {
    @Test func preflightAndWindowInferenceNeverUseTheSameModelTogether() async {
        let loads = Mutex(0)
        let access = SerialModelAccess<NeutralModel> { _ in
            loads.withLock { $0 += 1 }
            return NeutralModel()
        }
        let overlaps = Mutex<[Bool]>([])
        await Task.detached(priority: .utility) {
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                let result = access.withModel("neutral") { $0.predictionOverlaps() }
                if let result { overlaps.withLock { $0.append(result) } }
            }
        }.value
        #expect(overlaps.withLock { $0 } == [false, false])
        #expect(loads.withLock { $0 } == 1)
    }
}
