import Foundation

/// Event-driven foreground priority. Only a pending fit waits; there are no timers or idle polling.
public actor FramingWorkGate {
    private var busy = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    public init() {}
    public func setBusy(_ value: Bool) {
        busy = value
        if !busy { let current = waiters; waiters = [:]; for waiter in current.values { waiter.resume() } }
    }
    public func checkpoint() async throws {
        try Task.checkCancellation()
        guard busy else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
