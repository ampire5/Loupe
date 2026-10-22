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
        var photos = perform("child summaries", { try $0.childSummaries(of: location) }) ?? [:]
        let prefix = location.folder.hasSuffix("/") ? location.folder : location.folder + "/"
        for (place, summary) in pendingSummaries.values where place.volume == location.volume
            && place.folder.hasPrefix(prefix) && place.folder.count > prefix.count
            && !place.folder.dropFirst(prefix.count).contains("/") && !place.folder.lowercased().hasSuffix(".zip") {
            photos[place.folder] = summary.photos
        }
        return ChildSummaries(count: photos.count, photos: photos.values.reduce(0, +))
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
        guard summary != storedSummary(at: location) else { return }
        queueSummary(summary, at: location)
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
