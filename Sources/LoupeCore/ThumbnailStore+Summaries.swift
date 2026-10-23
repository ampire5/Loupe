import Foundation
import HomeScreenModel

/// Folder summaries (folder cards spec, "Сводка папки"): read from the batch waiting or the catalog, queued for the
/// store's next batch, and the open folder's from its full listing.
extension ThumbnailStore {
    /// The stored summary of the folder `location` names (`ThumbnailLocation.subfolder`), from the catalog alone. Nil
    /// when there is none or the catalog cannot say: a summary never gets in the way of thumbnails.
    /// One waiting for the next batch first.
    public func folderSummary(at location: ThumbnailLocation) async -> FolderSummary? {
        storedSummary(at: location)
    }

    /// The stored summaries of the direct subfolders of the folder `location` names (R8: a card's "+N inside"): the
    /// catalog's, and those waiting for its next batch, the newer per folder. One query, no listing; empty without a
    /// catalog.
    public func childSummaries(of location: ThumbnailLocation) async -> ChildSummaries {
        let photos = childSummaryPhotos(of: location)
        return ChildSummaries(count: photos.count, photos: photos.values.reduce(0, +))
    }

    /// `childSummaries`' photo counts by subfolder path: the catalog's, and those waiting for its next batch.
    func childSummaryPhotos(of location: ThumbnailLocation) -> [String: Int] {
        var photos = perform("child summaries", { try $0.childSummaries(of: location) }) ?? [:]
        let prefix = location.folder.hasSuffix("/") ? location.folder : location.folder + "/"
        for (place, summary) in pendingSummaries.values where place.volume == location.volume
            && place.folder.hasPrefix(prefix) && place.folder.count > prefix.count
            && !place.folder.dropFirst(prefix.count).contains("/") && !place.folder.lowercased().hasSuffix(".zip") {
            photos[place.folder] = summary.photos
        }
        return photos
    }

    /// Stores folder summaries in one batch, now. Failure is logged by `perform` and leaves the summaries unstored:
    /// they are made again on the next pass.
    public func putFolderSummaries(_ items: [(location: ThumbnailLocation, summary: FolderSummary)]) async {
        // A newer summary of the same folder waiting for the batch would be written over this one.
        for (location, _) in items { pendingSummaries[Self.summaryKey(location)] = nil }
        _ = perform("summaries", { try $0.putSummaries(items) })
    }

    /// The open folder's summary from its full listing (`BrowserListingSource.full`, which has the photos' dates and
    /// sizes on a share too: a share's folder gets them once visited), kept in the catalog with the folder's own date,
    /// as its parent's listing gives it, so the folder's card finds it fresh. Where the catalog keeps the folder and
    /// its date are asked in the folder's resolving lane (`folderLocation`'s limits: nothing when it does not answer);
    /// the summary is counted off the actor and goes with the next batch.
    public func putOpenFolderSummary(_ folder: URL, listing entries: [BrowserEntry]) async {
        // A zip's card has its summary from its directory; inside, the listing is its photos.
        guard !ArchivePath.isArchive(folder) else { return }
        let locate = self.locate, network = coverVolumeIsNetwork(folder)
        // Its entries are the share's answer, whatever its resolve below does.
        if network { noteVolumeAnswered(volumeKey(folder, nil)) }
        let outcome = await Self.onThread(coverThreads, lane: CoverLane(network: network, resolving: true),
                                          timeout: network ? coverNetworkTimeout : coverLocalTimeout) {
            (_: @Sendable (OpenFolderPlace) -> Bool) -> OpenFolderPlace in
            // A URL of its own: one handed over may hold resource values cached before the listing.
            let fresh = URL(fileURLWithPath: folder.path, isDirectory: true)
            return OpenFolderPlace(location: locate(folder.appendingPathComponent("_")),
                                   modified: try? fresh.resourceValues(forKeys: [.contentModificationDateKey])
                                       .contentModificationDate)
        }
        guard case .value(let place, _) = outcome else { return }
        // The folder's share answered.
        if network { noteVolumeAnswered(volumeKey(folder, place.location), alias: place.location?.volume) }
        guard let location = place.location else { return }
        let summary = await Self.offActor(qos: Self.coverQoS) {
            FolderSummary.of(listing: entries, folderModified: place.modified)
        }
        // A relist that changed nothing (the watcher's): nothing to write.
        guard let write = Self.summaryToStore(summary, stored: storedSummary(at: location)) else { return }
        queueSummary(write, at: location)
    }

    /// A folder renamed (the browser, through `PathMoving`): its summary and its subfolders' go with it, in the
    /// catalog and in the batch waiting, so its card keeps them under the new name. Where the catalog keeps it is
    /// asked of the new path, off the actor (`locate` may block on a slow share); the old one is the same volume and
    /// parent with the old name.
    public func moveSummaries(from: URL, to: URL) async {
        let locate = self.locate
        guard let location = await Self.offActor(qos: Self.coverQoS, { locate(to.appendingPathComponent("_")) })
        else { return }
        let parent = (location.folder as NSString).deletingLastPathComponent
        let move = PathMove(from: URL(fileURLWithPath: (parent == "/" ? "" : parent) + "/" + from.lastPathComponent),
                            to: URL(fileURLWithPath: location.folder))
        // The batch as the catalog: those at the new path or under it are stale, those at the old one move.
        let waiting = pendingSummaries.filter { $0.value.location.volume == location.volume }
        let stale = PathMove(from: URL(fileURLWithPath: move.to), to: URL(fileURLWithPath: move.to))
        for (key, pending) in waiting where stale.moved(pending.location.folder) != nil { pendingSummaries[key] = nil }
        for (key, pending) in waiting {
            guard let moved = move.moved(pending.location.folder) else { continue }
            pendingSummaries[key] = nil
            let target = ThumbnailLocation(volume: pending.location.volume, folder: moved, name: pending.location.name)
            pendingSummaries[Self.summaryKey(target)] = (target, pending.summary)
        }
        _ = perform("move summaries", { try $0.moveSummaries(volume: location.volume, from: move.from, to: move.to) })
    }

    /// "Refresh cover" on a folder's card: its summary goes from the batch waiting and the catalog, and this session's
    /// memos of it (its pick, its subfolders' names, its summary listed or due, its being found empty, its time outs)
    /// from memory, so its next card lists it again. `location` is where the catalog keeps the folder (as for its
    /// card), `folder` its path, which the memos are keyed by (at any of its dates). Its thumbnails stay in the catalog.
    public func forgetSummaryAndPick(of location: ThumbnailLocation, folder: URL) {
        pendingSummaries[Self.summaryKey(location)] = nil
        _ = perform("forget summary", { try $0.deleteSummary(at: location) })
        let path = folder.standardizedFileURL.path
        func isFolder(_ key: String) -> Bool { key == path || key.hasPrefix(path + "\u{0}") }
        coverPicks = coverPicks.filter { !isFolder($0.key) }
        summaryTried = summaryTried.filter { !isFolder($0) }
        summaryDue = summaryDue.filter { !isFolder($0) }
        emptyCovers = emptyCovers.filter { !isFolder($0) }
        coverTimeouts = coverTimeouts.filter { !isFolder($0.key) }
        if let names = coverSubfolders.removeValue(forKey: path) { coverSubfolderNames -= names.names.count }
    }

    /// Summaries waiting for the next batch at most: a full batch is written at once, else with the thumbnails'
    /// batch (`commitDelay`). Covers finish a few a second, so a batch is mostly what a second of covers made; the
    /// bound keeps a burst (a folder of hundreds of zips from the catalog) to one transaction per this many, each
    /// short on the store's actor. `putSummaries` into a table of 10 000 rows (Intel iMac, 8-core i7, SSD; best of 10):
    /// 1 / 16 / 64 / 256 rows in 0.28 / 0.45 / 1.15 / 3.35 ms (docs/bench/folder-cards.md).
    static let summaryBatch = 64

    /// A summary for the next batch (nothing without a database).
    func queueSummary(_ summary: FolderSummary, at location: ThumbnailLocation) {
        guard database() != nil else { return }
        pendingSummaries[Self.summaryKey(location)] = (location, summary)
        if pendingSummaries.count >= Self.summaryBatch { commit() } else { scheduleCommit() }
    }

    /// The summary of the folder `location` names, waiting for the batch or from the catalog.
    func storedSummary(at location: ThumbnailLocation) -> FolderSummary? {
        if let pending = pendingSummaries[Self.summaryKey(location)] { return pending.summary }
        return perform("summary", { try $0.summary(at: location) }) ?? nil
    }

    /// The summary to write for a folder after a count, or nil to keep the stored one: the same, or the same facts
    /// counted without the folder's date (a card asked for before its parent's complete listing) while the stored one
    /// has it. Written over undated, a summary is never fresh again, and the folder is listed once per session.
    nonisolated static func summaryToStore(_ summary: FolderSummary, stored: FolderSummary?) -> FolderSummary? {
        guard let stored, summary != stored else { return stored == nil ? summary : nil }
        if summary.folderModified == nil, stored.folderModified != nil {
            var dated = summary
            dated.folderModified = stored.folderModified
            if dated == stored { return nil }
        }
        return summary
    }

    nonisolated static func summaryKey(_ location: ThumbnailLocation) -> String {
        location.volume + "\u{0}" + location.folder
    }

    /// A complete listing's summary at the folder's date (the parent listing's, which freshness compares; a zip's own
    /// without it). Names only (a share): the dates and size of a stored summary that has them stay, as the folder was
    /// when it was open.
    nonisolated static func summary(of listing: CoverListing, modified: Date?, stored: FolderSummary?) -> FolderSummary {
        var summary = listing.summary ?? FolderSummary.of(names: listing.names, folderModified: modified)
        if let modified { summary.folderModified = modified }
        if !summary.datesKnown, let stored, stored.datesKnown {
            summary.bytes = stored.bytes
            summary.first = stored.first
            summary.last = stored.last
            summary.histogram = stored.histogram
            summary.datesKnown = true
        }
        return summary
    }
}

/// Renames in the file browser (`BrowserFileActions`): the summaries move with their folders, after the call returns.
extension ThumbnailStore: PathMoving {
    public nonisolated func movePaths(from: URL, to: URL) {
        Task(priority: .utility) { await self.moveSummaries(from: from, to: to) }
    }
}
