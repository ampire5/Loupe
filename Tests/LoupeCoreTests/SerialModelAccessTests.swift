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
    @Test func cancelledAnalysisDoesNotLoadOrUseAModel() {
        let loads = Mutex(0)
        let access = SerialModelAccess<NeutralModel> { _ in
            loads.withLock { $0 += 1 }
            return NeutralModel()
        }
        let result = access.withModel("neutral", shouldContinue: { false }) { _ in true }
        #expect(result == nil)
        #expect(loads.withLock { $0 } == 0)
    }

    @Test func cancellationDuringModelLoadingSkipsInference() {
        let cancelled = Mutex(false)
        let access = SerialModelAccess<NeutralModel> { _ in
            cancelled.withLock { $0 = true }
            return NeutralModel()
        }
        let result = access.withModel("neutral", shouldContinue: { !cancelled.withLock { $0 } }) { _ in true }
        #expect(result == nil)
    }

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
