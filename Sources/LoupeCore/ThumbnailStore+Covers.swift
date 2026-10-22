import CoreGraphics
import Foundation
import HomeScreenModel

/// Home's card covers (Home spec §2.5): the thumbnail of a file whose folder no window lists, from the catalog without
/// opening the folder, else made from the file and kept in the database like any thumbnail.
extension ThumbnailStore {
    /// The cover of `url` at most `maxPixel` on its long side; nil when the file cannot be read. A folder some window
    /// lists answers from the strip's thumbnails; else a stored thumbnail whose stamp is still the file's; else one
    /// made now, one at a time, behind every viewer read.
    public func cover(_ url: URL, maxPixel: Int) async -> CGImage? {
        if ids[url] != nil, let cell = await cell(url, maxPixel: maxPixel) { return cell }
        let locate = self.locate
        // `resolve` may block on a slow share: never on the actor.
        let location = await Self.offActor { locate(url) }
        guard let stamp = try? await reader.stamp(url, priority: ReadPriority.background) else { return nil }
        if let location, let row = perform("cover", { try $0.file(at: location) }) ?? nil, row.stamp == stamp,
           let stored = perform("cover", { try $0.thumbnail(row.id) }) ?? nil {
            return await Self.offActor { ThumbnailMaker.decodeCell(stored.jpeg, maxPixel: maxPixel) }
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
        return await Self.offActor { ThumbnailMaker.decodeCell(jpeg, maxPixel: maxPixel) }
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

    /// The stored thumbnail of `url` at most `maxPixel` on its long side, from the catalog alone: no stat and no read
    /// of the file (a folder card's mosaic on a slow share). Nil when the catalog has none; it may be older than the
    /// file, which only a folder card can afford.
    public func catalogThumbnail(_ url: URL, maxPixel: Int) async -> CGImage? {
        let locate = self.locate
        guard let location = await Self.offActor({ locate(url) }),
              let row = perform("catalog", { try $0.file(at: location) }) ?? nil,
              let stored = perform("catalog", { try $0.thumbnail(row.id) }) ?? nil else { return nil }
        return await Self.offActor { ThumbnailMaker.decodeCell(stored.jpeg, maxPixel: maxPixel) }
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
        !(mount(of: url)?.local ?? false)
    }

    /// The mount point of `url`'s share (nil on a local volume, or when no mount point matches), from the mount table.
    @Sendable static func networkMountPoint(_ url: URL) -> String? {
        guard let mount = mount(of: url), !mount.local else { return nil }
        return mount.point
    }

    /// The mount point above `url`'s path, as written, and whether it is local (`MNT_NOWAIT`: no file system asked).
    static func mount(of url: URL) -> (point: String, local: Bool)? {
        let room = getfsstat(nil, 0, MNT_NOWAIT)
        guard room > 0 else { return nil }
        let blank = statfs()
        var mounts = Array(repeating: blank, count: Int(room) + 4)
        let count = mounts.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        let path = url.standardizedFileURL.path
        var best: (point: String, local: Bool)?
        for index in 0..<max(0, Int(count)) {
            let mountPoint = ThumbnailLocation.string(from: &mounts[index].f_mntonname)
            guard path == mountPoint || path.hasPrefix(mountPoint == "/" ? "/" : mountPoint + "/") else { continue }
            if mountPoint.count > best?.point.count ?? -1 {
                best = (mountPoint, mounts[index].f_flags & UInt32(MNT_LOCAL) != 0)
            }
        }
        return best
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

    /// A folder's or zip's card: its pictures, at most `maxPixel` on their long side (up to four photos spread across
    /// it, the one last viewed there first), and its summary (folder cards spec, "Сводка папки"). `location` is where
    /// the catalog keeps the folder's files (from the folder Home shows: `folderLocation(shown)`'s `.subfolder(name)`;
    /// nil: none). `network` says whether it is on a share when there is no location (`CoverPlace.unknown`); nil: from
    /// the location, or from the mount table without one. `modified` is the folder's (or zip's) date as its parent's
    /// listing gave it.
    ///
    /// Four of the folder's photos in the catalog are its pictures, at once, without a listing. A summary in the
    /// catalog made at that date needs none either; else the card goes out with `summaryPending` and the next call for
    /// the folder lists it, once a session (limited to `coverListingTimeout` on a share, `coverLocalListingTimeout`
    /// elsewhere; while its share is offline only as the probe of `coverOfflineProbeInterval`): with stat on a local
    /// volume (the summary with dates and size), names only on a share (counts; the dates and size of a summary kept
    /// from a visit stay), a zip's directory read once. A listing that does not end (time out, lane full, part only)
    /// or fails keeps the stored summary. Without four photos in the catalog the listing's picks are
    /// made into thumbnails and kept in the catalog, like `cover`'s; a folder without photos shows one of each of its
    /// first four subfolders' (two levels down at most).
    ///
    /// Empty pictures when there is nothing to show; then the folder is not listed again this session: found empty, not
    /// listable, or listed `coverTimeoutsAllowed` times without a name in time. A malformed zip is `.broken`; a card on
    /// a share that is offline (`coverOfflineTimeouts` listings on it in a row without a name in time or with an I/O
    /// error, or its volume gone) is `.offline` until anything on it answers (`volumeAnswered`). Nil for "not now": no
    /// pictures yet and its lane full of hung calls, or its listing gave no name in time (on a share that is not
    /// offline). Nothing here asks the system but the listing. New thumbnails wait while the viewer is busy;
    /// cancelling the task stops the listing and the reads.
    public func folderCard(_ folder: URL, archive: Bool, in location: ThumbnailLocation?, network: Bool? = nil,
                           maxPixel: Int, lastViewed: String? = nil, modified: Date? = nil) async -> FolderCard? {
        // Without a location, a share as the mount table says (which never hangs).
        let network = network ?? location?.isNetwork ?? coverVolumeIsNetwork(folder)
        let key = Self.memoKey(folder, modified)
        let volume = network ? Self.volumeKey(folder, location) : nil
        let stored = location.flatMap { storedSummary(at: $0) }
        let fresh = stored.map { $0.folderModified != nil && $0.folderModified == modified } ?? false
        let wantsSummary = !fresh && !summaryTried.contains(key)
        func problem(_ own: CardProblem?) -> CardProblem? { isOffline(volume) ? .offline : own }
        // The catalog's four: the pictures at once, whatever becomes of the summary's listing.
        if let location, let images = await catalogCells(location, count: Self.coverPhotos, lastViewed: lastViewed,
                                                         maxPixel: maxPixel) {
            // Listed on a call of its own, the one after this (`summaryPending`); not while its share is offline but
            // for a probe now and then.
            guard wantsSummary, mayList(on: volume, probe: false) else {
                summaryDue.remove(key)
                return FolderCard(images: images, summary: stored, problem: problem(coverProblems[key]))
            }
            guard summaryDue.contains(key) else {
                noteSummaryDue(key)
                return FolderCard(images: images, summary: stored, problem: problem(coverProblems[key]),
                                  summaryPending: true)
            }
            guard !Task.isCancelled else {
                return FolderCard(images: images, summary: stored, problem: problem(coverProblems[key]),
                                  summaryPending: true)
            }
            summaryDue.remove(key)
            // Its share went offline since, and its probe is someone else's: done without the listing.
            guard mayList(on: volume, probe: true) else {
                return FolderCard(images: images, summary: stored, problem: problem(coverProblems[key]))
            }
            let result = await coverListing(folder, archive: archive, network: network, key: key, volume: volume,
                                            forSummary: true)
            // A card that left meanwhile keeps its try (and its follow-up).
            guard !Task.isCancelled else {
                noteSummaryDue(key)
                return FolderCard(images: images, summary: stored, problem: problem(coverProblems[key]),
                                  summaryPending: true)
            }
            noteSummaryTried(key)
            let listing: CoverListing?
            switch result {
            case .listed(let listed, complete: true): listing = listed
            case .listed, .settled, .notNow: listing = nil
            }
            return card(images, listing: listing, problem: problem(coverProblems[key]), modified: modified,
                        location: location)
        }
        if emptyCovers.contains(key) {
            return FolderCard(images: [], summary: stored, problem: problem(coverProblems[key]))
        }
        guard let made = await folderCover(folder, archive: archive, location: location, network: network,
                                           maxPixel: maxPixel, lastViewed: lastViewed, modified: modified,
                                           count: Self.coverPhotos, depth: 0, catalogChecked: true,
                                           mustList: wantsSummary) else {
            // On a share that is offline the card says so, pictures or not.
            guard isOffline(volume) else { return nil }
            return FolderCard(images: [], summary: stored, problem: .offline)
        }
        if made.listed, !Task.isCancelled { noteSummaryTried(key) }
        return card(made.images, listing: made.listing, problem: problem(made.problem), modified: modified,
                    location: location)
    }

    /// The card with a complete listing's summary, queued for the catalog when it changed, or the stored one. The
    /// stored summary is read again here: one written while the listing ran (the folder opened meanwhile, with dates)
    /// is what a names-only count keeps the dates of.
    private func card(_ images: [CGImage], listing: CoverListing?, problem: CardProblem?, modified: Date?,
                      location: ThumbnailLocation?) -> FolderCard {
        let stored = location.flatMap { storedSummary(at: $0) }
        guard let listing else { return FolderCard(images: images, summary: stored, problem: problem) }
        let summary = Self.summary(of: listing, modified: modified, stored: stored)
        if let location, summary != stored { queueSummary(summary, at: location) }
        return FolderCard(images: images, summary: summary, problem: problem, photoDates: listing.photoDates)
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
    private func coverListing(_ folder: URL, archive: Bool, network: Bool, key: String, volume: String?,
                              forSummary: Bool) async -> CoverListingResult {
        let lister = coverLister, dated = !network
        let outcome = await Self.onThread(coverThreads, lane: CoverLane(network: network, resolving: false),
                                          timeout: network ? coverNetworkTimeout : coverLocalTimeout) {
            part in try lister(folder, archive, dated, part)
        }
        func timedOut() -> CoverListingResult {
            noteVolumeTimeout(volume)
            guard !forSummary else { return .notNow }
            coverTimeouts[key, default: 0] += 1
            guard coverTimeouts[key, default: 0] >= Self.coverTimeoutsAllowed else { return .notNow }
            coverTimeouts[key] = nil
            emptyCovers.insert(key)
            return .settled(nil)
        }
        switch outcome {
        case .value(let listed, let complete):
            noteVolumeAnswered(volume)
            if !forSummary { coverTimeouts[key] = nil }
            setProblem(nil, for: key)
            return .listed(listed, complete: complete)
        case .failed(let error):
            if network, !coverVolumeIsNetwork(folder) {
                // The mount table no longer puts the path on a share: its volume is gone.
                markVolumeOffline(volume)
            } else if network, Self.isConnectionError(error) {
                return timedOut()
            } else {
                // No such file, no permission, a malformed zip: the share answered.
                noteVolumeAnswered(volume)
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

    /// The key of a share's card's volume for its offline state: the catalog's volume, else the share's mount point
    /// (nil when the mount table puts the folder on no share).
    nonisolated static func volumeKey(_ folder: URL, _ location: ThumbnailLocation?) -> String? {
        location?.volume ?? networkMountPoint(folder)
    }

    /// Tests: how often an offline share may be probed.
    func setCoverProbeInterval(_ interval: Duration) {
        coverProbeInterval = interval
    }

    /// Something on the share of `folder` answered (the browser's own listing of it, say): it is not offline, and its
    /// time outs in a row start again. `location`: where the catalog keeps `folder`'s files, as for its cards (nil:
    /// the mount table's share).
    public func volumeAnswered(_ folder: URL, in location: ThumbnailLocation?) {
        noteVolumeAnswered(Self.volumeKey(folder, location))
    }

    func isOffline(_ volume: String?) -> Bool {
        volume.map { offlineVolumes[$0] != nil } ?? false
    }

    /// Whether a card on `volume` may be listed for its summary: always unless the share is offline, then once per
    /// `coverProbeInterval` (`probe`: this is that listing; else only asking).
    private func mayList(on volume: String?, probe: Bool) -> Bool {
        guard let volume, let since = offlineVolumes[volume] else { return true }
        guard ContinuousClock.now - since >= coverProbeInterval else { return false }
        if probe { offlineVolumes[volume] = .now }
        return true
    }

    private func noteVolumeTimeout(_ volume: String?) {
        guard let volume else { return }
        if coverVolumeTimeouts.count >= Self.coverVolumeLimit { coverVolumeTimeouts.removeAll() }
        coverVolumeTimeouts[volume, default: 0] += 1
        if coverVolumeTimeouts[volume, default: 0] >= Self.coverOfflineTimeouts { markVolumeOffline(volume) }
    }

    private func markVolumeOffline(_ volume: String?) {
        guard let volume else { return }
        if offlineVolumes.count >= Self.coverVolumeLimit { offlineVolumes.removeAll() }
        offlineVolumes[volume] = .now
    }

    func noteVolumeAnswered(_ volume: String?) {
        guard let volume else { return }
        coverVolumeTimeouts[volume] = nil
        offlineVolumes[volume] = nil
    }

    /// The folder's card went out with `summaryPending`: its next call lists it.
    private func noteSummaryDue(_ key: String) {
        if summaryDue.count >= Self.coverPickLimit { summaryDue.removeAll() }
        summaryDue.insert(key)
    }

    /// The folder was listed for its summary this session (at this date): not again, whatever came of it.
    private func noteSummaryTried(_ key: String) {
        if summaryTried.count >= Self.coverPickLimit { summaryTried.removeAll() }
        summaryTried.insert(key)
    }

    /// `catalogChecked`: the caller found fewer than `count` photos of the folder in the catalog. `mustList`: the
    /// summary needs a listing, so the remembered pick does not spare it.
    private func folderCover(_ folder: URL, archive: Bool, location: ThumbnailLocation?, network: Bool, maxPixel: Int,
                             lastViewed: String?, modified: Date?, count: Int, depth: Int, catalogChecked: Bool = false,
                             mustList: Bool = false) async -> CoverMade? {
        let key = Self.memoKey(folder, modified)
        guard !emptyCovers.contains(key) else { return CoverMade(images: [], problem: coverProblems[key]) }
        guard !Task.isCancelled else { return nil }
        if !catalogChecked, let location,
           let images = await catalogCells(location, count: count, lastViewed: lastViewed, maxPixel: maxPixel) {
            return CoverMade(images: images)
        }
        // The pick of an earlier complete listing: the pictures from the catalog, no listing.
        if !mustList, let location, let pick = coverPick(key, lastViewed: lastViewed) {
            switch pick {
            case .photos(let names):
                if let images = await knownCells(folder, names.prefix(count), at: location, maxPixel: maxPixel) {
                    return CoverMade(images: images)
                }
                guard !Task.isCancelled else { return nil }
                coverPicks[key] = nil   // a thumbnail left the catalog: listed again
            case .subfolders(let names):
                return await subfolderCover(folder, names, location: location, network: network, maxPixel: maxPixel,
                                            count: count, depth: depth, complete: true, modified: modified)
                    .map { CoverMade(images: $0) }
            }
        }
        let listed: CoverListing, complete: Bool
        switch await coverListing(folder, archive: archive, network: network, key: key,
                                  volume: network ? Self.volumeKey(folder, location) : nil, forSummary: false) {
        case .listed(let value, let ended): (listed, complete) = (value, ended)
        case .settled(let problem): return CoverMade(images: [], listed: true, problem: problem)
        case .notNow: return nil
        }
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
        let summarized = complete && depth == 0 ? listed : nil
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
            return CoverMade(images: images, listing: summarized, listed: true)
        case .subfolders(let subfolders):
            guard let images = await subfolderCover(folder, Array(subfolders), location: location, network: network,
                                                    maxPixel: maxPixel, count: count, depth: depth, complete: complete,
                                                    modified: modified) else { return nil }
            return CoverMade(images: images, listing: summarized, listed: true)
        case .empty:
            if complete { emptyCovers.insert(key) }
            return CoverMade(images: [], listing: summarized, listed: true)
        }
    }

    /// `count` photos of the folder at `location` with a thumbnail in the catalog, spread across them as Finder sorts
    /// them, the one last viewed first, decoded; nil when there are fewer.
    private func catalogCells(_ location: ThumbnailLocation, count: Int, lastViewed: String?,
                              maxPixel: Int) async -> [CGImage]? {
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
        return images
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
                                maxPixel: Int, count: Int, depth: Int, complete: Bool,
                                modified: Date?) async -> [CGImage]? {
        guard depth < Self.coverDepth else { return [] }
        var images: [CGImage] = [], notNow = false
        for name in subfolders where images.count < count && !Task.isCancelled {
            // One picture of each: the subfolder's own card makes the rest when it is shown.
            let sub = await folderCover(folder.appendingPathComponent(name, isDirectory: true), archive: false,
                                        location: location?.subfolder(name), network: network, maxPixel: maxPixel,
                                        lastViewed: nil, modified: nil, count: 1, depth: depth + 1)
            if let sub { images += sub.images.prefix(1) } else { notNow = true }
        }
        if notNow, images.count < count { return nil }
        let keys = subfolders.map { Self.memoKey(folder.appendingPathComponent($0), nil) }
        if complete, keys.allSatisfy(emptyCovers.contains) { emptyCovers.insert(Self.memoKey(folder, modified)) }
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

    /// The pick remembered for `key`; a folder's photos only when made for the same last-viewed photo.
    private func coverPick(_ key: String, lastViewed: String?) -> CoverPick.Kind? {
        guard let pick = coverPicks[key] else { return nil }
        if case .photos = pick.kind, pick.lastViewed != lastViewed { return nil }
        coverPickUses += 1
        coverPicks[key]?.use = coverPickUses
        return pick.kind
    }

    private func remember(_ kind: CoverPick.Kind, for key: String, lastViewed: String?) {
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
            if ids[url] != nil || made[url] != nil, let cell = await cell(url, maxPixel: maxPixel) {
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

    /// The catalog's thumbnail of the file at `location` as a cell, however old (a card can afford it); nil when it
    /// has none.
    private func storedCell(at location: ThumbnailLocation, maxPixel: Int) async -> CGImage? {
        guard let row = perform("cover", { try $0.file(at: location) }) ?? nil,
              let stored = perform("cover", { try $0.thumbnail(row.id) }) ?? nil else { return nil }
        return await Self.offActor(qos: Self.coverQoS) { ThumbnailMaker.decodeCell(stored.jpeg, maxPixel: maxPixel) }
    }

    /// One photo of a cover: the strip's thumbnail when a window lists its folder, else the catalog's, else one made
    /// now, behind the open folders' thumbnails, and kept in the catalog.
    private func coverCell(_ url: URL, at location: ThumbnailLocation?, maxPixel: Int) async -> CGImage? {
        if ids[url] != nil || made[url] != nil, let cell = await cell(url, maxPixel: maxPixel) { return cell }
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
        return await Self.offActor(qos: Self.coverQoS) { ThumbnailMaker.decodeCell(jpeg, maxPixel: maxPixel) }
    }

    /// Runs blocking `work` on a thread of its own in a place of `lane` (`threads`), and waits for it at most `timeout`
    /// or until the task is cancelled, then gives up on it: the answer is what `work` handed to its `part` so far, and
    /// `part` returns false from then on so it can stop; the thread keeps its place until it returns. `.busy` when the
    /// lane has no free place (or the task was cancelled with nothing yet), `.timedOut` when nothing came in time.
    static func onThread<T: Sendable>(_ threads: CoverThreads, lane: CoverLane, timeout: Duration,
                                      _ work: @escaping @Sendable (_ part: @escaping @Sendable (T) -> Bool) throws -> T)
        async -> ThreadAnswer<T>.Outcome {
        guard threads.enter(lane) else { return .busy }
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
