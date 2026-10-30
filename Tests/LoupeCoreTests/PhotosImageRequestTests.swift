import Foundation
import Testing
@testable import LoupeCore

@Suite struct PhotosImageRequestTests {
    @Test func cancellationBeforeRegistrationDoesNotLeakRequest() async {
        let request = PhotosImageRequest<Int>()
        request.cancel()
        let cancelled = Counter()
        request.onCancel { cancelled.increment() }
        do {
            let _: Int = try await withCheckedThrowingContinuation { request.attach($0) }
            Issue.record("Cancelled request returned a value")
        } catch { #expect(error is CancellationError) }
        #expect(cancelled.value == 1)
    }

    @Test func completionWinsOverDuplicateCallbacksAndLateCancellation() async throws {
        let request = PhotosImageRequest<Int>()
        let cancelled = Counter()
        request.onCancel { cancelled.increment() }
        request.finish(.success(42))
        request.finish(.success(7))
        request.cancel()
        let result = try await withCheckedThrowingContinuation { request.attach($0) }
        #expect(result == 42)
        #expect(cancelled.value == 0)
    }

    @Test func attachedRequestCancelsExactlyOnce() async {
        let request = PhotosImageRequest<Int>()
        let cancelled = Counter()
        request.onCancel { cancelled.increment() }
        do {
            let _: Int = try await withCheckedThrowingContinuation {
                request.attach($0)
                request.cancel()
                request.cancel()
                request.finish(.success(99))
            }
            Issue.record("Cancellation was ignored")
        } catch { #expect(error is CancellationError) }
        #expect(cancelled.value == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
