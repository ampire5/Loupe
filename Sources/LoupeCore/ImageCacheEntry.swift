import Foundation

/// How long each stage of loading one photo took, in milliseconds (nil: not run yet). `previewMs` covers
/// coarse previews too; `uploadMs` is the latest upload.
public struct LoadTimings: Equatable, Sendable {
    public var readMs, firstLookMs, previewMs, fullMs, uploadMs: Double?

    public init(readMs: Double? = nil, firstLookMs: Double? = nil, previewMs: Double? = nil, fullMs: Double? = nil,
                uploadMs: Double? = nil) {
        self.readMs = readMs
        self.firstLookMs = firstLookMs
        self.previewMs = previewMs
        self.fullMs = fullMs
        self.uploadMs = uploadMs
    }
}

/// A snapshot of one cache entry, for the viewer.
public struct CacheEntryView<Pyramid>: Sendable where Pyramid: Sendable {
    public let url: URL
    public let info: ImageInfo?
    public let pyramid: Pyramid?
    /// `LoadErrorText.message(...)` of the read or decode failure.
    public let failure: String?
    public let decoderName: String?
    public let timings: LoadTimings
    /// Highest goal reached: nil, `.bytes`, `.coarse`, `.preview` or `.full` (all levels resident; an image
    /// whose Lfit is 0 is full as soon as its preview is).
    public let state: CacheGoal?
    /// The only resident level is the one seeded from the thumbnail (`ImageCache.seed`): nothing decoded from the
    /// file has been uploaded yet, so the screen shows the stretched thumbnail (the stats bar's `thumb`).
    public let isSeededOnly: Bool
    /// `pyramid` is the one seeded from the thumbnail (resident level or not): laid out oriented, so it is drawn
    /// with `ImageInfo.drawOrientation(seeded: true)`. Decoded levels go into another pyramid, which replaces it.
    public let pyramidIsSeeded: Bool

    public init(url: URL, info: ImageInfo?, pyramid: Pyramid?, failure: String?, decoderName: String?,
                timings: LoadTimings, state: CacheGoal?, isSeededOnly: Bool = false, pyramidIsSeeded: Bool = false) {
        self.url = url
        self.info = info
        self.pyramid = pyramid
        self.failure = failure
        self.decoderName = decoderName
        self.timings = timings
        self.state = state
        self.isSeededOnly = isSeededOnly
        self.pyramidIsSeeded = pyramidIsSeeded
    }
}

/// The system's memory pressure as the cache sees it (M2 spec §11.3): `warning` halves the effective
/// `cache-memory`, `critical` quarters it.
public enum MemoryPressure: Sendable {
    case normal, warning, critical

    /// What `cache-memory` is divided by at this level.
    var divisor: Int {
        switch self {
        case .normal: 1
        case .warning: 2
        case .critical: 4
        }
    }
}

/// Entries by state (`previewCount` counts coarse and preview pyramids, `fullCount` full ones) and memory held:
/// compressed bytes plus the resident levels' slot arrays of every entry (the pinned one included), plus the
/// levels uploads in flight are building. `limitBytes` is `cache-memory`, `effectiveLimitBytes` what the cache
/// holds itself to now (smaller under memory pressure). `evictedInactive`: entries and bytes eviction took from
/// inactive windows since launch (spec windows-and-tabs §3.8); growing, the limit is too small for the windows open.
/// On a discrete card (`graphicsLimitBytes` set, `CacheLimits.graphicsMemory`) `usedBytes`, `limitBytes` and
/// `effectiveLimitBytes` are the system tier's (the compressed bytes and ready decodes against `cache-memory`), and
/// `graphicsUsedBytes` the pyramids and uploads against the graphics tier; with one budget `graphicsUsedBytes` is
/// the pyramids' and uploads' share of `usedBytes`. `readyCount`: entries holding a ready decode (only ever on a
/// discrete card).
public struct CacheStats: Equatable, Sendable {
    public let bytesCount, previewCount, fullCount: Int
    public let readyCount: Int
    public let usedBytes, limitBytes, effectiveLimitBytes: Int
    public let evictedInactive: (count: Int, bytes: Int)
    public let graphicsUsedBytes: Int
    public let graphicsLimitBytes: Int?

    public init(bytesCount: Int, previewCount: Int, fullCount: Int, usedBytes: Int, limitBytes: Int,
                effectiveLimitBytes: Int, evictedInactive: (count: Int, bytes: Int) = (0, 0),
                graphicsUsedBytes: Int = 0, graphicsLimitBytes: Int? = nil, readyCount: Int = 0) {
        self.bytesCount = bytesCount
        self.readyCount = readyCount
        self.previewCount = previewCount
        self.fullCount = fullCount
        self.usedBytes = usedBytes
        self.limitBytes = limitBytes
        self.effectiveLimitBytes = effectiveLimitBytes
        self.evictedInactive = evictedInactive
        self.graphicsUsedBytes = graphicsUsedBytes
        self.graphicsLimitBytes = graphicsLimitBytes
    }

    public static func == (a: CacheStats, b: CacheStats) -> Bool {
        (a.bytesCount, a.previewCount, a.fullCount, a.readyCount)
            == (b.bytesCount, b.previewCount, b.fullCount, b.readyCount)
            && (a.usedBytes, a.limitBytes, a.effectiveLimitBytes) == (b.usedBytes, b.limitBytes, b.effectiveLimitBytes)
            && a.evictedInactive == b.evictedInactive
            && a.graphicsUsedBytes == b.graphicsUsedBytes && a.graphicsLimitBytes == b.graphicsLimitBytes
    }
}

/// What an activation found (`ImageCache.setActivity`), for the debug log (spec windows-and-tabs §3.8): the state of
/// the session's current photo (nil: nothing of it held), the reads and decodes the activation started (jobs
/// launched; 0 for a window whose photos were not evicted) and the cache's counts after it.
public struct CacheActivation: Sendable {
    public let current: CacheGoal?
    public let jobs: Int
    public let stats: CacheStats

    public init(current: CacheGoal?, jobs: Int, stats: CacheStats) {
        self.current = current
        self.jobs = jobs
        self.stats = stats
    }
}

/// One photo's cache state. Owned by `ImageCache` and only touched on it. A reset replaces the object, so a
/// job can tell its entry is gone by identity.
final class CacheEntry<Pyramid: AnyObject & Sendable> {
    var data: Data?
    var stamp: FileStamp?
    /// From the probe, or from the thumbnail's catalog row when the entry was seeded (then `decoder` is still nil,
    /// and the first probe checks it).
    var info: ImageInfo?
    var decoder: (any ImageDecoder)?
    var pyramid: Pyramid?
    /// On a discrete card, the full decode (level 0) kept in system memory after its upload or made for it in the
    /// background (`CacheGoal.ready`): stepping onto the photo uploads it instead of decoding the file. Counted in
    /// `ImageCache.usedSystemBytes`; never drawn from.
    var ready: LevelImage?
    /// Full jobs waiting for the entry's ready decode in flight (`awaitReadyDecode`): it is kept for them, planned
    /// or not, since they upload it next.
    var readyWaiters = 0
    /// A ready decode of the entry failed (dropped quietly, the photo not marked failed): none is started again until a
    /// full decode of the file succeeds or the entry is reset.
    var readyFailed = false
    var failure: String?
    var timings = LoadTimings()
    /// The read in flight; decode jobs await it, so the file is read once.
    var read: Task<Data, Error>?
    var readID = 0
    /// The queue position of the read in flight, shared with the reader: moving it moves the read whether it is
    /// queued yet or still on its way to the queue.
    var readPriority: ReadPriority?
    /// Decode jobs in flight, at most one per goal (`coarse`, `preview`, `full`, `ready`).
    var jobs: [CacheGoal: CacheJob] = [:]
    /// Bytes of the levels uploads into this entry are building right now: fresh textures for every level of
    /// `level...last`, all counted in `usedBytes` while the upload runs. Levels already resident are counted
    /// twice meanwhile, and that is real: the old textures go only once the new ones are swapped in. The entry
    /// is not evicted while this is non-zero.
    var uploadReserve = 0
    /// The resident levels came from the thumbnail (`ImageCache.seed`) and nothing decoded from the file has been
    /// uploaded since. Such levels satisfy `.coarse` at most, so the file is still read, probed and decoded.
    /// Cleared when a decoded level replaces them and when the pyramid goes.
    var seeded = false
    /// While `seeded`: the pyramid decoded levels go into, made in their own colour space, which replaces the
    /// seeded one as soon as an upload into it lands. Decoded levels and the thumbnail never share a pyramid, so
    /// neither can overwrite the other, and the thumbnail's colour space never outlives it.
    var pending: Pyramid?
}

struct CacheJob {
    let id: Int
    let task: Task<Void, Never>
    let phase: JobPhase
}

/// Whether a job is still only waiting (for bytes or a decode slot), so cancelling or restarting it loses
/// nothing, and the priority class it is (or will be) queued with. Set by the job on the actor and by its
/// decode work on the pool thread.
final class JobPhase: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = true
    private var current: Bool
    private var abandoned = false

    init(forCurrent: Bool) { current = forCurrent }

    var isWaiting: Bool { lock.withLock { waiting } }
    var forCurrent: Bool { lock.withLock { current } }
    func markWaiting(forCurrent: Bool) { lock.withLock { waiting = true; current = forCurrent } }
    func markBusy() { lock.withLock { waiting = false } }

    /// `markBusy` for work that may be given up (`abandonIfWaiting`): false, and still waiting, when it was. Called by
    /// the work as it starts on its pool thread, so a slot granted just before the job was given up decodes nothing:
    /// the task's own cancellation is checked only before the work is handed to the thread.
    func beginIfLive() -> Bool {
        lock.withLock {
            guard !abandoned else { return false }
            waiting = false
            return true
        }
    }

    /// Gives the job up if it is still waiting: its work then never starts (`beginIfLive`). False once it began.
    func abandonIfWaiting() -> Bool {
        lock.withLock {
            guard waiting else { return false }
            abandoned = true
            return true
        }
    }
}

extension ContinuousClock.Instant {
    /// Milliseconds from this instant to now.
    var millisecondsElapsed: Double {
        let c = (ContinuousClock.now - self).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
