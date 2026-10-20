import Foundation

/// The check of which recent paths can be reached (Home spec §3.3); the grid itself is HomeScreenKit's.
public enum HomeGrid {
    /// Whether each of `paths` exists, by `check` run off the caller, all at once: true or false, or nil when the
    /// answer took longer than `timeout` (a share that does not answer; Home spec §3.3). Never waits beyond it.
    public static func availability(of paths: [String], timeout: Duration,
                                    check: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        async -> [String: Bool?] {
        await withTaskGroup(of: (String, Bool?).self) { group in
            for path in paths {
                group.addTask { (path, await value(within: timeout) { check(path) }) }
            }
            var result: [String: Bool?] = [:]
            for await (path, answer) in group { result[path] = .some(answer) }
            return result
        }
    }

    /// `work()` on a thread of its own, or nil once `timeout` passes first.
    public static func value<T: Sendable>(within timeout: Duration, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { c in
            let once = Once(c)
            // A thread of its own: GCD's pool may be busy (or stuck on that share) and would hold the answer back.
            Thread.detachNewThread { once.resume(work()) }
            // A thread too: a busy pool (GCD's or the concurrency one) must not hold the deadline back.
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: timeout.seconds)
                once.resume(nil)
            }
        }
    }
}

/// A continuation resumed once, by whichever comes first: the answer or the deadline.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    init(_ c: CheckedContinuation<T?, Never>) { continuation = c }
    func resume(_ value: T?) {
        lock.withLock { () -> CheckedContinuation<T?, Never>? in
            defer { continuation = nil }
            return continuation
        }?.resume(returning: value)
    }
}
