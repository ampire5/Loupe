import Foundation

/// How far the subtree walk is (`ThumbsWalk.progress`): folders walked of those found, photos with a thumbnail of
/// those listed in them, and why it stopped early ("Too many folders — prepared N"), if it did.
public struct WalkProgress: Equatable, Sendable {
    public var folders: WorkCount
    public var files: WorkCount
    public var stopped: String?

    public init(folders: WorkCount = WorkCount(), files: WorkCount = WorkCount(), stopped: String? = nil) {
        self.folders = folders
        self.files = files
        self.stopped = stopped
    }
}

/// "Prepare thumbnails of folder and subfolders" (thumbs-ahead spec, stage 5): on the user's command only, the
/// thumbnails of every photo and the cover and summary of every folder down to a depth (`thumbs-depth`; 0 is the folder
/// itself), breadth first, one folder at a time.
///
/// Each folder is listed by a task of the cover queue on the walk's own client, in the work-ahead tier: after every
/// window's cards in view and margins, inside the queue's listing limits (one listing at a time on a share, whoever
/// asks), paused with it. Its photos go to the store's walk window (`ThumbnailStore.setWalkWindow`), made after every
/// window's files under the generator's own limits; on a local volume with the stamps of the listing's stat, on a share
/// (listed by names only, its slot free again at once) stamped one by one in the reader's background threads, no more
/// at once than the generator's reads, and handed over in chunks of `stampChunk` as they come. Its subfolders (while
/// above the depth) go to the queue's work ahead on the walk's client (`ThumbnailStore.prepareAhead`, as Home's), and
/// the walk goes on to the next folder once none of the window's photos is still to be made. The subfolders' covers
/// stay wanted after the walk until they are made, or a new walk or `cancel` drops them.
///
/// What the walk keeps is bounded by `folderLimit`: past it the walk stops after the folder that found too many and
/// says so (`WalkProgress.stopped`). It never runs on its own; a new `start` ends the walk before it.
public actor ThumbsWalk {
    /// Folders a walk may find at most: its own queue holds as many places (a few hundred bytes each), and the covers
    /// still to make go to the cover queue with every folder it lists. Measured in a debug test build on an Intel iMac
    /// (8-core i7-10700K, SSD) over a synthetic local tree of 1 961 empty folders, depth 2: the walk and its covers took
    /// 5.4 s and 8.0 s of CPU (about one and a half cores), and a cover queue `want` of 2 000 ids costs 4.2 ms, so even
    /// a walk on a share whose covers lag the whole bound behind spends some 8 ms a folder on the queue, well below
    /// that folder's own listing and thumbnails.
    public static let folderLimit = 2_000
    /// Photos stamped on a share before they reach the walk window: the window's folder is synced into the catalog
    /// again at each chunk, so a chunk is a few dozen photos, about a second of a share's stats at two at a time.
    static let stampChunk = 64
    /// How often stamps waiting for the queue's pause look again.
    static let pausePoll: Duration = .milliseconds(100)

    private struct Place: Sendable {
        var url: URL
        var location: ThumbnailLocation?
        var level: Int
    }

    private let store: ThumbnailStore
    private let queue: CoverQueue
    private let client: Int
    private let folderLimit: Int
    public private(set) var progress = WalkProgress()
    private var onProgress: (@Sendable (WalkProgress) -> Void)?
    private var task: Task<Void, Never>?
    /// The walk's folders on a share (its root's volume): their listings and covers take the share's limits.
    private var network = false
    /// The subfolders whose covers the walk still wants, by id (their path), in the order found (`coverOrder` may
    /// still hold some made since, until the next `want`).
    private var covers: [String: Place] = [:]
    private var coverOrder: [String] = []
    /// The folder being listed, its listing once it came, and the walk waiting for it.
    private var listing: (id: String, place: Place)?
    private var listingResult: ThumbnailStore.WalkListing?
    private var listingWaiter: CheckedContinuation<Void, Never>?

    /// `client`: the walk's id in `queue` (the store's cover queue), apart from every Home's. `folderLimit` other
    /// than `ThumbsWalk.folderLimit` only for tests.
    public init(store: ThumbnailStore, queue: CoverQueue, client: Int, folderLimit: Int = ThumbsWalk.folderLimit) {
        self.store = store
        self.queue = queue
        self.client = client
        self.folderLimit = max(1, folderLimit)
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

    /// Ends the walk: no more listings or stamps, its window and its covers dropped.
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

    private func run(_ root: URL, location: ThumbnailLocation?, depth: Int) async {
        network = await store.isOnShare(root, in: location)
        covers = [:]
        coverOrder = []
        progress = WalkProgress(folders: WorkCount(done: 0, total: 1))
        announce()
        var places = [Place(url: root, location: location, level: 0)]
        var next = 0
        while next < places.count, !Task.isCancelled {
            let place = places[next]
            next += 1
            guard let listed = await list(place), !Task.isCancelled else { break }
            var files: [URL] = [], stamps: [URL: FileStamp]?, subfolders: [String] = []
            if case .listed(let names, let known) = listed {
                files = ThumbnailStore.finderSorted(names.files).map { place.url.appendingPathComponent($0) }
                stamps = known.map { known in
                    Dictionary(known.map { (place.url.appendingPathComponent($0.key), $0.value) },
                               uniquingKeysWith: { first, _ in first })
                }
                subfolders = place.level < depth ? ThumbnailStore.finderSorted(names.folders) : []
            }
            let tooMany = places.count + subfolders.count > folderLimit
            if !tooMany, !subfolders.isEmpty {
                for name in subfolders {
                    let sub = Place(url: place.url.appendingPathComponent(name, isDirectory: true),
                                    location: place.location?.subfolder(name), level: place.level + 1)
                    places.append(sub)
                    covers[sub.url.path] = sub
                    coverOrder.append(sub.url.path)
                }
                progress.folders.total = places.count
                await want()
            }
            await prepare(files, stamps: stamps)
            guard !Task.isCancelled else { break }
            progress.folders.done += 1
            if tooMany {
                progress.stopped = "Too many folders — prepared \(progress.folders.done)"
                break
            }
            announce()
        }
        // The window goes; the covers found stay wanted until made, unless the walk was cancelled or stopped.
        listing = nil
        await store.setWalkWindow(nil, stamps: [:])
        if Task.isCancelled || progress.stopped != nil {
            covers = [:]
            coverOrder = []
        }
        await want()
        announce()
    }

    /// The folder's listing, by a task of the cover queue; nil once the walk is cancelled.
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

    private func listed(_ result: ThumbnailStore.WalkListing, id: String) {
        guard listing?.id == id else { return }
        listingResult = result
        wakeLister()
    }

    private func wakeLister() {
        listingWaiter?.resume()
        listingWaiter = nil
    }

    /// The walk's tasks in the cover queue: the folder being listed first, then the subfolders' covers.
    private func want() async {
        let store = self.store, network = self.network, covers = self.covers, listing = self.listing
        let work: @Sendable (String) async -> Bool = { [weak self] id in
            if let listing, id == listing.id {
                let result = await store.walkListing(listing.place.url, in: listing.place.location, network: network)
                if case .notNow = result { return false }
                await self?.listed(result, id: id)
                return true
            }
            guard let place = covers[id] else { return true }
            let done = await store.prepareAhead(place.url, in: place.location, network: network, lastViewed: nil).done
            if done { await self?.coverMade(id) }
            return done
        }
        coverOrder.removeAll { covers[$0] == nil }
        let ids = (listing.map { [$0.id] } ?? []) + coverOrder
        await queue.want([], visible: 0, ahead: ids, client: client, isNetwork: { _ in network }, work: work)
    }

    /// A subfolder's cover made: left out of the next `want` (the queue forgets it then), so what the walk asks of the
    /// queue at each folder is the covers still to make, not every one found.
    private func coverMade(_ id: String) {
        covers[id] = nil
    }

    /// The folder's photos through the walk window, until none of them is still to be made.
    private func prepare(_ files: [URL], stamps known: [URL: FileStamp]?) async {
        guard !files.isEmpty else { return }
        progress.files.total += files.count
        announce()
        let count: Int
        if let known {
            let stamped = files.filter { known[$0] != nil }
            await store.setWalkWindow(Self.request(stamped), stamps: known)
            count = stamped.count
        } else {
            count = await stampInChunks(files)
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
    /// waiting while the queue's work ahead is paused; every `stampChunk` answers the stamped ones go to the walk
    /// window, all of them at the end. Returns how many have a stamp; stops when the walk is cancelled.
    private func stampInChunks(_ files: [URL]) async -> Int {
        let store = self.store, limit = max(1, store.readLimit)
        var stamps: [URL: FileStamp] = [:]
        await withTaskGroup(of: (URL, FileStamp?).self) { group in
            var next = 0, answered = 0
            while next < min(limit, files.count), await waitWhilePaused() {
                let url = files[next]
                next += 1
                group.addTask { (url, await store.walkStamp(url)) }
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
                    group.addTask { (url, await store.walkStamp(url)) }
                }
            }
            group.cancelAll()
        }
        guard !Task.isCancelled else { return stamps.count }
        await store.setWalkWindow(Self.request(files.filter { stamps[$0] != nil }), stamps: stamps)
        return stamps.count
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
