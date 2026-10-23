import Foundation

/// A stage boundary of one cache job, for benchmarks (`LoupeBench replay` traces where a photo's time goes).
/// Off by default: with no handler set (`ImageCache.setTrace(nil)`) nothing is built or called.
public struct CacheTraceEvent: Sendable {
    public enum Kind: String, Sendable {
        /// A decode job was started for `goal`, or cancelled while still waiting (left the plan / restarted).
        case jobLaunched, jobCancelled
        /// The entry's read was submitted to the reader at `priority` (0: the current photo, else its plan rank).
        case readRequested
        /// A queued read was moved to `priority` (the plan changed).
        case readReprioritized
        /// The entry's read was cancelled because nothing waits for it any more.
        case readCancelled
        /// The read's bytes reached the cache actor.
        case readDelivered
        /// Each pair: asked for a decode slot (`…Wait`; for progressive full decodes, before the gate),
        /// got it and started (`…Start`, on the pool thread), finished (`…Done`, back on the actor).
        case probeWait, probeStart, probeDone
        case lookWait, lookStart, lookDone
        case decodeWait, decodeStart, decodeDone
        /// A full job found the entry's ready decode (`CacheGoal.ready`) in progress and waits for it, to upload it
        /// rather than decode the file a second time.
        case readyAwait
        /// A ready decode failed and was dropped quietly; the photo is not marked failed (its full job decodes itself).
        case readyFailed
        /// The upload of a decoded level into the pyramid began (room made) / finished.
        case uploadStart, uploadDone
        /// A decoded result was dropped (its goal left the plan and it did not fit, or something as sharp was resident).
        case uploadSkipped
        /// A level seeded from the thumbnail (`ImageCache.seed`, its `level`) became resident.
        case seeded
    }

    public let url: URL
    public let kind: Kind
    public let goal: CacheGoal?
    /// The decoded level for `decodeDone` / upload events.
    public let level: Int?
    /// The read priority for `readRequested` / `readReprioritized`.
    public let priority: Int?
    public let time: ContinuousClock.Instant

    public init(url: URL, kind: Kind, goal: CacheGoal?, level: Int? = nil, priority: Int? = nil,
                time: ContinuousClock.Instant = .now) {
        self.url = url
        self.kind = kind
        self.goal = goal
        self.level = level
        self.priority = priority
        self.time = time
    }
}

public typealias CacheTrace = @Sendable (CacheTraceEvent) -> Void

/// One entry as the cache holds it right now, for benchmarks.
public struct CacheEntryProbe: Sendable {
    public let state: CacheGoal?
    public let finest: Int?
    public let hasBytes: Bool
    public let reading: Bool
    /// Jobs in flight by goal: true while still waiting (for bytes or a slot), false once busy.
    public let jobs: [CacheGoal: Bool]
    /// The latest plan's goals for the entry → position in the plan.
    public let planned: [CacheGoal: Int]
}

extension ImageCache {
    /// Sets (or clears) the benchmark trace handler; called on the actor for every job stage boundary.
    public func setTrace(_ handler: CacheTrace?) { trace = handler }

    /// What the cache holds for each of `urls` (nil: no entry), for benchmarks.
    public func inspect(_ urls: [URL]) -> [CacheEntryProbe?] {
        urls.map { url in
            guard let e = entries[url] else { return nil }
            return CacheEntryProbe(state: state(of: url, e), finest: e.pyramid.flatMap { loader.finestResidentLevel(of: $0) },
                                   hasBytes: e.data != nil, reading: e.read != nil,
                                   jobs: e.jobs.mapValues { $0.phase.isWaiting }, planned: planned[url] ?? [:])
        }
    }

    func emit(_ url: URL, _ kind: CacheTraceEvent.Kind, _ goal: CacheGoal? = nil, level: Int? = nil, priority: Int? = nil) {
        trace?(CacheTraceEvent(url: url, kind: kind, goal: goal, level: level, priority: priority))
    }
}

extension DecodePool {
    /// Jobs waiting for a slot and slots in use, for benchmarks.
    public var load: (waiting: Int, running: Int) {
        (waitingCount, runningCount)
    }
}
