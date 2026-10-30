import Foundation

/// Bridges a callback request whose cancellation may arrive before its request ID or continuation exists.
final class PhotosImageRequest<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var cancellation: (@Sendable () -> Void)?
    private var cancelled = false

    var isFinished: Bool { lock.withLock { result != nil } }

    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        let ready = lock.withLock { () -> Result<Value, Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    func onCancel(_ action: @escaping @Sendable () -> Void) {
        let call = lock.withLock {
            if cancelled { return true }
            if result == nil { cancellation = action }
            return false
        }
        if call { action() }
    }

    func finish(_ result: Result<Value, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            cancellation = nil
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(with: result)
    }

    func cancel() {
        let state = lock.withLock { () -> (CheckedContinuation<Value, Error>?, (@Sendable () -> Void)?) in
            guard result == nil else { return (nil, nil) }
            cancelled = true
            result = .failure(CancellationError())
            let state = (continuation, cancellation)
            continuation = nil
            cancellation = nil
            return state
        }
        state.1?()
        state.0?.resume(throwing: CancellationError())
    }
}
