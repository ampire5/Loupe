import Foundation

/// One stderr line when a store's writes to `Loupe.db` start failing, and no more until a later write succeeds
/// (the changes stay pending and are retried, so a line per batch would only repeat itself). One per store.
final class WriteFailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reported = false
    private let sink: @Sendable (String) -> Void

    init(sink: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }) {
        self.sink = sink
    }

    func failed(_ error: Error) {
        let first = lock.withLock { () -> Bool in
            defer { reported = true }
            return !reported
        }
        if first { sink("loupe: could not save folder state to Loupe.db: \(error)") }
    }

    func succeeded() {
        lock.withLock { reported = false }
    }
}
