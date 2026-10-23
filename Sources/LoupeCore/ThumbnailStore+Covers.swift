import CoreGraphics
import Foundation
import HomeScreenModel

/// Home's card covers (Home spec §2.5): the thumbnail of a file whose folder no window lists, from the catalog without
/// opening the folder, else made from the file and kept in the database like any thumbnail.
extension ThumbnailStore {
    /// The cover of `url`, decoded to fill a cell of `maxPixel` (its short side covers it, up to the thumbnail's own
    /// size: `ThumbnailMaker.decodeFillCell`); nil when the file cannot be read. A folder some window
    /// lists answers from the strip's thumbnails; else a stored thumbnail whose stamp is still the file's; else one
    /// made now, one at a time, behind every viewer read.
    public func cover(_ url: URL, maxPixel: Int) async -> CGImage? {
        if ids[url] != nil, let cell = await stripCell(url, side: maxPixel) { return cell }
        let locate = self.locate
        // `resolve` may block on a slow share: never on the actor.
        let location = await Self.offActor { locate(url) }
        guard let stamp = try? await reader.stamp(url, priority: ReadPriority.background) else { return nil }
        if let location, let row = perform("cover", { try $0.file(at: location) }) ?? nil, row.stamp == stamp,
           let stored = perform("cover", { try $0.thumbnail(row.id) }) ?? nil {
            return await Self.offActor { ThumbnailMaker.decodeFillCell(stored.jpeg, side: maxPixel) }
        }
        try? await coverLimit.acquireSlot(forCurrent: false, rank: Self.readPriority)
        defer { coverLimit.releaseSlot(forCurrent: false) }
        let recipe = Recipe(url: url, listedStamp: stamp, maxSide: thumbSize, reader: reader,
                            decodeLimit: decodeLimit, decoder: decoder, cachedBytes: cachedBytes,
                            readEnded: {}, readAgain: {})
        var timing = Timing()
        guard case .made(let jpeg, let info, let madeStamp) = await Self.generate(recipe, &timing) else { return nil }
        if let location {
            _ = perform("cover") { db in
                let id = try db.addFile(location, stamp: madeStamp)
                try db.put([(id, madeStamp, jpeg, info)])
            }
        }
        return await Self.offActor { ThumbnailMaker.decodeFillCell(jpeg, side: maxPixel) }
    }

    /// The file browser's folder cards (file browser spec §4.2): how many photos the catalog knows in each folder, from
    /// rows earlier listings left; a folder never listed has no count (it is not listed for one).
    public func knownCounts(_ folders: [URL]) async -> [URL: Int] {
        let locate = self.locate
        var counts: [URL: Int] = [:]
        for folder in folders {
            // `resolve` may block on a slow share: never on the actor.
            guard let location = await Self.offActor({ locate(folder.appendingPathComponent("_")) }),
                  let count = perform("counts", { try $0.fileCount(in: location) }) ?? nil else { continue }
            counts[folder] = count
        }
        return counts
    }

    /// A folder card's mosaic (file browser, second round): up to `limit` photos of the folder that already have a
    /// thumbnail, by name, from the catalog alone — no listing and no read of the folder, which on a slow share would
    /// queue in front of what the user clicked.
    public func folderSamples(_ folder: URL, limit: Int) async -> [URL] {
        let locate = self.locate
        guard let location = await Self.offActor({ locate(folder.appendingPathComponent("_")) }),
              let names = perform("samples", { try $0.namesWithThumbnails(in: location, limit: limit) }) else { return [] }
        return names.map { folder.appendingPathComponent($0) }
    }

    /// The stored thumbnail of `url` decoded to fill a cell of `maxPixel` (`decodeFillCell`), from the catalog alone:
    /// no stat and no read of the file (a folder card's mosaic on a slow share). Nil when the catalog has none; it may
    /// be older than the file, which only a folder card can afford.
    public func catalogThumbnail(_ url: URL, maxPixel: Int) async -> CGImage? {
        let locate = self.locate
        guard let location = await Self.offActor({ locate(url) }),
              let row = perform("catalog", { try $0.file(at: location) }) ?? nil,
              let stored = perform("catalog", { try $0.thumbnail(row.id) }) ?? nil else { return nil }
        return await Self.offActor { ThumbnailMaker.decodeFillCell(stored.jpeg, side: maxPixel) }
    }
}

/// What a folder's (or a zip's) listing gives a cover: its photos' names (a zip's entries as one path component each,
/// "caps∕0001.jpg") and its subfolders' names, in listing order.
public struct CoverNames: Equatable, Sendable {
    public var files: [String]
    public var folders: [String]

    public init(files: [String], folders: [String]) {
        self.files = files
        self.folders = folders
    }
}

/// A folder's direct subfolders from its card's complete listing (`ThumbnailStore.coverSubfolders`): their names in
/// listing order, the dates a listing with stat gave, and when they were last asked for.
struct CoverSubfolders {
    var names: [String]
    var dates: [String: Date]
    var use: UInt64
}

/// A folder's pick from a complete listing (`ThumbnailStore.coverPicks`): its photos (spread across it, the one last
/// viewed first) or, without any, its subfolders.
struct CoverPick {
    enum Kind {
        case photos([String])
        case subfolders([String])
    }

    var kind: Kind
    var lastViewed: String?
    var use: UInt64
}

/// Where the catalog keeps a folder's files, as `ThumbnailStore.folderLocation` found it.
public enum CoverPlace: Equatable, Sendable {
    case located(ThumbnailLocation)
    /// The system could not say (the folder is gone, or cannot be examined): covers go without the catalog, on a
    /// share's terms when the mount table says it is one.
    case unknown(network: Bool)
    /// Its resolving lane is full of hung calls, or the resolve did not answer in time: ask again later.
    case notNow
}

extension ThumbnailLocation {
    /// On a share (`net:` volume): its covers' listings have a time limit and a lane of their own.
    public var isNetwork: Bool { volume.hasPrefix("net:") }

    /// The location of the file `name` in this location's folder.
    public func sibling(_ name: String) -> ThumbnailLocation {
        ThumbnailLocation(volume: volume, folder: folder, name: name)
    }

    /// The subfolder (or zip) `name` of this location's folder, as a location in it (named "_", like
    /// `resolve(folder/_)`), made without asking the system: the same volume, one level down. Home resolves the folder
    /// it shows once (`ThumbnailStore.folderLocation`) and its cards' covers go from there.
    public func subfolder(_ name: String) -> ThumbnailLocation {
        ThumbnailLocation(volume: volume, folder: folder == "/" ? "/" + name : folder + "/" + name, name: "_")
    }
}

/// Home's folder and archive covers made in the background (folder covers spec): `coverQueue` runs `folderCover` for a
/// few cards at a time.
extension ThumbnailStore {
    /// Lists `folder` (a zip's directory when `archive`), blocking. Now and then `part` gets the names so far; false
    /// from it stops the listing (thrown or returned, either will do).
    typealias CoverLister = @Sendable (_ folder: URL, _ archive: Bool,
                                       _ part: @escaping @Sendable (CoverNames) -> Bool) throws -> CoverNames
    /// `CoverLister` with stat when `dated` (a local volume): the listing's summary and dates come too.
    typealias DatedCoverLister = @Sendable (_ folder: URL, _ archive: Bool, _ dated: Bool,
                                            _ part: @escaping @Sendable (CoverListing) -> Bool) throws -> CoverListing

    /// How long a cover's listing on a share may take (and `folderLocation`): what came by then is what the photos are
    /// picked from, so a folder of thousands of files on a slow share holds its place in the queue no longer than this.
    public static let coverListingTimeout: Duration = .seconds(2)
    /// The same on a local volume: generous (a local listing of thousands of names takes well under a second), only so
    /// a disk that hangs (a USB drive spinning up, or failing) cannot hold the local cards' places for good.
    public static let coverLocalListingTimeout: Duration = .seconds(10)
    /// Listings of one folder that gave no name in time before it is given up for the session (a share alive but too
    /// slow): with `CoverQueue`'s growing retry delay, a few seconds of the share's time per card, not one a second.
    static let coverTimeoutsAllowed = 3
    /// Covers' reads and decodes go behind the open folders' thumbnails (`readPriority`) in the reader's queue and
    /// the decode slots.
    public static let coverReadPriority = readPriority + 1
    /// Thumbnails a cover makes at most: the four of a folder's mosaic.
    static let coverPhotos = 4
    /// Folders whose last pick is remembered (`coverPicks`): a few names each, so a few hundred kilobytes at most, for
    /// the folders of any browsing session.
    static let coverPickLimit = 4000
    /// Subfolder names remembered for the work ahead (`coverSubfolders`), in all: a few megabytes at most.
    static let coverSubfolderNameLimit = 50_000
    /// Subfolders of one folder remembered at most: a card with more prepares none ahead.
    static let coverSubfoldersPerFolder = 1_000
    /// Subfolders looked into below a folder without photos: its own, and theirs.
    static let coverDepth = 2
    /// Threads in a cover's blocking call at most, per lane (`CoverLane`: listings and resolves, each on local volumes
    /// and on shares), those given up on included: one hung on a dead share stays in the kernel. Past that the lane's
    /// calls are "not now" until one returns, so a share that hangs costs a few threads, not one per card, and never
    /// another lane's. One more than the most `CoverQueue` runs at once in a listing lane.
    static let coverThreadsPerLane = 3
    /// How often a cover waiting for the viewer to go idle looks again (at most a few covers wait at once).
    static let coverIdlePoll: Duration = .milliseconds(50)
    /// The covers' threads: background work, below the viewer's and the open folders' thumbnails.
    static let coverQoS = DispatchQoS.QoSClass.utility

    /// Tests: a fake listing of names only (dated or not), and the time limits.
    func setCoverListing(_ lister: @escaping CoverLister, networkTimeout: Duration = coverListingTimeout,
                         localTimeout: Duration = coverLocalListingTimeout) {
        setCoverListing(dated: { folder, archive, _, part in
            CoverListing(names: try lister(folder, archive) { part(CoverListing(names: $0)) })
        }, networkTimeout: networkTimeout, localTimeout: localTimeout)
    }

    /// Tests: a fake listing, and the time limits.
    func setCoverListing(dated lister: @escaping DatedCoverLister, networkTimeout: Duration = coverListingTimeout,
                         localTimeout: Duration = coverLocalListingTimeout) {
        coverLister = lister
        coverNetworkTimeout = networkTimeout
        coverLocalTimeout = localTimeout
    }

    /// Tests: which paths are on a share, instead of the mount table.
    func setCoverVolumes(_ isNetwork: @escaping @Sendable (URL) -> Bool) {
        coverVolumeIsNetwork = isNetwork
    }

    /// Where the catalog keeps `folder`'s files (`locate(folder/_)`), for its cards' covers (`subfolder`). Resolving
    /// asks the system (realpath, statfs), which can hang on a share: it runs in a resolving lane of its own, the
    /// share's or the local volumes' as the mount table says (which never hangs), and after the lane's time limit (or a
    /// cancel) the answer is `.notNow` and the thread is left to finish alone. The caller asks again later.
    public func folderLocation(_ folder: URL) async -> CoverPlace {
        switch await resolveFolder(folder) {
        case .place(let place): return place
        case .busy, .timedOut: return .notNow
        }
    }

    /// `folderLocation`'s answer, with its "not now" told apart: the lane full (`.busy`) or the resolve not answering
    /// in time (`.timedOut`).
    enum FolderResolve: Equatable {
        case place(CoverPlace)
        case busy
        case timedOut
    }

    func resolveFolder(_ folder: URL) async -> FolderResolve {
        let locate = self.locate, network = coverVolumeIsNetwork(folder)
        let outcome = await Self.onThread(coverThreads, lane: CoverLane(network: network, resolving: true),
                                          timeout: network ? coverNetworkTimeout : coverLocalTimeout) {
            (_: @Sendable (ThumbnailLocation?) -> Bool) -> ThumbnailLocation? in
            locate(folder.appendingPathComponent("_"))
        }
        switch outcome {
        case .value(let location?, _): return .place(.located(location))
        case .value(nil, _), .failed: return .place(.unknown(network: network))
        case .busy: return .busy
        case .timedOut: return .timedOut
        }
    }

    /// How long Home waits before asking again where the folder it shows is, after a "not now" (`shownFolderPlace`).
    public static let coverResolveRetry: Duration = .milliseconds(500)
    /// How many times Home asks where a folder on a local volume is before it gives up on the catalog for it. The mount
    /// table calls a symlink into a share local, so its resolve can hang on that share: past these time outs its covers
    /// go as a share's (`.unknown(network: true)`, the share lane's time limit and one listing at a time), and nothing
    /// more waits in the local resolving lane for it. As many tries finding the lane full (another folder's resolves
    /// hung in it) and it goes on as a local folder without the catalog (`.unknown(network: false)`).
    public static let coverLocalResolveTries = 3

    /// Where the catalog keeps the files of `folder`, the folder Home shows, for its cards' covers: `folderLocation`,
    /// asked again after `retry` while it says "not now". A share is asked for as long as the task lasts (Home cancels
    /// it when it leaves the folder). A local volume is asked until `coverLocalResolveTries` resolves time out (then
    /// `.unknown(network: true)`) or as many tries find its lane full (then `.unknown(network: false)`). `.notNow` only
    /// once cancelled.
    public func shownFolderPlace(_ folder: URL, retry: Duration = coverResolveRetry) async -> CoverPlace {
        let network = coverVolumeIsNetwork(folder)
        var timeouts = 0, busy = 0
        while !Task.isCancelled {
            switch await resolveFolder(folder) {
            case .place(let place): return place
            case .timedOut:
                timeouts += 1
                if !network, timeouts >= Self.coverLocalResolveTries { return .unknown(network: true) }
            case .busy:
                busy += 1
                if !network, busy >= Self.coverLocalResolveTries { return .unknown(network: false) }
            }
            guard (try? await Task.sleep(for: retry)) != nil else { break }
        }
        return .notNow
    }

    /// Whether `url` is on a share, from the mount table the system keeps (`getfsstat` with `MNT_NOWAIT` asks no file
    /// system, so it never hangs): the mount point above its path, as written (a symlink to a share counts as local,
    /// which only costs it the local lane's time limit). True when no mount point matches.
    @Sendable static func mountIsNetwork(_ url: URL) -> Bool {
        !(mount(of: url.standardizedFileURL.path, in: mounts())?.local ?? false)
    }

    /// The share `url` is on, as the mount table names it, in the catalog's form (`ThumbnailLocation.volume`,
    /// `net:<share address>`): the same while the share is mounted again elsewhere. Nil on a local volume, or when no
    /// mount point matches. Never hangs (`mountIsNetwork`).
    @Sendable public static func networkVolume(_ url: URL) -> String? {
        networkVolume(of: url.standardizedFileURL.path, in: mounts())
    }

    /// A mounted file system as the mount table gives it: where, from what, and whether it is local.
    struct Mount {
        var point: String
        var from: String
        var local: Bool
    }

    /// `networkVolume`'s pure part: the share of `path` among `mounts`.
    static func networkVolume(of path: String, in mounts: [Mount]) -> String? {
        guard let mount = mount(of: path, in: mounts), !mount.local else { return nil }
        return ThumbnailLocation.volumeKey(mountPoint: mount.point, mountFrom: mount.from, isLocal: false,
                                           volumeUUID: nil)
    }

    /// The mount point above `path`, as written: the longest that holds it.
    static func mount(of path: String, in mounts: [Mount]) -> Mount? {
        var best: Mount?
        for mount in mounts where path == mount.point || path.hasPrefix(mount.point == "/" ? "/" : mount.point + "/") {
            if mount.point.count > best?.point.count ?? -1 { best = mount }
        }
        return best
    }

    /// The mount table (`MNT_NOWAIT`: no file system asked).
    static func mounts() -> [Mount] {
        let room = getfsstat(nil, 0, MNT_NOWAIT)
        guard room > 0 else { return [] }
        let blank = statfs()
        var table = Array(repeating: blank, count: Int(room) + 4)
        let count = table.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        return (0..<max(0, Int(count))).map { index in
            Mount(point: ThumbnailLocation.string(from: &table[index].f_mntonname),
                  from: ThumbnailLocation.string(from: &table[index].f_mntfromname),
                  local: table[index].f_flags & UInt32(MNT_LOCAL) != 0)
        }
    }

    /// The pictures of a folder's or zip's card (`folderCard`'s), for callers that show no summary. Nil for "not now",
    /// as `folderCard`'s, and also for an offline card without pictures that is still being tried (its folder's third
    /// time out gives it up for the session: empty).
    public func folderCover(_ folder: URL, archive: Bool, in location: ThumbnailLocation?, network: Bool? = nil,
                            maxPixel: Int, lastViewed: String? = nil, modified: Date? = nil) async -> [CGImage]? {
        guard let card = await folderCard(folder, archive: archive, in: location, network: network, maxPixel: maxPixel,
                                          lastViewed: lastViewed, modified: modified) else { return nil }
        if card.problem == .offline, card.images.isEmpty, !emptyCovers.contains(Self.memoKey(folder, modified)) {
            return nil
        }
        return card.images
    }

    /// A folder's or zip's card: its pictures (up to four photos spread across it, the one last viewed there first),
    /// decoded to fill cells of `maxPixel` (`decodeFillCell`: the short side covers it, up to the thumbnail's own
    /// size), and its summary (folder cards spec, "Сводка папки"). `location` is where
    /// the catalog keeps the folder's files (from the folder Home shows: `folderLocation(shown)`'s `.subfolder(name)`;
    /// nil: none). `network` says whether it is on a share when there is no location (`CoverPlace.unknown`); nil: from
    /// the location, or from the mount table without one. `modified` is the folder's (or zip's) date as its parent's
    /// listing gave it.
    ///
    /// Four of the folder's photos in the catalog (every one of a folder whose stored summary counts fewer:
    /// `catalogCount`), or the pick of this session's complete listing, are its pictures, at once, without a listing.
    /// A summary in the catalog made at that date needs none either; else the card goes
    /// out with `summaryPending` and the next call for the folder lists it (limited to `coverListingTimeout` on a
    /// share, `coverLocalListingTimeout` elsewhere), until a listing answers, once a session (`summaryFollowUp`; while
    /// its share is offline only a call that may take the share's probe of `coverOfflineProbeInterval` lists): with
    /// stat on a local volume (the summary with dates and size), names only on a share (counts; the dates and size of
    /// a summary kept from a visit stay), a zip's directory read once. A listing that does not end (time out, lane
    /// full, part only) or fails keeps the stored summary. Without pictures from the catalog the listing's picks are
    /// made into thumbnails and kept in the catalog, like `cover`'s; a folder without photos shows one of each of its
    /// first four subfolders' (two levels down at most).
    ///
    /// Empty pictures when there is nothing to show; then the folder is not listed again this session: found empty, not
    /// listable, or listed `coverTimeoutsAllowed` times without a name in time (those given up while their share did
    /// not answer are tried again when it comes back). A malformed zip is `.broken`; a card on a share that is offline
    /// (`coverOfflineTimeouts` listings on it in a row without a name in time or with an I/O error, or its volume
    /// gone) is `.offline` until anything on it answers (`volumeAnswered`; the app hears it). Nil for "not now": no
    /// pictures yet and its lane full of hung calls, or its listing gave no name in time (on a share that is not
    /// offline). Nothing here asks the system but the listing. New thumbnails wait while the viewer is busy;
    /// cancelling the task stops the listing and the reads.
    public func folderCard(_ folder: URL, archive: Bool, in location: ThumbnailLocation?, network: Bool? = nil,
                           maxPixel: Int, lastViewed: String? = nil, modified: Date? = nil) async -> FolderCard? {
        // Without a location, a share as the mount table says (which never hangs).
        let network = network ?? location?.isNetwork ?? coverVolumeIsNetwork(folder)
        let key = Self.memoKey(folder, modified)
        let volume = network ? volumeKey(folder, location) : nil
        let stored = location.flatMap { storedSummary(at: $0) }
        let fresh = stored.map { $0.folderModified != nil && $0.folderModified == modified } ?? false
        let wantsSummary = !fresh && !summaryTried.contains(key)
        let place = CardPlace(folder: folder, archive: archive, network: network, key: key, volume: volume,
                              modified: modified, maxPixel: maxPixel)
        // The catalog's four (or all of a smaller folder's): the pictures at once, whatever becomes of the summary's
        // listing.
        if let location, let cells = await catalogCells(location, count: Self.catalogCount(stored),
                                                        lastViewed: lastViewed, maxPixel: maxPixel) {
            return await summaryFollowUp(cells.images, place, location: location, stored: stored, wants: wantsSummary,
                                         pictured: cells.names, lastViewed: lastViewed)
        }
        if emptyCovers.contains(key) {
            return FolderCard(images: [], summary: stored, problem: isOffline(volume) ? .offline : coverProblems[key])
        }
        // The pick of this session's complete listing: the pictures from the catalog, the summary as the catalog's
        // four have theirs (a listing of its own, which a share away does not spend).
        if let location {
            switch await pickedCover(folder, key: key, location: location, network: network, volume: volume,
                                     maxPixel: maxPixel, lastViewed: lastViewed, modified: modified,
                                     count: Self.coverPhotos, depth: 0) {
            case .images(let images):
                return await summaryFollowUp(images, place, location: location, stored: stored, wants: wantsSummary)
            case .notNow:
                guard isOffline(volume) else { return nil }
                return FolderCard(images: [], summary: stored, problem: .offline)
            case .none:
                break
            }
        }
        guard let made = await folderCover(folder, archive: archive, location: location, network: network,
                                           volume: volume, maxPixel: maxPixel, lastViewed: lastViewed,
                                           modified: modified, count: Self.coverPhotos, depth: 0, checked: true,
                                           probe: wantsSummary && probeDue(volume)) else {
            // On a share that is offline the card says so, pictures or not.
            guard isOffline(volume) else { return nil }
            return FolderCard(images: [], summary: stored, problem: .offline)
        }
        if made.listed, !Task.isCancelled { noteSummaryTried(key) }
        return card(made.images, listing: made.listing, problem: isOffline(volume) ? .offline : made.problem,
                    modified: modified, location: location, folder: archive ? nil : folder)
    }

    /// How many of a folder's photos the catalog must have for its card's pictures to come from there, without a
    /// listing: four, or every photo of a folder whose stored summary counts fewer (however old the summary: the
    /// catalog's four are as old). Without it a folder of one or three photos was listed for its pictures whenever its
    /// remembered pick no longer served (another photo last viewed there, the folder's date not yet known), and a
    /// listing that failed on a busy share gave the card up for the session (`emptyCovers`, which a smaller folder met
    /// before its catalog): the cover vanished though the catalog had it.
    nonisolated static func catalogCount(_ stored: FolderSummary?) -> Int {
        guard let photos = stored?.photos, photos > 0 else { return coverPhotos }
        return min(coverPhotos, photos)
    }

    /// A card's folder as `folderCard` was asked for it, for the summary's follow-up.
    private struct CardPlace {
        var folder: URL
        var archive: Bool
        var network: Bool
        var key: String
        var volume: String?
        var modified: Date?
        var maxPixel = 0
    }

    /// A card whose pictures came without a listing (the catalog's four, a remembered pick) and its summary: the
    /// stored one when fresh or tried; else pending, and the next call lists the folder for it (R6c). Only an answer
    /// spends the session's try: a complete or partial listing, or a failure that is not the share's (no such file,
    /// no permission, a malformed zip). A listing that does not answer (no name in time, its lane full, a connection
    /// error, the share's volume gone, the probe's turn taken), or a card that left meanwhile, keeps the summary due:
    /// pending, and the queue asks again at its pace (its retry delay growing to a minute); while the share is
    /// offline only a call that may take its probe (`coverOfflineProbeInterval`) lists.
    ///
    /// `pictured`: the catalog's names the pictures are of. A complete listing that lacks one (deleted or renamed
    /// since its thumbnail was made, which the catalog cannot tell) gives the card the listing's pick instead.
    private func summaryFollowUp(_ images: [CGImage], _ place: CardPlace, location: ThumbnailLocation,
                                 stored: FolderSummary?, wants: Bool, pictured: [String] = [],
                                 lastViewed: String? = nil) async -> FolderCard {
        let key = place.key, volume = place.volume
        func pending() -> FolderCard {
            FolderCard(images: images, summary: storedSummary(at: location),
                       problem: isOffline(volume) ? .offline : coverProblems[key], summaryPending: true)
        }
        guard wants else {
            summaryDue.remove(key)
            return FolderCard(images: images, summary: stored,
                              problem: isOffline(volume) ? .offline : coverProblems[key])
        }
        // Listed on a call of its own, the one after this (`summaryPending`).
        guard summaryDue.contains(key) else {
            noteSummaryDue(key)
            return pending()
        }
        guard !Task.isCancelled, probeDue(volume) else { return pending() }
        summaryDue.remove(key)
        let result = await coverListing(place.folder, archive: place.archive, network: place.network, key: key,
                                        volume: volume, alias: location.volume, forSummary: true, probe: true)
        let listing: CoverListing?, answered: Bool
        switch result {
        case .listed(let listed, let complete): (listing, answered) = (complete ? listed : nil, true)
        case .settled: (listing, answered) = (nil, !isOffline(volume))
        case .notNow: (listing, answered) = (nil, false)
        }
        guard answered, !Task.isCancelled else {
            noteSummaryDue(key)
            return pending()
        }
        noteSummaryTried(key)
        var images = images
        if let listing, !Set(pictured).isSubset(of: Set(listing.names.files)), !Task.isCancelled,
           let made = await pictures(of: listing, place.folder, location: location, network: place.network,
                                     volume: volume, maxPixel: place.maxPixel, lastViewed: lastViewed,
                                     modified: place.modified, count: Self.coverPhotos, depth: 0, complete: true) {
            images = made
        }
        return card(images, listing: listing, problem: isOffline(volume) ? .offline : coverProblems[key],
                    modified: place.modified, location: location, folder: place.archive ? nil : place.folder)
    }

    /// What a remembered pick gave (`pickedCover`).
    private enum PickedCover {
        /// No pick, or one of its thumbnails left the catalog: listed again.
        case none
        case images([CGImage])
        /// A subfolder's cover not now, or cancelled.
        case notNow
    }

    /// The pictures of the folder's pick from this session's complete listing (`coverPicks`), from the catalog: no
    /// listing of the folder (its subfolders' covers may list them).
    private func pickedCover(_ folder: URL, key: String, location: ThumbnailLocation, network: Bool, volume: String?,
                             maxPixel: Int, lastViewed: String?, modified: Date?, count: Int,
                             depth: Int) async -> PickedCover {
        guard let pick = coverPick(key, lastViewed: lastViewed) else { return .none }
        switch pick {
        case .photos(let names):
            if let images = await knownCells(folder, names.prefix(count), at: location, maxPixel: maxPixel) {
                return .images(images)
            }
            guard !Task.isCancelled else { return .notNow }
            coverPicks[key] = nil   // a thumbnail left the catalog: listed again
            return .none
        case .subfolders(let names):
            guard let images = await subfolderCover(folder, names, location: location, network: network,
                                                    volume: volume, maxPixel: maxPixel, count: count, depth: depth,
                                                    complete: true, modified: modified) else { return .notNow }
            return .images(images)
        }
    }

    /// The card with a complete listing's summary, queued for the catalog when it changed, or the stored one. The
    /// stored summary is read again here: one written while the listing ran (the folder opened meanwhile, with dates)
    /// is what a names-only count keeps the dates of. A folder's (not a zip's) subfolders are remembered for the work
    /// ahead (`subfolderNames`).
    func card(_ images: [CGImage], listing: CoverListing?, problem: CardProblem?, modified: Date?,
                      location: ThumbnailLocation?, folder: URL?) -> FolderCard {
        let stored = location.flatMap { storedSummary(at: $0) }
        guard let listing else { return FolderCard(images: images, summary: stored, problem: problem) }
        if let folder { rememberSubfolders(of: folder, listing) }
        var summary = Self.summary(of: listing, modified: modified, stored: stored)
        var written = false
        if let location {
            if let write = Self.summaryToStore(summary, stored: stored) {
                queueSummary(write, at: location)
                written = true
            } else if let stored {
                summary = stored   // the same facts: the stored one keeps its folder date
            }
        }
        return FolderCard(images: images, summary: summary, problem: problem, photoDates: listing.photoDates,
                          summaryWritten: written)
    }

    /// Listings on a share in a row without a name in time (or with an I/O error) before the share is offline: every
    /// card on it says so, and none is listed for its summary until anything on it answers (`noteVolumeAnswered`) but
    /// for a probe every `coverOfflineProbeInterval`.
    static let coverOfflineTimeouts = 2
    /// How often an offline share's cards may probe it with a summary's listing: one listing on it per this, so a
    /// share that came back is found again within it while a dead one costs a thread per this at most (the share's
    /// listing time limit is 2 s of 30).
    public static let coverOfflineProbeInterval: Duration = .seconds(30)
    /// Shares whose offline state is kept at most (then forgotten at once): a few are mounted at a time.
    static let coverVolumeLimit = 64

    /// What a cover pass made: its pictures, the folder's complete listing when it made one (`folderCard`'s summary;
    /// only at the top, not a subfolder's), whether a listing ran to some end (`folderCard` does not list again for
    /// the summary), and what the card has against it.
    struct CoverMade {
        var images: [CGImage]
        var listing: CoverListing?
        var listed = false
        var problem: CardProblem?
    }

    /// What a listing of a cover came to (`coverListing`).
    enum CoverListingResult {
        /// All of it, or what came before its time limit.
        case listed(CoverListing, complete: Bool)
        /// It failed: nothing to show for the session (but for the summary's listing), and what the card has against it.
        case settled(CardProblem?)
        /// Its lane full, or no name in time: ask again later.
        case notNow
    }

    /// Lists `folder` in its lane, with its time limit, and keeps the session's notes of how it went: a share's time
    /// outs and I/O errors in a row towards offline (`coverOfflineTimeouts`), cleared by any listing on it that
    /// answers; a share's volume gone makes it offline; a malformed zip is broken. `forSummary`: the pictures came from
    /// the catalog, so a failure or a time out leaves the folder's own notes (empty for the session, time outs)
    /// alone.
    func coverListing(_ folder: URL, archive: Bool, network: Bool, key: String, volume: String?,
                              alias: String?, forSummary: Bool, probe: Bool = false) async -> CoverListingResult {
        let lister = coverLister, dated = !network
        var turn: ProbeTurn?
        if probe {
            guard let taken = takeProbeTurn(volume) else { return .notNow }
            turn = taken
        }
        let outcome = await Self.onThread(coverThreads, lane: CoverLane(network: network, resolving: false),
                                          timeout: network ? coverNetworkTimeout : coverLocalTimeout) {
            part in try lister(folder, archive, dated, part)
        }
        if case .busy = outcome { giveBack(turn, volume) }
        func timedOut() -> CoverListingResult {
            noteVolumeTimeout(volume)
            guard !forSummary else { return .notNow }
            noteAway(key, on: volume)
            coverTimeouts[key, default: 0] += 1
            guard coverTimeouts[key, default: 0] >= Self.coverTimeoutsAllowed else { return .notNow }
            coverTimeouts[key] = nil
            emptyCovers.insert(key)
            return .settled(nil)
        }
        switch outcome {
        case .value(let listed, let complete):
            noteVolumeAnswered(volume, alias: alias)
            if !forSummary { coverTimeouts[key] = nil }
            setProblem(nil, for: key)
            return .listed(listed, complete: complete)
        case .failed(let error):
            if network, !coverVolumeIsNetwork(folder) {
                // The mount table no longer puts the path on a share: its volume is gone.
                markVolumeOffline(volume)
                if !forSummary { noteAway(key, on: volume) }
            } else if network, Self.isConnectionError(error) {
                return timedOut()
            } else {
                // No such file, no permission, a malformed zip: the share answered.
                noteVolumeAnswered(volume, alias: alias)
            }
            let problem: CardProblem? = error is ArchiveError ? .broken : nil
            setProblem(problem, for: key)
            if !forSummary { emptyCovers.insert(key) }
            return .settled(problem)
        case .busy:
            return .notNow
        case .timedOut:
            return timedOut()
        }
    }

    /// An offline share's probe turn as a call took it: when, and the share's mark before.
    struct ProbeTurn {
        var taken: ContinuousClock.Instant
        var before: ContinuousClock.Instant
    }

    /// An offline share's probe takes its turn as its call starts: nil (not now) when the turn is not due (another
    /// card took it within `coverProbeInterval`); a turn without a mark when the share is not offline.
    func takeProbeTurn(_ volume: String?) -> ProbeTurn?? {
        guard let volume, let since = offlineVolumes[volume] else { return .some(nil) }
        let now = ContinuousClock.now
        guard now - since >= coverProbeInterval else { return nil }
        offlineVolumes[volume] = now
        return .some(ProbeTurn(taken: now, before: since))
    }

    /// The turn given back when its call did not start (the lane full, the task cancelled).
    func giveBack(_ turn: ProbeTurn??, _ volume: String?) {
        if let turn = turn ?? nil, let volume, offlineVolumes[volume] == turn.taken { offlineVolumes[volume] = turn.before }
    }

    /// An error of a share's connection rather than of the folder (gone, no permission): it counts as a time out.
    nonisolated static func isConnectionError(_ error: Error) -> Bool {
        let code: Int32?
        if let posix = error as? POSIXError {
            code = posix.code.rawValue
        } else {
            let ns = error as NSError
            code = ns.domain == NSPOSIXErrorDomain ? Int32(ns.code)
                : (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
        }
        guard let code else { return false }
        return [EIO, ENOTCONN, ETIMEDOUT, ENETDOWN, ENETUNREACH, ENETRESET, ECONNRESET, ECONNABORTED, EHOSTDOWN,
                EHOSTUNREACH, ESTALE].contains(code)
    }

    /// The key of a share's card's volume for its offline state: the share as the mount table names it
    /// (`networkVolume`, the catalog's form), the same for the cards with a location and without and across a mount
    /// again; else (a share gone from the mount table, a symlink into one) the catalog's volume; nil when neither is
    /// known.
    func volumeKey(_ folder: URL, _ location: ThumbnailLocation?) -> String? {
        coverNetworkVolume(folder) ?? location?.volume
    }

    /// Tests: the share a path is on (`networkVolume`), instead of the mount table.
    func setCoverNetworkVolumes(_ volume: @escaping @Sendable (URL) -> String?) {
        coverNetworkVolume = volume
    }

    /// Told the key (`volumeKey`) of a share that was offline and answered: the app asks again for that share's
    /// cards it shows dimmed (`CoverQueue.forget`), those done with a fresh summary too (`cardIsOn` says which).
    /// Called on the store's actor, once per coming back.
    public func setOnVolumeAnswered(_ handler: @escaping @Sendable (String) -> Void) {
        onVolumeAnswered = handler
    }

    /// Whether a card is on the share `volume` that answered (`setOnVolumeAnswered`): its catalog volume (`location`,
    /// as `folderCard` was given it) or, without one, its share (`share`: `networkVolume` of its folder, or of the
    /// folder Home shows; nil off a share) is that key.
    public nonisolated static func cardIsOn(_ volume: String, location: ThumbnailLocation?, share: String?) -> Bool {
        location?.volume == volume || share == volume
    }

    /// Tests: how often an offline share may be probed.
    func setCoverProbeInterval(_ interval: Duration) {
        coverProbeInterval = interval
    }

    /// Something on the share of `folder` answered (the browser's own listing of it, say): it is not offline, and its
    /// time outs in a row start again. `location`: where the catalog keeps `folder`'s files, as for its cards (nil:
    /// the mount table's share).
    public func volumeAnswered(_ folder: URL, in location: ThumbnailLocation?) {
        noteVolumeAnswered(volumeKey(folder, location), alias: location?.volume)
    }

    func isOffline(_ volume: String?) -> Bool {
        volume.map { offlineVolumes[$0] != nil } ?? false
    }

    /// Whether a card on `volume` may be listed for its summary: always unless the share is offline, then once per
    /// `coverProbeInterval`. Only asking: the listing takes the turn as it starts (`coverListing`'s `probe`).
    private func probeDue(_ volume: String?) -> Bool {
        guard let volume, let since = offlineVolumes[volume] else { return true }
        return ContinuousClock.now - since >= coverProbeInterval
    }

    func noteVolumeTimeout(_ volume: String?) {
        guard let volume else { return }
        if coverVolumeTimeouts.count >= Self.coverVolumeLimit { coverVolumeTimeouts.removeAll() }
        coverVolumeTimeouts[volume, default: 0] += 1
        if coverVolumeTimeouts[volume, default: 0] >= Self.coverOfflineTimeouts { markVolumeOffline(volume) }
    }

    func markVolumeOffline(_ volume: String?) {
        guard let volume else { return }
        if offlineVolumes.count >= Self.coverVolumeLimit {
            // Forgotten, so no longer offline: their dimmed cards are asked for again, as when they answer.
            let forgotten = offlineVolumes.keys
            offlineVolumes.removeAll()
            for key in forgotten where key != volume { shareCameBack(key) }
        }
        offlineVolumes[volume] = .now
    }

    /// The share answered: under its key, and under its catalog volume (`alias`) where a card on it without the mount
    /// table's share is keyed (a symlink into it, its mount gone). A share that was offline is told of
    /// (`onVolumeAnswered`), once. One that was not, but has folders noted away on it (time outs while it answered
    /// other listings), forgives them too: their time outs in a row start again, and one already given up is tried
    /// again (the app told, so it asks for the card) — a busy share's slow folder is not lost for the session. A folder
    /// that always hangs on a share that keeps answering is so retried at the cover queue's pace (its retry delay
    /// growing to a minute), not given up.
    func noteVolumeAnswered(_ volume: String?, alias: String? = nil) {
        for key in [volume, alias].compactMap({ $0 }) {
            coverVolumeTimeouts[key] = nil
            if offlineVolumes.removeValue(forKey: key) != nil {
                shareCameBack(key)
            } else if awayFolders.values.contains(key), forgiveAway(on: key) {
                onVolumeAnswered?(key)
            }
        }
    }

    /// Clears the away notes of the folders on `volume` (their time outs and their give-up for the session); true
    /// when one of them had been given up.
    private func forgiveAway(on volume: String) -> Bool {
        var givenUp = false
        for (key, on) in awayFolders where on == volume {
            if emptyCovers.remove(key) != nil { givenUp = true }
            coverTimeouts[key] = nil
            awayFolders[key] = nil
        }
        return givenUp
    }

    /// The folder `key` was given up (or is on its way: time outs) because its share `volume` did not answer: tried
    /// again when the share comes back.
    private func noteAway(_ key: String, on volume: String?) {
        guard let volume else { return }
        if awayFolders.count >= Self.coverPickLimit { awayFolders.removeAll() }
        awayFolders[key] = volume
    }

    /// An offline share is back (or forgotten): its folders given up while it was away are tried again, and the app
    /// is told (`onVolumeAnswered`), so it asks for their cards again.
    private func shareCameBack(_ volume: String) {
        _ = forgiveAway(on: volume)
        onVolumeAnswered?(volume)
    }

    /// The folder's card went out with `summaryPending`: its next call lists it.
    private func noteSummaryDue(_ key: String) {
        if summaryDue.count >= Self.coverPickLimit { summaryDue.removeAll() }
        summaryDue.insert(key)
    }

    /// The folder was listed for its summary this session (at this date): not again, whatever came of it.
    func noteSummaryTried(_ key: String) {
        if summaryTried.count >= Self.coverPickLimit { summaryTried.removeAll() }
        summaryTried.insert(key)
    }

    /// `volume`: the card's share key (`volumeKey`, nil off a share), asked once per card. `checked`: the caller
    /// found fewer than `count` photos of the folder in the catalog and no remembered pick. `probe`: the listing is
    /// an offline share's probe (`coverListing`).
    private func folderCover(_ folder: URL, archive: Bool, location: ThumbnailLocation?, network: Bool, volume: String?,
                             maxPixel: Int, lastViewed: String?, modified: Date?, count: Int, depth: Int,
                             checked: Bool = false, probe: Bool = false) async -> CoverMade? {
        let key = Self.memoKey(folder, modified)
        guard !emptyCovers.contains(key) else { return CoverMade(images: [], problem: coverProblems[key]) }
        guard !Task.isCancelled else { return nil }
        if !checked, let location {
            if let cells = await catalogCells(location, count: count, lastViewed: lastViewed, maxPixel: maxPixel) {
                return CoverMade(images: cells.images)
            }
            switch await pickedCover(folder, key: key, location: location, network: network, volume: volume,
                                     maxPixel: maxPixel, lastViewed: lastViewed, modified: modified, count: count,
                                     depth: depth) {
            case .images(let images): return CoverMade(images: images)
            case .notNow: return nil
            case .none: break
            }
        }
        let listed: CoverListing, complete: Bool
        switch await coverListing(folder, archive: archive, network: network, key: key, volume: volume,
                                  alias: location?.volume, forSummary: false, probe: probe) {
        case .listed(let value, let ended): (listed, complete) = (value, ended)
        case .settled(let problem): return CoverMade(images: [], listed: true, problem: problem)
        case .notNow: return nil
        }
        let summarized = complete && depth == 0 ? listed : nil
        guard let images = await pictures(of: listed, folder, location: location, network: network, volume: volume,
                                          maxPixel: maxPixel, lastViewed: lastViewed, modified: modified, count: count,
                                          depth: depth, complete: complete) else { return nil }
        return CoverMade(images: images, listing: summarized, listed: true)
    }

    /// The pictures of a listing's pick (remembered for the folder when the listing is complete): its photos made
    /// into thumbnails (or read from the catalog), else one of each of its first subfolders'; none for an empty
    /// folder (given up for the session when complete). Nil: a subfolder's cover not now.
    private func pictures(of listed: CoverListing, _ folder: URL, location: ThumbnailLocation?, network: Bool,
                          volume: String?, maxPixel: Int, lastViewed: String?, modified: Date?, count: Int, depth: Int,
                          complete: Bool) async -> [CGImage]? {
        let key = Self.memoKey(folder, modified)
        let names = listed.names
        let plan = await Self.offActor(qos: Self.coverQoS) {
            CoverSampling.plan(names: Self.finderSorted(names.files), directories: Self.finderSorted(names.folders),
                               lastViewed: lastViewed)
        }
        if complete, location != nil {
            switch plan {
            case .photos(let picked): remember(.photos(Array(picked)), for: key, lastViewed: lastViewed)
            case .subfolders(let subfolders): remember(.subfolders(Array(subfolders)), for: key, lastViewed: lastViewed)
            case .empty: break
            }
        }
        switch plan {
        case .photos(let picked):
            var images: [CGImage] = []
            for name in picked.prefix(count) {
                guard await idleViewer() else { break }
                if let image = await coverCell(folder.appendingPathComponent(name), at: location?.sibling(name),
                                               maxPixel: maxPixel) {
                    images.append(image)
                }
            }
            return images
        case .subfolders(let subfolders):
            return await subfolderCover(folder, Array(subfolders), location: location, network: network, volume: volume,
                                        maxPixel: maxPixel, count: count, depth: depth, complete: complete,
                                        modified: modified)
        case .empty:
            if complete { emptyCovers.insert(key) }
            return []
        }
    }

    /// `count` photos of the folder at `location` with a thumbnail in the catalog, spread across them as Finder sorts
    /// them, the one last viewed first, decoded, and their names; nil when there are fewer.
    private func catalogCells(_ location: ThumbnailLocation, count: Int, lastViewed: String?,
                              maxPixel: Int) async -> (images: [CGImage], names: [String])? {
        guard let names = perform("cover", { try $0.namesWithThumbnails(in: location, limit: .max) }),
              names.count >= count else { return nil }
        // Sorting thousands of names takes a while: not on the actor.
        let picked = await Self.offActor(qos: Self.coverQoS) {
            CoverSampling.pick(Self.finderSorted(names), count: count, lastViewed: lastViewed)
        }
        var images: [CGImage] = []
        for name in picked where !Task.isCancelled {
            if let image = await storedCell(at: location.sibling(name), maxPixel: maxPixel) { images.append(image) }
        }
        return (images, Array(picked))
    }

    /// Notes (or, nil, clears) what a folder's card has against it, keeping the notes bounded.
    private func setProblem(_ problem: CardProblem?, for key: String) {
        guard let problem else {
            coverProblems[key] = nil
            return
        }
        if coverProblems.count >= Self.coverPickLimit { coverProblems.removeAll() }
        coverProblems[key] = problem
    }

    /// A folder without photos of its own: one picture of each of its first subfolders with one (`count` at most).
    private func subfolderCover(_ folder: URL, _ subfolders: [String], location: ThumbnailLocation?, network: Bool,
                                volume: String?, maxPixel: Int, count: Int, depth: Int, complete: Bool,
                                modified: Date?) async -> [CGImage]? {
        guard depth < Self.coverDepth else { return [] }
        var images: [CGImage] = [], notNow = false
        for name in subfolders where images.count < count && !Task.isCancelled {
            // One picture of each: the subfolder's own card makes the rest when it is shown.
            let sub = await folderCover(folder.appendingPathComponent(name, isDirectory: true), archive: false,
                                        location: location?.subfolder(name), network: network, volume: volume,
                                        maxPixel: maxPixel, lastViewed: nil, modified: nil, count: 1, depth: depth + 1)
            if let sub { images += sub.images.prefix(1) } else { notNow = true }
        }
        if notNow, images.count < count { return nil }
        let keys = subfolders.map { Self.memoKey(folder.appendingPathComponent($0), nil) }
        if complete, keys.allSatisfy(emptyCovers.contains) {
            let key = Self.memoKey(folder, modified)
            emptyCovers.insert(key)
            // Given up with a subfolder its share did not answer for (or while it is offline): tried again with them
            // when the share comes back.
            if isOffline(volume) || keys.contains(where: { awayFolders[$0] != nil }) { noteAway(key, on: volume) }
        }
        return images
    }

    /// The key of a folder's session memos (`emptyCovers`, `coverPicks`): its path and the modification date its
    /// listing entry gave, so a folder filled or emptied in the Finder is looked at again. Nil where the caller has
    /// no date (a subfolder looked into).
    static func memoKey(_ folder: URL, _ modified: Date?) -> String {
        let path = folder.standardizedFileURL.path
        guard let modified else { return path }
        return path + "\u{0}" + String(modified.timeIntervalSinceReferenceDate)
    }

    /// The names of `folder`'s direct subfolders, in Finder order, for the work ahead (thumbs-ahead spec, stage 4),
    /// never from a new listing: those of its card's complete listing this session, else the catalog's (the stored
    /// summaries of its subfolders, at `location`'s, when there are as many as its own stored summary counts:
    /// `childSummaries`' query). Nil when neither knows them all, and for a folder of more than
    /// `coverSubfoldersPerFolder` (a card with more prepares none ahead).
    public func subfolderNames(of folder: URL, in location: ThumbnailLocation?) async -> [String]? {
        let path = folder.standardizedFileURL.path
        if let known = coverSubfolders[path] {
            coverSubfolderUses += 1
            coverSubfolders[path]?.use = coverSubfolderUses
            return Self.finderSorted(known.names)
        }
        guard let location, let stored = storedSummary(at: location) else { return nil }
        guard stored.folders > 0 else { return [] }
        // More than a card prepares ahead (as a listing's are not remembered: `rememberSubfolders`).
        guard stored.folders <= Self.coverSubfoldersPerFolder else { return nil }
        let children = childSummaryPhotos(of: location)
        // A deleted subfolder's leftover row can make the counts match without a new one's (accepted: that one waits
        // for its parent's listing).
        guard children.count == stored.folders else { return nil }
        return Self.finderSorted(children.keys.map { ($0 as NSString).lastPathComponent })
    }

    /// The modification date the work ahead makes a subfolder's card at (`folderCard`'s `modified`, which a stored
    /// summary must match to be fresh): its parent's dated listing's this session, else one stat of the subfolder
    /// itself (nothing inside it), in the covers' listing lane of its volume (a share's or the local volumes') with
    /// that lane's time limit. `.notNow` when the lane is full or the stat does not answer in time. On a share it
    /// keeps to the share's gate as a listing does (`coverListing`): while the share is offline no stat but its probe
    /// turn's (`coverProbeInterval`), else `.notNow`; a time out or a connection error counts towards offline, an
    /// answer brings the share back. Called from the cover queue's work, never on the main thread.
    public func subfolderModified(_ subfolder: URL, in location: ThumbnailLocation?) async -> SubfolderDate {
        let url = subfolder.standardizedFileURL
        if let date = coverSubfolders[url.deletingLastPathComponent().path]?.dates[url.lastPathComponent] {
            return .known(date)
        }
        let stat = coverStat, network = location?.isNetwork ?? coverVolumeIsNetwork(url)
        let volume = network ? volumeKey(url, location) : nil
        guard let turn = takeProbeTurn(volume) else { return .notNow }
        let outcome = await Self.onThread(coverThreads, lane: CoverLane(network: network, resolving: false),
                                          timeout: network ? coverNetworkTimeout : coverLocalTimeout) {
            (_: @Sendable (Date?) -> Bool) -> Date? in
            try stat(url)
        }
        switch outcome {
        case .value(let date, _):
            noteVolumeAnswered(volume, alias: location?.volume)
            return .known(date)
        case .failed(let error):
            if network, !coverVolumeIsNetwork(url) {
                markVolumeOffline(volume)   // the mount table no longer puts it on a share: its volume is gone
                return .notNow
            }
            if network, Self.isConnectionError(error) {
                noteVolumeTimeout(volume)
                return .notNow
            }
            noteVolumeAnswered(volume, alias: location?.volume)   // gone, no permission: the share answered
            return .known(nil)
        case .busy:
            giveBack(turn, volume)
            return .notNow
        case .timedOut:
            noteVolumeTimeout(volume)
            return .notNow
        }
    }

    /// One stat of a folder: its own modification date (a URL of its own, so no cached resource value is used).
    typealias CoverStat = @Sendable (URL) throws -> Date?

    @Sendable static func statFolder(_ folder: URL) throws -> Date? {
        try URL(fileURLWithPath: folder.path, isDirectory: true)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Tests: a fake stat for `subfolderModified`.
    func setCoverStat(_ stat: @escaping CoverStat) {
        coverStat = stat
    }

    /// `folder`'s subfolders from its complete listing, for `subfolderNames`. A folder of more than
    /// `coverSubfoldersPerFolder` is not remembered (its work ahead would be most of a session's); past
    /// `coverSubfolderNameLimit` names in all, the least recently used tenth of the folders goes.
    private func rememberSubfolders(of folder: URL, _ listing: CoverListing) {
        let path = folder.standardizedFileURL.path
        if let old = coverSubfolders.removeValue(forKey: path) { coverSubfolderNames -= old.names.count }
        let names = listing.names.folders
        guard names.count <= Self.coverSubfoldersPerFolder else { return }
        coverSubfolderUses += 1
        coverSubfolders[path] = CoverSubfolders(names: names, dates: listing.folderDates, use: coverSubfolderUses)
        coverSubfolderNames += names.count
        guard coverSubfolderNames > Self.coverSubfolderNameLimit || coverSubfolders.count > Self.coverPickLimit
        else { return }
        let old = coverSubfolders.sorted { $0.value.use < $1.value.use }.prefix(max(1, coverSubfolders.count / 10))
        for (key, kept) in old {
            coverSubfolders[key] = nil
            coverSubfolderNames -= kept.names.count
        }
    }

    /// The pick remembered for `key`; a folder's photos only when made for the same last-viewed photo.
    private func coverPick(_ key: String, lastViewed: String?) -> CoverPick.Kind? {
        guard let pick = coverPicks[key] else { return nil }
        if case .photos = pick.kind, pick.lastViewed != lastViewed { return nil }
        coverPickUses += 1
        coverPicks[key]?.use = coverPickUses
        return pick.kind
    }

    func remember(_ kind: CoverPick.Kind, for key: String, lastViewed: String?) {
        coverPickUses += 1
        coverPicks[key] = CoverPick(kind: kind, lastViewed: lastViewed, use: coverPickUses)
        guard coverPicks.count > Self.coverPickLimit else { return }
        // A tenth at once, the least recently used: one sort per few hundred new folders, not one per folder.
        let old = coverPicks.sorted { $0.value.use < $1.value.use }.prefix(Self.coverPickLimit / 10)
        for (path, _) in old { coverPicks[path] = nil }
    }

    /// The thumbnails of `names` in `folder` from the strip or the catalog; nil when one is in neither.
    private func knownCells(_ folder: URL, _ names: ArraySlice<String>, at location: ThumbnailLocation,
                            maxPixel: Int) async -> [CGImage]? {
        var images: [CGImage] = []
        for name in names {
            guard !Task.isCancelled else { return nil }
            let url = folder.appendingPathComponent(name)
            if ids[url] != nil || made[url] != nil, let cell = await stripCell(url, side: maxPixel) {
                images.append(cell)
            } else if let stored = await storedCell(at: location.sibling(name), maxPixel: maxPixel) {
                images.append(stored)
            } else {
                return nil
            }
        }
        return images
    }

    nonisolated static func finderSorted(_ names: [String]) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Waits while the viewer cache is not idle (the user stepping through photos), so a running cover reads nothing
    /// meanwhile; false once the task is cancelled.
    private func idleViewer() async -> Bool {
        while activity != .idle {
            guard (try? await Task.sleep(for: Self.coverIdlePoll)) != nil else { return false }
        }
        return !Task.isCancelled
    }

    /// The strip's thumbnail of `url` (a window lists its folder) as a cover's cell: decoded to fill (`decodeFillCell`),
    /// not the strip's cell of the long side; nil while it is not made.
    private func stripCell(_ url: URL, side: Int) async -> CGImage? {
        guard let (jpeg, _) = storedThumbnail(url) else { return nil }
        return await Self.offActor(qos: Self.coverQoS) { ThumbnailMaker.decodeFillCell(jpeg, side: side) }
    }

    /// The catalog's thumbnail of the file at `location` as a cell, however old (a card can afford it); nil when it
    /// has none.
    private func storedCell(at location: ThumbnailLocation, maxPixel: Int) async -> CGImage? {
        guard let row = perform("cover", { try $0.file(at: location) }) ?? nil,
              let stored = perform("cover", { try $0.thumbnail(row.id) }) ?? nil else { return nil }
        return await Self.offActor(qos: Self.coverQoS) { ThumbnailMaker.decodeFillCell(stored.jpeg, side: maxPixel) }
    }

    /// One photo of a cover: the strip's thumbnail when a window lists its folder, else the catalog's, else one made
    /// now, behind the open folders' thumbnails, and kept in the catalog.
    private func coverCell(_ url: URL, at location: ThumbnailLocation?, maxPixel: Int) async -> CGImage? {
        if ids[url] != nil || made[url] != nil, let cell = await stripCell(url, side: maxPixel) { return cell }
        if let location, let stored = await storedCell(at: location, maxPixel: maxPixel) { return stored }
        // No stamp is asked for (a stat queues like a read): the read brings the file's, and no viewer bytes are
        // looked up, so the listed stamp is never used.
        let recipe = Recipe(url: url, listedStamp: FileStamp(modified: .distantPast, size: 0), maxSide: thumbSize,
                            reader: reader, decodeLimit: decodeLimit, decoder: decoder, cachedBytes: { _, _ in nil },
                            readEnded: {}, readAgain: {}, rank: Self.coverReadPriority)
        var timing = Timing()
        guard case .made(let jpeg, let info, let stamp) = await Self.generate(recipe, &timing) else { return nil }
        log?("cover \(url.lastPathComponent): read \(Self.ms(timing.read)) ms (\(timing.source)), "
             + "decode \(Self.ms(timing.decode)) ms")
        if let location, perform("cover", { db -> Bool in
            let id = try db.addFile(location, stamp: stamp)
            try db.put([(id, stamp, jpeg, info)])
            return true
        }) == true {
            storedBytes += jpeg.count
            if storedBytes > limitBytes { enforceLimit() }
        }
        return await Self.offActor(qos: Self.coverQoS) { ThumbnailMaker.decodeFillCell(jpeg, side: maxPixel) }
    }

    /// Runs blocking `work` on a thread of its own in a place of `lane` (`threads`), and waits for it at most `timeout`
    /// or until the task is cancelled, then gives up on it: the answer is what `work` handed to its `part` so far, and
    /// `part` returns false from then on so it can stop; the thread keeps its place until it returns. `.busy` when the
    /// lane has no free place (or the task was cancelled with nothing yet), `.timedOut` when nothing came in time.
    static func onThread<T: Sendable>(_ threads: CoverThreads, lane: CoverLane, timeout: Duration,
                                      _ work: @escaping @Sendable (_ part: @escaping @Sendable (T) -> Bool) throws -> T)
        async -> ThreadAnswer<T>.Outcome {
        // A task already cancelled (a card left, a walk ended) starts no blocking call.
        guard !Task.isCancelled, threads.enter(lane) else { return .busy }
        let answer = ThreadAnswer<T>()
        DispatchQueue.global(qos: coverQoS).async {
            let result = Result { try work { answer.part($0) } }
            threads.leave(lane)
            answer.finish(result)
        }
        typealias Race = ThreadAnswer<T>.Race
        return await withTaskGroup(of: Race.self, returning: ThreadAnswer<T>.Outcome.self) { group in
            group.addTask { .answered(await answer.value()) }
            group.addTask {
                // Cancelled (the answer came first, or the caller's task): not a time out.
                guard (try? await Task.sleep(for: timeout)) != nil else { return .answered(.busy) }
                return .timedOut
            }
            // Whichever comes first: the timer stops the work, whose answer is then what it had so far.
            var timedOut = false
            while let first = await group.next() {
                answer.stop()
                group.cancelAll()
                switch first {
                case .timedOut: timedOut = true
                case .answered(.busy): continue   // the cancelled timer, or the work given up on by a cancel
                case .answered(let outcome): return outcome
                }
            }
            return timedOut && !Task.isCancelled ? .timedOut : .busy
        }
    }

    /// The real listing: a folder's names (`BrowserListingSource.names`, as `listCoverNames`), on a local volume
    /// (`dated`) with each photo's date and size from the same pass (no file opened); a zip's photo entries and its
    /// own size and date from one read of its directory.
    @Sendable static func listCover(_ folder: URL, archive: Bool, dated: Bool,
                                    part: @escaping @Sendable (CoverListing) -> Bool) throws -> CoverListing {
        if archive || ArchivePath.isArchive(folder) {
            let (stamp, entries) = try ArchiveReader.shared.listing(of: folder)
            return CoverListing(names: CoverNames(files: entries.map(\.url.lastPathComponent), folders: []),
                                summary: .ofArchive(photos: entries.count, bytes: Int64(stamp.size),
                                                    modified: stamp.modified))
        }
        // Parts every 100 ms at most: what a time limit finds is never older than that.
        return CoverListing(listing: try BrowserListingSource.names(folder, archives: false, stat: dated, partEvery: 64,
                                                                    partAfter: .milliseconds(100)) {
            part(CoverListing(listing: $0, dated: false))
        }, dated: dated)
    }

    /// `listCover`'s names alone, never with stat.
    @Sendable static func listCoverNames(_ folder: URL, archive: Bool,
                                         part: @escaping @Sendable (CoverNames) -> Bool) throws -> CoverNames {
        try listCover(folder, archive: archive, dated: false) { part($0.names) }.names
    }
}

/// One blocking call of a cover on its thread, between the thread and the task waiting for it: what it handed over so
/// far, how it ended, and whether the waiter gave up on it (the thread then stops at its next `part`).
final class ThreadAnswer<T: Sendable>: @unchecked Sendable {
    enum Outcome: Sendable {
        /// All of it (`complete`), or what came before the waiter gave up.
        case value(T, complete: Bool)
        /// It threw, with nothing before.
        case failed(any Error)
        /// No free thread, or given up on (cancelled) with nothing yet.
        case busy
        /// Its time limit ran out with nothing yet.
        case timedOut
    }

    /// What the waiter heard first: the answer, or its time limit.
    enum Race: Sendable {
        case answered(Outcome)
        case timedOut
    }

    private let lock = NSLock()
    private var latest: T?
    private var outcome: Result<T, Error>?
    private var stopped = false
    private var waiter: CheckedContinuation<Outcome, Never>?

    /// From the thread: false once the waiter gave up.
    func part(_ value: T) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            latest = value
            return true
        }
    }

    func finish(_ result: Result<T, Error>) {
        let (waiter, answer) = lock.withLock { () -> (CheckedContinuation<Outcome, Never>?, Outcome) in
            outcome = result
            defer { self.waiter = nil }
            return (self.waiter, answerLocked())
        }
        waiter?.resume(returning: answer)
    }

    /// The waiter gives up: it gets what came so far now.
    func stop() {
        let (waiter, answer) = lock.withLock { () -> (CheckedContinuation<Outcome, Never>?, Outcome) in
            stopped = true
            defer { self.waiter = nil }
            return (self.waiter, answerLocked())
        }
        waiter?.resume(returning: answer)
    }

    /// The outcome once the call ended, else once `stop` was called or the task cancelled.
    func value() async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let answer = lock.withLock { () -> Outcome? in
                    guard outcome != nil || stopped else {
                        waiter = continuation
                        return nil
                    }
                    return answerLocked()
                }
                if let answer { continuation.resume(returning: answer) }
            }
        } onCancel: {
            stop()
        }
    }

    private func answerLocked() -> Outcome {
        if case .success(let value) = outcome { return .value(value, complete: true) }
        if let latest { return .value(latest, complete: false) }
        if !stopped, case .failure(let error) = outcome { return .failed(error) }
        return .busy
    }
}

/// Where a cover's blocking call runs: listings or resolves, on local volumes or on shares. Each has its own threads, so
/// calls hung on a share never take a local volume's, nor a listing's a resolve's.
public struct CoverLane: Hashable, Sendable {
    public var network: Bool
    public var resolving: Bool

    public init(network: Bool, resolving: Bool) {
        self.network = network
        self.resolving = resolving
    }
}

/// Counts the threads in covers' blocking calls, per lane, up to `limit` in each.
final class CoverThreads: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var counts: [CoverLane: Int] = [:]

    init(limit: Int) { self.limit = limit }

    func enter(_ lane: CoverLane) -> Bool {
        lock.withLock {
            guard counts[lane, default: 0] < limit else { return false }
            counts[lane, default: 0] += 1
            return true
        }
    }

    func leave(_ lane: CoverLane) { lock.withLock { counts[lane, default: 0] -= 1 } }

    /// Threads in a lane now, for tests.
    func count(_ lane: CoverLane) -> Int { lock.withLock { counts[lane, default: 0] } }
}
