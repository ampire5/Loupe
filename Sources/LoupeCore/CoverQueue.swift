import Foundation

/// Home's folder and archive covers in the background (folder covers spec, "Order and limits"): each card's cover is
/// one task, a few at a time, the visible cards before the margin, and a card that left the live area is cancelled.
///
/// A cover begins with a listing of the folder (or the zip's directory), which on a share can take seconds and which
/// nothing interrupts once it is in the kernel, so the limits are on covers in flight: `listingLimit` on local volumes
/// and `networkListingLimit` on shares, counted apart (a slow share never holds up the local cards, and a share gets
/// one listing at a time from the covers, beside what the user opened). A cancelled task keeps its place in the count
/// until it has really ended, so a burst of scrolling cannot pile up tasks. While the viewer is busy (`pause`), no
/// new cover starts; those running go on (their reads are background reads, behind the viewer's).
///
/// Only the ids of the last `want` are kept: what waits is bounded by the cards on screen and in the margin.
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

    private struct Item {
        let id: String
        let network: Bool
        let visible: Bool
        let work: @Sendable (String) async -> Void
    }

    private struct Running {
        let token: UInt64
        let network: Bool
        let task: Task<Void, Never>
    }

    private let listingLimit: Int
    private let networkListingLimit: Int
    private let resumeDelay: Duration
    /// Wanted and not started, visible first.
    private var pending: [Item] = []
    private var running: [String: Running] = [:]
    /// Cancelled tasks still ending, by token: they hold their place in the limits.
    private var ending: [UInt64: Bool] = [:]
    /// Covers made for cards still wanted: not made again on the next `want`.
    private var done: Set<String> = []
    private var paused = false
    private var resumeWake: Task<Void, Never>?
    private var nextToken: UInt64 = 0

    public init(listingLimit: Int = CoverQueue.listingLimit, networkListingLimit: Int = CoverQueue.networkListingLimit,
                resumeDelay: Duration = CoverQueue.defaultResumeDelay) {
        self.listingLimit = max(1, listingLimit)
        self.networkListingLimit = max(1, networkListingLimit)
        self.resumeDelay = resumeDelay
    }

    /// The cards that want a cover now, in the order they start: the `visible` ones on screen first, then the margin.
    /// A card running or waiting that is not among them is cancelled or dropped; one already done stays done while
    /// it stays wanted. `isNetwork` must answer without touching the disk (it runs on the queue for every id). `work`
    /// makes and delivers the card's cover, at `.utility` for a visible card and `.background` for the margin's, and
    /// should end soon once cancelled.
    public func want(_ ids: [String], visible: Int, isNetwork: (String) -> Bool,
                     work: @escaping @Sendable (String) async -> Void) {
        let wanted = Set(ids)
        for (id, job) in running where !wanted.contains(id) {
            job.task.cancel()
            ending[job.token] = job.network
            running[id] = nil
        }
        done.formIntersection(wanted)
        var seen: Set<String> = []
        // A repeated id counts once, at its first place.
        pending = ids.enumerated().compactMap { index, id in
            guard seen.insert(id).inserted, running[id] == nil, !done.contains(id) else { return nil }
            return Item(id: id, network: isNetwork(id), visible: index < visible, work: work)
        }
        pump()
    }

    /// True while the viewer is busy: covers wait. Back to false, they start again after `resumeDelay`, unless the
    /// viewer is busy again by then.
    public func pause(_ on: Bool) {
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
        let delay = resumeDelay
        resumeWake = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            await self?.resume()
        }
    }

    private func resume() {
        resumeWake = nil
        paused = false
        pump()
    }

    /// Covers waiting to start, for tests.
    var pendingCount: Int { pending.count }
    /// Covers in flight, cancelled ones still ending included, for tests.
    var runningCount: Int { running.count + ending.count }

    private func inFlight(network: Bool) -> Int {
        running.values.filter { $0.network == network }.count + ending.values.filter { $0 == network }.count
    }

    private func pump() {
        guard !paused else { return }
        var local = inFlight(network: false), network = inFlight(network: true)
        var index = 0
        while index < pending.count {
            let item = pending[index]
            if item.network ? network < networkListingLimit : local < listingLimit {
                pending.remove(at: index)
                start(item)
                if item.network { network += 1 } else { local += 1 }
            } else {
                index += 1
            }
            if local >= listingLimit, network >= networkListingLimit { return }
        }
    }

    private func start(_ item: Item) {
        nextToken += 1
        let token = nextToken, id = item.id, work = item.work
        let task = Task(priority: item.visible ? .utility : .background) {
            await work(id)
            self.finished(id, token: token)
        }
        running[id] = Running(token: token, network: item.network, task: task)
    }

    private func finished(_ id: String, token: UInt64) {
        if ending.removeValue(forKey: token) == nil, running[id]?.token == token {
            running[id] = nil
            done.insert(id)
        }
        pump()
    }
}
