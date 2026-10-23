import Foundation

/// What the subtree walk (thumbs-ahead spec, stage 5: `ThumbsWalk`) and Home's work ahead (stage 4) ask of the store:
/// the walk's window of photos behind every window's, its folders' listings in the covers' lanes, its photos' stamps on
/// a share, and the card of a subfolder made ahead.
extension ThumbnailStore {
    /// A walk's listing of a folder (`walkFolder`).
    enum WalkListing: Sendable {
        /// What came within the lane's time limit: its names, and on a local volume (a listing with stat) its photos'
        /// stamps (`CoverListing.fileStamps`; none on a share, listed by names only).
        case listed(CoverListing)
        /// It cannot be listed (gone, no permission): nothing in it to prepare.
        case gone
        /// Its lane is full, the share is offline (but for its probe turn) or did not answer in time: ask again later.
        /// `offline`: the share is offline now.
        case notNow(offline: Bool)
    }

    /// A walk's stamp of a photo on a share (`walkStamp`).
    enum WalkStamp: Sendable {
        case stamp(FileStamp)
        /// The share answered without one (gone, no permission): the photo is left out, its catalog row kept.
        case failed
        /// The share is offline (but for its probe turn) or did not answer in time: ask again later. `offline`: the
        /// share is offline now.
        case notNow(offline: Bool)
    }

    /// The decoded cells of a subfolder made ahead are dropped (only the catalog keeps what it made: no view shows
    /// it), so they are decoded as small as can be: the thumbnails kept are the store's own size whatever this is.
    static let aheadCellPixels = 16

    /// What the work ahead on a subfolder came to (`prepareAhead`).
    public struct AheadOutcome: Equatable, Sendable {
        /// Its work is over (made, or no longer wanted); false: "not now", or its summary still to be listed.
        public var done: Bool
        /// A new or changed summary was queued for the catalog: its parent's "+N inside" may have changed.
        public var summaryWritten: Bool
    }

    /// Home's work ahead on one subfolder of a visible card (the walk makes its folders' cards from its own listing,
    /// `walkFolder`): its card
    /// (`folderCard`, at the date its parent's listing gave, else its own stat's: `subfolderModified`, "not now" when
    /// that does not answer) for the catalog only, with "not now" and a summary still to be listed as a card's. Ends
    /// as done once its task is cancelled.
    public func prepareAhead(_ subfolder: URL, in location: ThumbnailLocation?, network: Bool,
                             lastViewed: String?) async -> AheadOutcome {
        guard case .known(let modified) = await subfolderModified(subfolder, in: location) else {
            return AheadOutcome(done: false, summaryWritten: false)
        }
        guard !Task.isCancelled else { return AheadOutcome(done: true, summaryWritten: false) }
        guard let made = await folderCard(subfolder, archive: false, in: location, network: network,
                                          maxPixel: Self.aheadCellPixels, lastViewed: lastViewed, modified: modified)
        else { return AheadOutcome(done: false, summaryWritten: false) }
        guard !Task.isCancelled else { return AheadOutcome(done: true, summaryWritten: false) }
        return AheadOutcome(done: !(made.summaryPending || (made.problem == .offline && made.images.isEmpty)),
                            summaryWritten: made.summaryWritten)
    }

    /// Whether `folder` is on a share: its catalog volume's, else the mount table's (never hangs).
    func isOnShare(_ folder: URL, in location: ThumbnailLocation?) -> Bool {
        location?.isNetwork ?? coverVolumeIsNetwork(folder)
    }

    /// The walk's one listing of `folder`, and its card from it: the folder's date first (`subfolderModified`: its
    /// parent's dated listing this session, else one stat), then the listing, in its covers' lanes with their time
    /// limits and the share's gate (`coverListing` as for a summary: an offline share is listed only on its probe turn,
    /// time outs count towards offline, an answer brings it back). With stat on a local volume. A complete listing
    /// makes the folder's card as a cover's listing would (`walkCard`), so nothing lists it again for its cover.
    func walkFolder(_ folder: URL, in location: ThumbnailLocation?, network: Bool) async -> WalkListing {
        let volume = network ? volumeKey(folder, location) : nil
        guard case .known(let modified) = await subfolderModified(folder, in: location), !Task.isCancelled else {
            return .notNow(offline: isOffline(volume))
        }
        let key = Self.memoKey(folder, modified)
        switch await coverListing(folder, archive: false, network: network, key: key, volume: volume,
                                  alias: location?.volume, forSummary: true, probe: true) {
        case .listed(let listing, let complete):
            if complete, let location {
                await walkCard(folder, listing: listing, location: location, modified: modified, key: key)
            }
            return .listed(listing)
        case .settled: return .gone
        case .notNow: return .notNow(offline: isOffline(volume))
        }
    }

    /// A walked folder's card from the walk's complete listing, as `folderCard`'s listing makes it: its pick (photos
    /// or subfolders, or found empty) and its subfolders remembered, its summary at its date queued for the catalog
    /// when new or changed, and its summary listed for the session. No pictures: the walk window makes its photos, and
    /// its card shows them from the catalog.
    private func walkCard(_ folder: URL, listing: CoverListing, location: ThumbnailLocation, modified: Date?,
                          key: String) async {
        let names = listing.names
        let plan = await Self.offActor(qos: Self.coverQoS) {
            CoverSampling.plan(names: Self.finderSorted(names.files), directories: Self.finderSorted(names.folders),
                               lastViewed: nil)
        }
        switch plan {
        case .photos(let picked): remember(.photos(Array(picked)), for: key, lastViewed: nil)
        case .subfolders(let subfolders): remember(.subfolders(Array(subfolders)), for: key, lastViewed: nil)
        case .empty: emptyCovers.insert(key)
        }
        _ = card([], listing: listing, problem: nil, modified: modified, location: location, folder: folder)
        noteSummaryTried(key)
    }

    /// A photo's stamp for the walk's window on a share, kept to the share's gate as its listings are: while the share
    /// is offline only on its probe turn (`coverProbeInterval`), else "not now"; a background job of the reader (on
    /// the thumbnail reads' threads, behind the open folders' reads) given the share's listing time limit, whose
    /// expiry (or a connection error) counts towards offline, and whose answer brings the share back. `location`:
    /// where the catalog keeps the photo's folder (nil: none).
    func walkStamp(_ url: URL, in location: ThumbnailLocation?) async -> WalkStamp {
        let volume = volumeKey(url.deletingLastPathComponent(), location)
        guard let turn = takeProbeTurn(volume) else { return .notNow(offline: true) }
        let reader = self.reader, timeout = coverNetworkTimeout
        let priority = ReadPriority(Self.coverReadPriority, isBackground: true)
        enum Race: Sendable {
            case stamp(FileStamp)
            case error(any Error)
            case timedOut
        }
        let race = await withTaskGroup(of: Race?.self, returning: Race?.self) { group in
            group.addTask {
                do { return .stamp(try await reader.stamp(url, priority: priority)) } catch {
                    return Task.isCancelled ? nil : .error(error)
                }
            }
            group.addTask { (try? await Task.sleep(for: timeout)) != nil ? .timedOut : nil }
            for await answer in group {
                guard let answer else { continue }
                group.cancelAll()
                return answer
            }
            return nil
        }
        switch race {
        case .stamp(let stamp)?:
            noteVolumeAnswered(volume, alias: location?.volume)
            return .stamp(stamp)
        case .error(let error)?:
            if !coverVolumeIsNetwork(url) {
                markVolumeOffline(volume)   // the mount table no longer puts it on a share: its volume is gone
            } else if Self.isConnectionError(error) {
                noteVolumeTimeout(volume)
            } else {
                noteVolumeAnswered(volume, alias: location?.volume)   // gone, no permission: the share answered
                return .failed
            }
            return .notNow(offline: isOffline(volume))
        case .timedOut?:
            noteVolumeTimeout(volume)
            return .notNow(offline: isOffline(volume))
        case nil:
            giveBack(turn, volume)   // cancelled: the turn was not spent
            return .notNow(offline: false)
        }
    }

    /// The subtree walk's window: one folder's stamped photos, made after every window's files
    /// (`ThumbnailQueue.order`'s `trailing`), under the generator's own limits and idle rule; nil when the walk is
    /// over. `complete` false: the folder's photos stamped so far (a share's, in chunks), so the catalog keeps the rows
    /// of the others; `keeping`: photos listed without a stamp (their stat failed), whose rows the catalog keeps too.
    /// A folder some window shows is opened with that window's listing while it shows it, and with the walk's once it
    /// no longer does (`reopenWalkFolders`).
    public func setWalkWindow(_ request: ThumbnailRequest?, stamps: [URL: FileStamp], complete: Bool = true,
                              keeping: [URL] = []) async {
        defer { replan() }
        guard let request else {
            walkWindow = nil
            walkPartial = false
            walkKept = [:]
            closeUnshownFolders()
            return
        }
        walkWindow = Window(request: request, stamps: stamps, listings: Self.listings(request.files, stamps))
        walkPartial = !complete
        walkKept = Dictionary(grouping: keeping, by: { $0.deletingLastPathComponent() })
            .mapValues { Set($0.map(\.lastPathComponent)) }
        await openWalkFolders()
    }

    /// The walk window's folders no window shows, opened with the walk's listings (after a window let one go too).
    func reopenWalkFolders() async {
        guard walkWindow != nil else { return }
        await openWalkFolders()
        replan()
    }

    private func openWalkFolders() async {
        guard let walk = walkWindow else { return }
        let shown = Set(windows.values.flatMap(\.listings.keys))
        await openListings(walk.listings.filter { !shown.contains($0.key) }, partial: walkPartial, kept: walkKept) {
            $0.walkWindow?.listings
        }
    }

    /// The walk window's photos still without a thumbnail, counted anew (after any change of windows or folders): those
    /// listed (a window's folder lists them while it shows it) or in a folder the walk opens.
    func countWalkPending() {
        guard let walk = walkWindow else {
            walkPending = []
            return notifyWalk()
        }
        let shown = Set(windows.values.flatMap(\.listings.keys))
        var pending: Set<URL> = []
        for (dir, listing) in walk.listings {
            for file in listing where listed[file.url] != nil || !shown.contains(dir) {
                if status(file.url) == .pending, !evicted.contains(file.url) { pending.insert(file.url) }
            }
        }
        walkPending = pending
        notifyWalk()
    }

    /// A photo made or failed: one fewer for the walk to wait for.
    func walkFileDone(_ url: URL) {
        if walkPending.remove(url) != nil { notifyWalk() }
    }

    private func notifyWalk() {
        guard let waiter = walkWaiter, waiter.count != walkPending.count else { return }
        walkWaiter = nil
        waiter.continuation.resume(returning: walkPending.count)
    }

    /// The count of the walk window's photos without a thumbnail, once it is no longer `count` (at once if it is
    /// not), or as it is when the task is cancelled.
    func walkFilesChanged(from count: Int) async -> Int {
        guard walkPending.count == count, !Task.isCancelled else { return walkPending.count }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                walkWaiter?.continuation.resume(returning: walkPending.count)
                walkWaiter = (count, continuation)
            }
        } onCancel: {
            Task { await self.releaseWalkWaiter() }
        }
    }

    private func releaseWalkWaiter() {
        guard let waiter = walkWaiter else { return }
        walkWaiter = nil
        waiter.continuation.resume(returning: walkPending.count)
    }
}
