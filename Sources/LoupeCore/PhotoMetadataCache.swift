import Foundation
import Synchronization

/// The metadata of the photos seen with the info panel open, by file and stamp (path + size + modification date): an
/// edited file is another entry, and a photo flipped back to is not read again. The least recently used one goes first.
/// Callers for the same version share one bounded read and can withdraw independently.
public actor PhotoMetadataCache {
    private struct Key: Hashable {
        let path: String
        let size: Int
        let modified: Date?
    }

    // M4 Max (14 cores), 20 stock JPEGs on APFS and SMB, stat + ImageIO. At 1/2/3/4 EXIF slots,
    // two-window median wall time was 0.189/0.097/0.093/0.090 ms locally and 52.504/26.495/26.175/26.193 ms on SMB.
    // Two EXIF slots serve two windows in parallel. One reserved stat slot lets size publish while they're busy.
    package static let inspectorPool = DecodePool(slots: min(3, max(1, Machine.physicalCores / 2)),
                                                reserved: 1, qos: .utility)

    private let capacity: Int
    private let pool: DecodePool
    private let reader: @Sendable (URL) -> PhotoMetadata
    private var entries: [Key: PhotoMetadata] = [:]
    /// Keys from the least recently used to the newest.
    private var order: [Key] = []
    private var inFlight: [Key: Flight] = [:]

    public init(capacity: Int = 64, pool: DecodePool? = nil,
                reader: @escaping @Sendable (URL) -> PhotoMetadata = { PhotoMetadata.read($0) }) {
        self.capacity = max(1, capacity)
        self.pool = pool ?? Self.inspectorPool
        self.reader = reader
    }

    public func metadata(for url: URL, size: Int, modified: Date?) async throws -> PhotoMetadata {
        try Task.checkCancellation()
        let key = Key(path: url.path, size: size, modified: modified)
        if let hit = entries[key] {
            touch(key)
            return hit
        }
        let id = UUID()
        let flight: Flight
        if let existing = inFlight[key], existing.join(id) {
            flight = existing
        } else {
            flight = Flight(id)
            inFlight[key] = flight
            flight.setWorker(Task(priority: .utility) { [pool, reader] in
                let result: Result<PhotoMetadata, Error>
                do {
                    result = .success(try await pool.run(forCurrent: false, rank: 0) {
                        try flight.begin()
                        return reader(url)
                    })
                } catch {
                    result = .failure(error)
                }
                finish(flight, key: key, result: result)
            })
        }
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { flight.attach(id, $0) }
        } onCancel: {
            flight.cancel(id)
        }
        try Task.checkCancellation()
        return value
    }

    /// Queued and running requests, including multiple windows waiting for the same key.
    var waiterCount: Int { inFlight.values.reduce(0) { $0 + $1.waiterCount } }

    private func finish(_ flight: Flight, key: Key, result: Result<PhotoMetadata, Error>) {
        if inFlight[key] === flight {
            inFlight[key] = nil
            // A failed read (a share that hiccuped between the stat and ImageIO) is retried on the next ask.
            if case .success(let value) = result, value.error == nil {
                entries[key] = value
                touch(key)
                while order.count > capacity { entries[order.removeFirst()] = nil }
            }
        }
        flight.finish(result)
    }

    private func touch(_ key: Key) {
        if let at = order.firstIndex(of: key) { order.remove(at: at) }
        order.append(key)
    }

    /// Synchronous cancellation withdraws a queued read without waiting for the cache actor. The actor registers
    /// and attaches each waiter in one turn, and handles completion after the blocking call returns.
    private final class Flight: Sendable {
        private typealias Continuation = CheckedContinuation<PhotoMetadata, Error>
        private struct State {
            var waiters: [UUID: Continuation?] = [:]
            var worker: Task<Void, Never>?
            var started = false
        }
        private let state: Mutex<State>

        init(_ id: UUID) { state = Mutex(State(waiters: [id: nil])) }

        var waiterCount: Int { state.withLock { $0.waiters.count } }

        func join(_ id: UUID) -> Bool {
            state.withLock {
                // An unstarted read with no waiters has been withdrawn. Its replacement gets a fresh flight.
                guard $0.started || !$0.waiters.isEmpty else { return false }
                $0.waiters.updateValue(nil, forKey: id)
                return true
            }
        }

        func setWorker(_ worker: Task<Void, Never>) { state.withLock { $0.worker = worker } }

        func attach(_ id: UUID, _ continuation: CheckedContinuation<PhotoMetadata, Error>) {
            let attached = state.withLock {
                guard $0.waiters.keys.contains(id) else { return false }
                $0.waiters[id] = continuation
                return true
            }
            if !attached { continuation.resume(throwing: CancellationError()) }
        }

        func begin() throws {
            try state.withLock {
                guard !$0.waiters.isEmpty else { throw CancellationError() }
                $0.started = true
            }
        }

        func cancel(_ id: UUID) {
            let (waiter, worker) = state.withLock { state -> (Continuation?, Task<Void, Never>?) in
                let waiter = state.waiters.removeValue(forKey: id) ?? nil
                let worker = state.waiters.isEmpty && !state.started ? state.worker : nil
                return (waiter, worker)
            }
            worker?.cancel()
            waiter?.resume(throwing: CancellationError())
        }

        func finish(_ result: Result<PhotoMetadata, Error>) {
            let waiters = state.withLock {
                let waiters = $0.waiters.values.compactMap { $0 }
                $0.waiters.removeAll()
                $0.worker = nil
                return waiters
            }
            for waiter in waiters { waiter.resume(with: result) }
        }
    }
}
