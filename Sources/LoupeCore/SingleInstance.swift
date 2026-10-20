import Foundation

/// One running copy of the app, as seen by the single-instance check.
public struct RunningInstance: Equatable, Sendable {
    public var pid: Int32
    /// Bundle identifier, or the executable path when there is none.
    public var key: String
    /// nil sorts last.
    public var launchDate: Date?

    public init(pid: Int32, key: String, launchDate: Date?) {
        self.pid = pid
        self.key = key
        self.launchDate = launchDate
    }
}

public enum SingleInstance {
    /// The instance that must keep running: among `instances` with the same `key` as `me`, the earliest launched.
    /// Returns nil when `me` itself is that instance (or nothing else shares its key) — then `me` stays.
    public static func primary(over me: RunningInstance, among instances: [RunningInstance]) -> RunningInstance? {
        let others = instances.filter { $0.key == me.key && $0.pid != me.pid }
        guard let best = others.min(by: launchedBefore) else { return nil }
        return launchedBefore(best, me) ? best : nil
    }

    private static func launchedBefore(_ a: RunningInstance, _ b: RunningInstance) -> Bool {
        switch (a.launchDate, b.launchDate) {
        case let (x?, y?) where x != y: return x < y
        case (.some, .none): return true
        case (.none, .some): return false
        default: return a.pid < b.pid
        }
    }
}
