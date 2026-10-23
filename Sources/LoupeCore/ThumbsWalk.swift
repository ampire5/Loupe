import Foundation

/// How far the subtree walk is (`ThumbsWalk.progress`): folders walked of those found, photos with a thumbnail of
/// those listed in them, why it stopped early ("Too many folders — prepared N"), if it did, and why it waits now.
public struct WalkProgress: Equatable, Sendable {
    public var folders: WorkCount
    public var files: WorkCount
    public var stopped: String?
    /// Why it waits now, for the popover (`ThumbsWalk.waitingForShare`); nil while it goes on.
    public var waiting: String?

    public init(folders: WorkCount = WorkCount(), files: WorkCount = WorkCount(), stopped: String? = nil,
                waiting: String? = nil) {
        self.folders = folders
        self.files = files
        self.stopped = stopped
        self.waiting = waiting
    }
}

/// "Prepare thumbnails of folder and subfolders" (thumbs-ahead spec, stage 5): on the user's command only, the
/// thumbnails of every photo and the cover and summary of every folder down to a depth (`thumbs-depth`; 0 is the folder
/// itself), breadth first, one folder at a time, each listed once.
///
/// Each folder is listed by a task of the cover queue on the walk's own client, in the work-ahead tier: after every
/// window's cards in view and margins, inside the queue's listing limits (one listing at a time on a share, whoever
/// asks), paused with it. That one listing also makes the folder's card for the catalog (its summary, its pick:
/// `ThumbnailStore.walkFolder`), so no cover lists it again. Its photos go to the store's walk window
/// (`ThumbnailStore.setWalkWindow`), made after every window's files under the generator's own limits; on a local
/// volume with the stamps of the listing's stat, on a share (listed by names only, its slot free again at once) stamped
/// one by one in the reader's background threads (`ThumbnailStore.walkStamp`, kept to the share's offline gate and time
/// limit), no more at once than the generator's reads, and handed over in chunks of `stampChunk` as they come. The walk
/// goes on to the next folder once none of the window's photos is still to be made. While a share does not answer, the
/// walk keeps its place and says so (`WalkProgress.waiting`).
///
/// What the walk keeps is bounded by `folderLimit`: past it the walk stops after the folder that found too many and
/// says so (`WalkProgress.stopped`). It never runs on its own; a new `start` ends the walk before it.
public actor ThumbsWalk {
    /// Folders a walk may find at most: its own queue holds as many places (a few hundred bytes each), and it asks the
    /// cover queue for one task at a time, so its cost there does not grow with the bound. Measured in a debug test
    /// build on an Intel iMac (8-core i7-10700K, SSD) over a synthetic local tree of 1 961 empty folders, depth 2, each
    /// listed once with its card made from that listing: 1.6-1.8 s for the whole walk, 1.9-2.3 s of CPU (about one
    /// core and a fifth; two runs). With covers listed apart, as first written, the same tree took 5.4 s and 8.0 s.
    public static let folderLimit = 2_000
    /// Photos stamped on a share before they reach the walk window: the window's folder is synced into the catalog
    /// again at each chunk, so a chunk is a few dozen photos, about a second of a share's stats at two at a time.
    static let stampChunk = 64
    /// How often stamps waiting for the queue's pause look again.
    static let pausePoll: Duration = .milliseconds(100)
    /// `WalkProgress.waiting` while the share does not answer.
    public static let waitingForShare = "Waiting for the share"

    private struct Place: Sendable {
        var url: URL
        var location: ThumbnailLocation?
        var level: Int
    }

    private let store: ThumbnailStore
    private let queue: CoverQueue
    private let client: Int
    private let folderLimit: Int
    private let retryDelay: Duration
    private let maxRetryDelay: Duration
    public private(set) var progress = WalkProgress()
    private var onProgress: (@Sendable (WalkProgress) -> Void)?
    private var task: Task<Void, Never>?
    /// The walk's folders on a share (its root's volume): their listings and stamps take the share's limits.
    private var network = false
    /// The folder being listed, its listing once it came, and the walk waiting for it.
    private var listing: (id: String, place: Place)?
    private var listingResult: ThumbnailStore.WalkListing?
    private var listingWaiter: CheckedContinuation<Void, Never>?

    /// `client`: the walk's id in `queue` (the store's cover queue), apart from every Home's. `retryDelay` and
    /// `maxRetryDelay`: how long a share's stamp that said "not now" waits before it is asked again, doubled each time
    /// up to the cap (the cover queue's, as its listings). `folderLimit` and the delays other than their defaults only
    /// for tests.
    public init(store: ThumbnailStore, queue: CoverQueue, client: Int, folderLimit: Int = ThumbsWalk.folderLimit,
                retryDelay: Duration = CoverQueue.defaultRetryDelay,
                maxRetryDelay: Duration = CoverQueue.defaultMaxRetryDelay) {
        self.store = store
        self.queue = queue
        self.client = client
        self.folderLimit = max(1, folderLimit)
        self.retryDelay = retryDelay
        self.maxRetryDelay = max(retryDelay, maxRetryDelay)
    }

    /// Prepares `folder` (`location`: where the catalog keeps it, as for its card; nil: none) and its subfolders down
    /// to `depth` levels, in the background, after the walk before has ended.
    public func start(_ folder: URL, location: ThumbnailLocation?, depth: Int) {
        let previous = task
        previous?.cancel()
        task = Task(priority: .utility) { [weak self] in
            await previous?.value
            await self?.run(folder, location: location, depth: max(0, depth))
        }
    }

    /// Ends the walk: no more listings or stamps, its window dropped and its task gone from the queue.
    public func cancel() {
        task?.cancel()
    }

    /// `handler` hears the walk's progress whenever it changes, on the walk's actor: the caller coalesces.
    public func setOnProgress(_ handler: @escaping @Sendable (WalkProgress) -> Void) {
        onProgress = handler
    }

    /// Returns once the last walk started has ended (tests).
    func finished() async {
        while let current = task {
            await current.value
            if task == current { return }
        }
    }

    private func announce() {
        onProgress?(progress)
    }

    /// The share does not answer (true) or answered (false): the walk says so while it waits.
    private func setWaiting(_ waiting: Bool) {
        let note = waiting ? Self.waitingForShare : nil
        guard progress.waiting != note else { return }
        progress.waiting = note
        announce()
    }

    private func run(_ root: URL, location: ThumbnailLocation?, depth: Int) async {
        network = await store.isOnShare(root, in: location)
        progress = WalkProgress(folders: WorkCount(done: 0, total: 1))
        announce()
        var places = [Place(url: root, location: location, level: 0)]
        var next = 0
        while next < places.count, !Task.isCancelled {
            let place = places[next]
            next += 1
            guard let listed = await list(place), !Task.isCancelled else { break }
            var listing = CoverListing(names: CoverNames(files: [], folders: []))
            if case .listed(let value) = listed { listing = value }
            let files = ThumbnailStore.finderSorted(listing.names.files).map { place.url.appendingPathComponent($0) }
            // Below the depth only: a folder at the depth is listed and its photos made, its subfolders left alone.
            // (Its card may still show a photo of a subfolder when Home shows it: `folderCard`'s own pick for a folder
            // without photos, Home's card, not the walk going deeper.)
            let subfolders = place.level < depth ? ThumbnailStore.finderSorted(listing.names.folders) : []
            let tooMany = places.count + subfolders.count > folderLimit
            if !tooMany {
                for name in subfolders {
                    places.append(Place(url: place.url.appendingPathComponent(name, isDirectory: true),
                                        location: place.location?.subfolder(name), level: place.level + 1))
                }
                progress.folders.total = places.count
            }
            let stamps = network ? nil : Dictionary(listing.fileStamps.map { (place.url.appendingPathComponent($0.key), $0.value) },
                                                    uniquingKeysWith: { first, _ in first })
            await prepare(files, stamps: stamps, location: place.location)
            guard !Task.isCancelled else { break }
            progress.folders.done += 1
            if tooMany {
                progress.stopped = "Too many folders — prepared \(progress.folders.done)"
                break
            }
            announce()
        }
        listing = nil
        await store.setWalkWindow(nil, stamps: [:])
        await want()
        if progress.waiting != nil { progress.waiting = nil }
        announce()
    }

    /// The folder's listing (and card), by a task of the cover queue: the walk's one `want` for the folder. Nil once
    /// the walk is cancelled.
    private func list(_ place: Place) async -> ThumbnailStore.WalkListing? {
        listing = ("\u{0}walk\u{0}" + place.url.path, place)
        listingResult = nil
        await want()
        if listingResult == nil {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if listingResult != nil || Task.isCancelled {
                        continuation.resume()
                    } else {
                        listingWaiter = continuation
                    }
                }
            } onCancel: {
                Task { await self.wakeLister() }
            }
        }
        listing = nil
        return Task.isCancelled ? nil : listingResult
    }

    /// The listing task's answer: the listing, or "not now" (the share offline: the walk says it waits).
    private func listed(_ result: ThumbnailStore.WalkListing, id: String) {
        guard listing?.id == id else { return }
        if case .notNow(let offline) = result {
            setWaiting(offline)
            return
        }
        setWaiting(false)
        listingResult = result
        wakeLister()
    }

    private func wakeLister() {
        listingWaiter?.resume()
        listingWaiter = nil
    }

    /// The walk's task in the cover queue: the folder being listed, if any.
    private func want() async {
        let store = self.store, network = self.network, listing = self.listing
        let work: @Sendable (String) async -> Bool = { [weak self] id in
            guard let listing, id == listing.id else { return true }
            let result = await store.walkFolder(listing.place.url, in: listing.place.location, network: network)
            await self?.listed(result, id: id)
            if case .notNow = result { return false }
            return true
        }
        await queue.want([], visible: 0, ahead: listing.map { [$0.id] } ?? [], client: client,
                         isNetwork: { _ in network }, work: work)
    }

    /// The folder's photos through the walk window, until none of them is still to be made.
    private func prepare(_ files: [URL], stamps known: [URL: FileStamp]?, location: ThumbnailLocation?) async {
        guard !files.isEmpty else { return }
        progress.files.total += files.count
        announce()
        let count: Int
        if let known {
            let stamped = files.filter { known[$0] != nil }
            await store.setWalkWindow(Self.request(stamped), stamps: known,
                                      keeping: files.filter { known[$0] == nil })
            count = stamped.count
        } else {
            count = await stampInChunks(files, location: location)
        }
        progress.files.total -= files.count - count
        let before = progress.files.done
        var left = await store.walkFilesChanged(from: -1)
        while left > 0, !Task.isCancelled {
            progress.files.done = before + max(0, count - left)
            announce()
            left = await store.walkFilesChanged(from: left)
        }
        if !Task.isCancelled { progress.files.done = before + count }
    }

    /// A share's photos stamped in the reader's background threads, no more at once than the generator's reads, each
    /// waiting while the queue's work ahead is paused; a stamp that says "not now" (the share offline or slow) is asked
    /// again after a growing delay while the walk says it waits. Every `stampChunk` answers the stamped ones go to the
    /// walk window, all of them at the end, those whose stamp failed kept in the catalog. Returns how many have a stamp;
    /// stops when the walk is cancelled.
    private func stampInChunks(_ files: [URL], location: ThumbnailLocation?) async -> Int {
        let limit = max(1, store.readLimit)
        var stamps: [URL: FileStamp] = [:]
        await withTaskGroup(of: (URL, FileStamp?).self) { group in
            var next = 0, answered = 0
            while next < min(limit, files.count), await waitWhilePaused() {
                let url = files[next]
                next += 1
                group.addTask { (url, await self.stamp(url, location: location)) }
            }
            while let (url, stamp) = await group.next() {
                answered += 1
                if let stamp { stamps[url] = stamp }
                guard !Task.isCancelled else { break }
                if answered % Self.stampChunk == 0, answered < files.count {
                    await store.setWalkWindow(Self.request(files.filter { stamps[$0] != nil }), stamps: stamps,
                                              complete: false)
                }
                if next < files.count, await waitWhilePaused() {
                    let url = files[next]
                    next += 1
                    group.addTask { (url, await self.stamp(url, location: location)) }
                }
            }
            group.cancelAll()
        }
        guard !Task.isCancelled else { return stamps.count }
        await store.setWalkWindow(Self.request(files.filter { stamps[$0] != nil }), stamps: stamps,
                                  keeping: files.filter { stamps[$0] == nil })
        return stamps.count
    }

    /// One photo's stamp, asked again after "not now" (doubling from `retryDelay` to `maxRetryDelay`, each wait after
    /// the queue's pause); nil when its stat failed or the walk was cancelled.
    private func stamp(_ url: URL, location: ThumbnailLocation?) async -> FileStamp? {
        var delay = retryDelay
        while !Task.isCancelled {
            switch await store.walkStamp(url, in: location) {
            case .stamp(let stamp):
                setWaiting(false)
                return stamp
            case .failed:
                setWaiting(false)
                return nil
            case .notNow(let offline):
                if offline { setWaiting(true) }
                guard (try? await Task.sleep(for: delay)) != nil, await waitWhilePaused() else { return nil }
                delay = min(delay * 2, maxRetryDelay)
            }
        }
        return nil
    }

    /// Waits while the cover queue's work ahead is paused (the viewer busy; the user's pause to come); false once the
    /// walk is cancelled.
    private func waitWhilePaused() async -> Bool {
        while await queue.aheadPaused {
            guard (try? await Task.sleep(for: Self.pausePoll)) != nil else { return false }
        }
        return !Task.isCancelled
    }

    private static func request(_ files: [URL]) -> ThumbnailRequest {
        ThumbnailRequest(files: files, current: 0, visible: [], isKey: false)
    }
}
