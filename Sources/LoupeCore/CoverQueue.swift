import Foundation

/// Home's folder and archive covers in the background (folder covers spec, "Order and limits"): each card's cover is
/// one task, a few at a time, the visible cards before the margin, and a card that left the live area is cancelled.
///
/// A cover begins with a listing of the folder (or the zip's directory), which on a share can take seconds and which
/// nothing interrupts once it is in the kernel, so the limits are on covers in flight: `listingLimit` on local volumes
/// and `networkListingLimit` on shares, counted apart (a slow share never holds up the local cards, and a share gets
/// one listing at a time from the covers, beside what the user opened). A cancelled task keeps its place in the count
/// until it has really ended, so a burst of scrolling cannot pile up tasks. While the viewer is busy (`pause`), no
/// new cover starts; those running wait before their next thumbnail (`ThumbnailStore.folderCover`). A cover that
/// cannot be made now (a share hung) says so and is tried again after `retryDelay`, rather than being done empty.
///
/// Each window's Home is a `client` of the one queue (the limits are the app's, not a window's): a client's `want`
/// replaces its own cards only, and the cards in view in every window go before any margin. Only the ids of each
/// client's last `want` are kept: what waits is bounded by the cards on screen and in the margins.
///
/// After every client's margin comes the work ahead (thumbs-ahead spec, stage 4): the direct subfolders of the cards
/// in view, whose covers and summaries go to the catalog only, so that entering a folder finds its cards made. They
/// share the same limits (one listing at a time on a share, whatever the tier) and leave with the card they belong
/// to: the caller sends a card's subfolders only while it is in view.
public actor CoverQueue {
    /// Covers in flight on local volumes. `LoupeBench thumbs --covers` on a local SSD folder of 48 subfolders of 40
    /// progressive 3456 x 2160 JPEGs (i7-10700K, 8 cores, 3 thumbnail decode slots; 4 thumbnails a cover, ~155 ms of
    /// CPU each): 1/2/3/4/6 at once fill the 48 covers in 31/14.2/9.6/9.5/9.0 s for the same ~30 s of CPU, i.e.
    /// 1/2/3/3/3 cores busy. Two halve the wait for a quarter of the machine; a third takes the store's last decode
    /// slot, which the open folders' own thumbnails need, and more only wait for those slots. From the catalog (the
    /// next session) the 48 come in 0.13 s.
    ///
    /// The work ahead (the visible cards' subfolders) adds no listing slot: `LoupeBench thumbs --ahead` on a synthetic
    /// local folder of 16 subfolders, each of 10 JPEG 2400 x 1600 and 6 subfolders of 12 (SSD, the same machine; 12
    /// cards in view, so 72 subfolders ahead): the 16 cards are done in 1.3-1.6 s either way, the 72 subfolders have their
    /// covers 5.4-6.5 s later (two runs), and the peak cores busy over 250 ms windows stay 2.0-2.3 with and without
    /// the work ahead (the CPU over the pass: 3 s for the cards, 14.5 s with the subfolders).
    public static let listingLimit = 2
    /// Covers in flight on shares: one, so a share already slow for the folder the user opened gets one more listing
    /// at a time, never a burst (on the share of docs/bench/2026-10-15-m2.5-thumb-speed.md a second read adds only a
    /// quarter to the first).
    public static let networkListingLimit = 1
    /// How long the viewer must have been idle before covers start again: its idle signal flickers between jobs while
    /// the user steps through photos (the thumbnail generator's `idleDelay`).
    public static let defaultResumeDelay: Duration = .milliseconds(100)
    /// How long a card whose work said "not now" (a share's lane full of hung calls, a listing with no name in time)
    /// waits before it is tried again, doubled at each further "not now" up to `defaultMaxRetryDelay`: a share that
    /// hangs or crawls is asked about less and less, and only by cards still wanted.
    public static let defaultRetryDelay: Duration = .seconds(1)
    public static let defaultMaxRetryDelay: Duration = .seconds(60)

    /// Where a card stands in the order: in view, in the margin, or work ahead (a visible card's subfolder).
    enum Tier: Sendable {
        case inView, margin, ahead
    }

    /// A card of a client: two windows may show the same folder.
    private struct Key: Hashable {
        let client: Int
        let id: String
    }

    private struct Item {
        let key: Key
        let network: Bool
        let tier: Tier
        let work: @Sendable (String) async -> Bool
    }

    private struct Running {
        let token: UInt64
        let network: Bool
        let task: Task<Void, Never>
    }

    private let listingLimit: Int
    private let networkListingLimit: Int
    private let resumeDelay: Duration
    private let retryDelay: Duration
    private let maxRetryDelay: Duration
    /// The cards of each client's last `want`, in their order (visible first, then the margin, then the work ahead).
    private var clients: [Int: [Item]] = [:]
    /// Every client's cards in the order they start: the visible ones of all, then the margins, then the work ahead;
    /// those running or done are skipped.
    private var wanted: [Item] = []
    /// Told the client whose counts (`progress`) may have changed; the caller coalesces.
    private var onProgress: (@Sendable (Int) -> Void)?
    private var running: [Key: Running] = [:]
    /// Cancelled tasks still ending, by token: they hold their place in the limits.
    private var ending: [UInt64: Bool] = [:]
    /// Covers made for cards still wanted: not made again on the next `want`.
    private var done: Set<Key> = []
    /// Cards whose work said "not now": not started again before then.
    private var retryAt: [Key: ContinuousClock.Instant] = [:]
    /// "Not now"s in a row per card still wanted, for the growing delay.
    private var notNows: [Key: Int] = [:]
    private var retryWake: Task<Void, Never>?
    private var paused = false
    /// Bumped by every `pause`: a resume scheduled before is stale.
    private(set) var pauseGeneration = 0
    private var resumeWake: Task<Void, Never>?
    private var nextToken: UInt64 = 0

    public init(listingLimit: Int = CoverQueue.listingLimit, networkListingLimit: Int = CoverQueue.networkListingLimit,
                resumeDelay: Duration = CoverQueue.defaultResumeDelay, retryDelay: Duration = CoverQueue.defaultRetryDelay,
                maxRetryDelay: Duration = CoverQueue.defaultMaxRetryDelay) {
        self.listingLimit = max(1, listingLimit)
        self.networkListingLimit = max(1, networkListingLimit)
        self.resumeDelay = resumeDelay
        self.retryDelay = retryDelay
        self.maxRetryDelay = max(retryDelay, maxRetryDelay)
    }

    /// The cards of `client` that want a cover now, in the order they start: the `visible` ones on screen first, then
    /// the margin, then `ahead` (the visible cards' subfolders, after every client's margin; an id already among
    /// `ids` counts there). A card of the client's running or waiting that is not among them is cancelled or dropped;
    /// one already done stays done while it stays wanted. Other clients' cards are left as they are. `isNetwork` must
    /// answer without touching the disk (it runs on the queue for every id; `ThumbnailLocation.isNetwork` of the
    /// folder Home shows). `work` makes and delivers the card's cover, at `.utility` for a visible card and
    /// `.background` for the margin's and the work ahead, should end soon once cancelled, and returns false for "not
    /// now": the card is tried again after `retryDelay`, twice that after the next "not now", and so on up to
    /// `maxRetryDelay`, while it stays wanted.
    public func want(_ ids: [String], visible: Int, ahead: [String] = [], client: Int = 0,
                     isNetwork: (String) -> Bool, work: @escaping @Sendable (String) async -> Bool) {
        let keys = Set((ids + ahead).map { Key(client: client, id: $0) })
        func gone(_ key: Key) -> Bool { key.client == client && !keys.contains(key) }
        for (key, job) in running where gone(key) {
            job.task.cancel()
            ending[job.token] = job.network
            running[key] = nil
        }
        done = done.filter { !gone($0) }
        retryAt = retryAt.filter { !gone($0.key) }
        notNows = notNows.filter { !gone($0.key) }
        var seen: Set<String> = []
        // A repeated id counts once, at its first place.
        let tiered = ids.enumerated().map { ($1, $0 < visible ? Tier.inView : .margin) } + ahead.map { ($0, Tier.ahead) }
        let items = tiered.compactMap { id, tier -> Item? in
            guard seen.insert(id).inserted else { return nil }
            return Item(key: Key(client: client, id: id), network: isNetwork(id), tier: tier, work: work)
        }
        clients[client] = items.isEmpty ? nil : items
        let all = clients.keys.sorted().flatMap { clients[$0]! }
        wanted = all.filter { $0.tier == .inView } + all.filter { $0.tier == .margin } + all.filter { $0.tier == .ahead }
        onProgress?(client)
        pump()
    }

    /// How far `client`'s cards of its last `want` are, per tier: done (made, while wanted) of wanted.
    public func progress(client: Int) -> CoverProgress {
        var progress = CoverProgress()
        for item in clients[client] ?? [] {
            let made = done.contains(item.key) ? 1 : 0
            switch item.tier {
            case .inView: progress.inView.total += 1; progress.inView.done += made
            case .margin: progress.margin.total += 1; progress.margin.done += made
            case .ahead: progress.ahead.total += 1; progress.ahead.done += made
            }
        }
        return progress
    }

    /// `handler` hears the client whose `progress` may have changed (a `want`, a card done or forgotten), on the
    /// queue, as it happens: the caller coalesces.
    public func setOnProgress(_ handler: @escaping @Sendable (Int) -> Void) {
        onProgress = handler
    }

    /// Cards of `client` whose cover is no longer shown (the browser dropped the picture and has none kept): made again
    /// while they are wanted, not counted as done.
    public func forget(_ ids: [String], client: Int = 0) {
        for id in ids {
            let key = Key(client: client, id: id)
            done.remove(key)
            retryAt[key] = nil
            notNows[key] = nil
        }
        if !ids.isEmpty { onProgress?(client) }
        pump()
    }

    /// True while the viewer is busy: covers wait. Back to false, they start again after `resumeDelay`, unless the
    /// viewer is busy again by then.
    public func pause(_ on: Bool) {
        pauseGeneration += 1
        resumeWake?.cancel()
        resumeWake = nil
        if on {
            paused = true
            return
        }
        guard paused else { return }
        guard resumeDelay > .zero else {
            paused = false
            return pump()
        }
        let delay = resumeDelay, generation = pauseGeneration
        resumeWake = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            await self?.resume(generation)
        }
    }

    /// Whether work ahead waits now (the subtree walk's stamps and listings too, thumbs-ahead plan R3): while the
    /// viewer is busy (`pause`) and until its resume delay has passed.
    public var aheadPaused: Bool { paused }

    /// The end of a resume delay; stale (and ignored) when `pause` was called again since it was scheduled, even if
    /// its wake had already left the timer.
    func resume(_ generation: Int) {
        guard generation == pauseGeneration else { return }
        resumeWake = nil
        paused = false
        pump()
    }

    /// Covers wanted and waiting to start (or to be tried again), for tests.
    var pendingCount: Int { wanted.filter { running[$0.key] == nil && !done.contains($0.key) }.count }
    /// Covers in flight, cancelled ones still ending included, for tests.
    var runningCount: Int { running.count + ending.count }

    private func inFlight(network: Bool) -> Int {
        running.values.filter { $0.network == network }.count + ending.values.filter { $0 == network }.count
    }

    private func pump() {
        guard !paused else { return }
        let now = ContinuousClock.now
        var local = inFlight(network: false), network = inFlight(network: true)
        var nextRetry: ContinuousClock.Instant?
        for item in wanted where running[item.key] == nil && !done.contains(item.key) {
            if let at = retryAt[item.key], at > now {
                nextRetry = min(nextRetry ?? at, at)
                continue
            }
            if item.network ? network < networkListingLimit : local < listingLimit {
                retryAt[item.key] = nil
                start(item)
                if item.network { network += 1 } else { local += 1 }
            }
        }
        retryWake?.cancel()
        retryWake = nil
        if let nextRetry {
            retryWake = Task { [weak self] in
                guard (try? await Task.sleep(until: nextRetry)) != nil else { return }
                await self?.retryWoke()
            }
        }
    }

    /// The wake may have left its timer just before a newer `pump` replaced it: `pump` cancels and replaces the
    /// handle it finds, so this one keeps whatever handle is there.
    private func retryWoke() {
        pump()
    }

    private func start(_ item: Item) {
        nextToken += 1
        let token = nextToken, key = item.key, work = item.work
        let task = Task(priority: item.tier == .inView ? .utility : .background) {
            let made = await work(key.id)
            self.finished(key, token: token, made: made)
        }
        running[key] = Running(token: token, network: item.network, task: task)
    }

    /// How long a card waits after its `notNows`-th "not now" in a row (the first: 1): `base`, doubled at each further
    /// one, never past `cap`.
    nonisolated static func retryDelay(after notNows: Int, base: Duration, cap: Duration) -> Duration {
        min(base * (1 << min(max(notNows - 1, 0), 16)), cap)
    }

    private func finished(_ id: Key, token: UInt64, made: Bool) {
        if ending.removeValue(forKey: token) == nil, running[id]?.token == token {
            running[id] = nil
            if made {
                done.insert(id)
                notNows[id] = nil
                onProgress?(id.client)
            } else {
                let times = notNows[id, default: 0]
                notNows[id] = times + 1
                retryAt[id] = .now + Self.retryDelay(after: times + 1, base: retryDelay, cap: maxRetryDelay)
            }
        }
        pump()
    }
}

/// How far a client's covers are (`CoverQueue.progress`): the cards in view, the margin, and the work ahead (the
/// visible cards' subfolders), each done of wanted.
public struct CoverProgress: Equatable, Sendable {
    public var inView: WorkCount
    public var margin: WorkCount
    public var ahead: WorkCount

    public init(inView: WorkCount = WorkCount(), margin: WorkCount = WorkCount(), ahead: WorkCount = WorkCount()) {
        self.inView = inView
        self.margin = margin
        self.ahead = ahead
    }
}
