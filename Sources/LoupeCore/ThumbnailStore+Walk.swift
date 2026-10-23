import Foundation

/// What the subtree walk (thumbs-ahead spec, stage 5: `ThumbsWalk`) and Home's work ahead (stage 4) ask of the store:
/// the walk's window of photos behind every window's, its folders' listings in the covers' lanes, its photos' stamps on
/// a share, and the card of a subfolder made ahead.
extension ThumbnailStore {
    /// A walk's listing of a folder (`walkListing`).
    enum WalkListing: Sendable {
        /// Its names (what came within the lane's time limit), and its photos' stamps from a listing with stat (a
        /// local volume); nil on a share, listed by names only.
        case listed(CoverNames, stamps: [String: FileStamp]?)
        /// It cannot be listed (gone, no permission): nothing in it to prepare.
        case gone
        /// Its lane is full, the share is offline (but for its probe turn) or no name came in time: ask again later.
        case notNow
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

    /// The work ahead on one subfolder, Home's (the visible cards' subfolders) and the walk's: its card
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

    /// The walk's listing of `folder`, in its covers' listing lane with that lane's time limit and the share's gate
    /// (`coverListing` as for a summary: an offline share is listed only on its probe turn, time outs count towards
    /// offline, an answer brings it back; the folder's own cover notes are left alone). With stat on a local volume.
    func walkListing(_ folder: URL, in location: ThumbnailLocation?, network: Bool) async -> WalkListing {
        let volume = network ? volumeKey(folder, location) : nil
        switch await coverListing(folder, archive: false, network: network, key: Self.memoKey(folder, nil),
                                  volume: volume, alias: location?.volume, forSummary: true, probe: true) {
        case .listed(let listing, _): return .listed(listing.names, stamps: network ? nil : listing.fileStamps)
        case .settled: return .gone
        case .notNow: return .notNow
        }
    }

    /// A photo's stamp for the walk's window on a share: a background job of the reader (on the thumbnail reads'
    /// threads, behind the open folders' reads), nil when it fails or is cancelled.
    func walkStamp(_ url: URL) async -> FileStamp? {
        try? await reader.stamp(url, priority: ReadPriority(Self.coverReadPriority, isBackground: true))
    }

    /// The subtree walk's window: one folder's stamped photos, made after every window's files
    /// (`ThumbnailQueue.order`'s `trailing`), under the generator's own limits and idle rule; nil when the walk is
    /// over. `complete` false: the folder's photos stamped so far (a share's, in chunks), so the catalog keeps the rows
    /// of the others. A folder some window shows keeps that window's listing.
    public func setWalkWindow(_ request: ThumbnailRequest?, stamps: [URL: FileStamp], complete: Bool = true) async {
        defer { replan() }
        guard let request else {
            walkWindow = nil
            closeUnshownFolders()
            return
        }
        let shown = Set(windows.values.flatMap(\.listings.keys))
        let listings = Self.listings(request.files, stamps).filter { !shown.contains($0.key) }
        walkWindow = Window(request: request, stamps: stamps, listings: listings)
        await openListings(listings, partial: !complete) { $0.walkWindow?.listings }
    }

    /// The walk window's photos still without a thumbnail, counted anew (after any change of windows or folders).
    func countWalkPending() {
        guard let walk = walkWindow else {
            walkPending = []
            return notifyWalk()
        }
        var files = Set(walk.listings.values.flatMap { $0.map(\.url) })
        for url in walk.request.files where listed[url] != nil { files.insert(url) }
        walkPending = files.filter { status($0) == .pending && !evicted.contains($0) }
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
