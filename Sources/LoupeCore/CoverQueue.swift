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
public actor CoverQueue {
    /// Covers in flight on local volumes. `LoupeBench thumbs --covers` on a local SSD folder of 48 subfolders of 40
    /// progressive 3456 x 2160 JPEGs (i7-10700K, 8 cores, 3 thumbnail decode slots; 4 thumbnails a cover, ~155 ms of
    /// CPU each): 1/2/3/4/6 at once fill the 48 covers in 31/14.2/9.6/9.5/9.0 s for the same ~30 s of CPU, i.e.
    /// 1/2/3/3/3 cores busy. Two halve the wait for a quarter of the machine; a third takes the store's last decode
    /// slot, which the open folders' own thumbnails need, and more only wait for those slots. From the catalog (the
    /// next session) the 48 come in 0.13 s.
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

    /// A card of a client: two windows may show the same folder.
    private struct Key: Hashable {
        let client: Int
        let id: String
    }

    private struct Item {
        let key: Key
        let network: Bool
        let visible: Bool
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
    /// The cards of each client's last `want`, in their order (visible first).
    private var clients: [Int: [Item]] = [:]
    /// Every client's cards in the order they start: the visible ones of all, then the margins; those running or done
    /// are skipped.
    private var wanted: [Item] = []
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
    /// the margin. A card of the client's running or waiting that is not among them is cancelled or dropped; one
    /// already done stays done while it stays wanted. Other clients' cards are left as they are. `isNetwork` must answer without touching the disk (it runs on the queue for every id;
    /// `ThumbnailLocation.isNetwork` of the folder Home shows). `work` makes and delivers the card's cover, at
    /// `.utility` for a visible card and `.background` for the margin's, should end soon once cancelled, and returns
    /// false for "not now": the card is tried again after `retryDelay`, twice that after the next "not now", and so on
    /// up to `maxRetryDelay`, while it stays wanted.
    public func want(_ ids: [String], visible: Int, client: Int = 0, isNetwork: (String) -> Bool,
                     work: @escaping @Sendable (String) async -> Bool) {
        let keys = Set(ids.map { Key(client: client, id: $0) })
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
        let items = ids.enumerated().compactMap { index, id -> Item? in
            guard seen.insert(id).inserted else { return nil }
            return Item(key: Key(client: client, id: id), network: isNetwork(id), visible: index < visible, work: work)
        }
        clients[client] = items.isEmpty ? nil : items
        let all = clients.keys.sorted().flatMap { clients[$0]! }
        wanted = all.filter(\.visible) + all.filter { !$0.visible }
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
        let task = Task(priority: item.visible ? .utility : .background) {
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
            } else {
                let times = notNows[id, default: 0]
                notNows[id] = times + 1
                retryAt[id] = .now + Self.retryDelay(after: times + 1, base: retryDelay, cap: maxRetryDelay)
            }
        }
        pump()
    }
}
