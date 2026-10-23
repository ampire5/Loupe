import CoreGraphics
import Foundation

/// What the strip should draw for a file.
public enum ThumbnailStatus: Sendable, Equatable {
    /// In memory or in the database: `cell` returns it.
    case ready
    /// Not made yet (or its folder is not synced yet).
    case pending
    /// Reading or decoding failed in this session; tried again at the next opening of its folder.
    case unavailable
}

/// The app's one source of thumbnails (spec §3): owns the two databases, makes the missing thumbnails in the
/// background for every window's folder, and serves cell-sized pictures to the strips.
///
/// The generator keeps out of the viewer's way (spec §3.6): at most `maxReads` thumbnail reads, marked
/// `ReadPriority.isBackground`, which `FileReader` runs only on threads beyond the viewer's two (so even reads stuck
/// on a dead share never hold up the viewer's); new ones start only once the viewer cache has been idle for
/// `idleDelay` (its idle signal flickers between jobs), none start while neighbours are being read, and those still
/// reading are cancelled when the current photo needs I/O. A finished read is decoded in the store's own `DecodePool`
/// (`decodes` at once, at utility QoS, so the viewer's decodes win the cores) while the next one runs. A new thumbnail lands in memory at once and reaches the database in batches
/// (every `commitDelay` or 100 thumbnails), so the writer costs a few ms per second at most.
///
/// What is known per file lives in a few maps keyed by URL, all limited to the folders some window shows
/// (`listed`, `ids`, `stored`) except `made`, the thumbnails not in the database: those not written yet, and
/// with no database (`limitBytes == 0`, or it cannot be opened) every thumbnail of the session, up to
/// `memoryCap` (ThumbnailStore+Memory.swift).
public actor ThumbnailStore {
    static let readPriority = ReadPriority.background
    /// Thumbnail reads in flight at most. On the user's share a second read adds about a quarter to the first
    /// (docs/bench/2026-10-15-m2.5-thumb-speed.md) and the server gives little more to four; `FileReader` has two
    /// threads for background reads, so a third would only wait in its queue.
    public static let maxReads = 2
    /// Thumbnail decodes at once, by the machine: half its physical cores less one, 1 to 4 (3 on an 8-core i7 or an
    /// M1, 1 on 4 cores). Thumbnails come fast but leave most of the machine to the viewer and the user's other apps:
    /// on a local SSD folder of progressive 3456 x 2160 JPEGs (i7-10700K) 1/2/3/4/6 decodes make
    /// 7.0/13.8/20.3/26.3/36.2 files/s for the same ~30 s of CPU per 200 files, so each slot is one busy core for as
    /// long as the folder takes.
    public static let defaultDecodes = decodes(physicalCores: Machine.physicalCores)

    static func decodes(physicalCores: Int) -> Int { min(4, max(1, physicalCores / 2 - 1)) }
    static let batchSize = 100
    static let cellCapacity = 300

    // MARK: Configuration

    let directory: URL?
    let reader: any FileReading
    var thumbSize: Int
    var limitBytes: Int
    let decoder: @Sendable (Data) -> any ImageDecoder
    let cachedBytes: @Sendable (URL, FileStamp) async -> Data?
    let locate: @Sendable (URL) -> ThumbnailLocation?
    /// A file's location on a share from the mount table alone, without asking the share (`shareLocation`); nil off a
    /// share, where `locate` answers.
    let shareLocate: @Sendable (URL) -> ThumbnailLocation?
    let idleDelay: Duration
    let commitDelay: Duration
    let readLimit: Int
    /// The thumbnails' own decode slots, apart from the viewer's: on a local disk reads cost nothing and the decodes
    /// are the limit (a progressive 3456 x 2160 JPEG under 4096 px decodes whole, ~125 ms on an i7-10700K).
    let decodeLimit: DecodePool
    /// Home's covers are made one at a time (`cover`).
    let coverLimit = DecodePool(slots: 1, reserved: 0)
    /// Home's folder and archive covers in the background (`folderCover`), a few at a time; paused while the viewer is
    /// busy (`setViewerActivity`).
    public nonisolated let coverQueue = CoverQueue()
    /// Diagnostics, one line per thumbnail made (the app passes `DebugLog.log` under `LOUPE_DEBUG`).
    let log: (@Sendable (String) -> Void)?

    // MARK: Windows and folders

    struct ListedFile: Equatable, Sendable {
        let url: URL
        let stamp: FileStamp
    }

    struct Window {
        var request: ThumbnailRequest
        var stamps: [URL: FileStamp]
        /// The request's stamped files by folder, in playlist order.
        var listings: [URL: [ListedFile]]
        /// Folders of the request with no stamped file (a share's names-only listing): served from the catalog until
        /// their stamps come (`openProvisional`).
        var provisional: Set<URL> = []
    }

    struct Folder {
        var listing: [ListedFile]
        /// Nil: no database for this folder (memory only, or its volume could not be examined).
        var location: ThumbnailLocation?
        /// Only some of the folder's files (the walk's photos stamped so far): the catalog keeps the others' rows.
        var partial = false
        /// Names listed without a stamp (the walk's photos whose stat failed): the catalog keeps their rows.
        var kept: Set<String> = []
        /// Its files' names only so far: `listing` holds the catalog's rows of them with the stamps they were
        /// catalogued at, nothing is written for it (no sync, no access) and nothing is made (`listed` has none).
        var provisional = false
        /// A provisional folder's catalog rows, read once per visit, and the ids checked for a thumbnail so far.
        var catalog: [String: CatalogRow]?
        var checked: [Int64: Bool] = [:]
        /// A provisional folder's files asked for (those the catalog has rows of are `listing`).
        var asked: [URL] = []
    }

    typealias CatalogRow = (id: Int64, stamp: FileStamp)

    var windows: [Int: Window] = [:]
    /// The subtree walk's window (`setWalkWindow`): after every window's files, one folder at a time; its listings
    /// hold all its folders, those a window shows too (that window's listing wins while it shows them).
    var walkWindow: Window?
    /// How the walk window's folders are opened: only some of their files (`Folder.partial`), and the names kept.
    var walkPartial = false
    var walkKept: [URL: Set<String>] = [:]
    /// Its files with no thumbnail yet (pending, not evicted), and the walk waiting for that count to change.
    var walkPending: Set<URL> = []
    var walkWaiter: (count: Int, continuation: CheckedContinuation<Int, Never>)?
    /// Folders some window shows, by directory URL: two windows on one folder share it.
    var folders: [URL: Folder] = [:]
    /// Resolved once per folder for the session (`resolve` blocks on a slow share, so never per file).
    var locations: [URL: ThumbnailLocation] = [:]
    var locating: [URL: Task<ThumbnailLocation?, Never>] = [:]
    /// Folders whose `locations` key came from the mount table (`shareLocate`): a resolved one replaces it.
    var shareLocated: Set<URL> = []

    /// Files of the open folders with their listing stamps: only these are generated.
    var listed: [URL: FileStamp] = [:]
    /// Catalog file ids of the listed files.
    var ids: [URL: Int64] = [:]
    /// Listed files with a thumbnail in `Thumbs.db`.
    var stored: Set<URL> = []
    /// Files of provisional folders with an id from the catalog (`Folder.provisional`): their showing is no access.
    var provisional: Set<URL> = []
    /// Files served provisionally whose real stamps differed (`open`), until the request that brought them takes them.
    var provisionalChanged: Set<URL> = []
    /// Test hook: catalog reads of a provisional folder's rows (`lookUpProvisional`).
    var provisionalLookups = 0

    // MARK: Thumbnails

    struct Made {
        let jpeg: Data
        let info: ImageInfo
        /// The stamp of the bytes it was made from.
        let stamp: FileStamp
    }

    /// Change through `setMade` / `removeMade` / `removeAllMade`, which keep the byte count and the cap.
    var made: [URL: Made] = [:]
    var madeBytes = 0
    /// `accessClock` at the last make or show of each `made` entry, for the cap's least-recently-used order.
    var madeAccess: [URL: UInt64] = [:]
    var accessClock: UInt64 = 0
    let memoryCap: Int
    var unavailable: Set<URL> = []
    /// Thumbnails the size limit evicted from files still listed: made again at the next opening of their
    /// folder, not now, or a folder bigger than the limit would be read in circles.
    var evicted: Set<URL> = []
    var cells = ThumbnailCells(capacity: cellCapacity)
    /// Bumped whenever cached cells may no longer match: a decode that started before is not cached.
    var cellEpoch = 0
    /// Files whose `cell` or `image` came back nil while pending: told about when they turn up in the database, which
    /// (unlike a newly made thumbnail) would otherwise go unannounced.
    var missed: Set<URL> = []
    var onThumbnail: (@Sendable (URL) -> Void)?

    // MARK: Folder covers

    var coverLister: DatedCoverLister = ThumbnailStore.listCover
    var coverStat: CoverStat = ThumbnailStore.statFolder
    var coverNetworkTimeout = ThumbnailStore.coverListingTimeout
    var coverLocalTimeout = ThumbnailStore.coverLocalListingTimeout
    var coverVolumeIsNetwork: @Sendable (URL) -> Bool = ThumbnailStore.mountIsNetwork
    var coverNetworkVolume: @Sendable (URL) -> String? = ThumbnailStore.networkVolume
    /// `setOnVolumeAnswered`'s handler.
    var onVolumeAnswered: (@Sendable (String) -> Void)?
    /// Folders and zips with nothing to show on a cover for the rest of the session, by path: found empty, not
    /// listable, or never listed in time.
    var emptyCovers: Set<String> = []
    /// Listings of a folder that gave no name in time so far, by path (`coverTimeoutsAllowed`).
    var coverTimeouts: [String: Int] = [:]
    /// Each folder's last pick from a complete listing this session, by path, at most `coverPickLimit` (the least
    /// recently used go first): its next cover needs no listing.
    var coverPicks: [String: CoverPick] = [:]
    var coverPickUses: UInt64 = 0
    /// The direct subfolders of each folder whose card had a complete listing this session, by path
    /// (`subfolderNames`), at most `coverSubfolderNameLimit` names in all (the least recently used folders go first).
    var coverSubfolders: [String: CoverSubfolders] = [:]
    var coverSubfolderUses: UInt64 = 0
    var coverSubfolderNames = 0
    /// What the cards of folders and zips this session have against them (a malformed zip), by `memoKey`; cleared by
    /// a listing that answers. At most `coverPickLimit` (then forgotten at once).
    var coverProblems: [String: CardProblem] = [:]
    /// Folders (by `memoKey`) listed for their summary this session, however it ended: not again. At most
    /// `coverPickLimit` (then forgotten at once).
    var summaryTried: Set<String> = []
    /// Folders (by `memoKey`) whose card went out with the catalog's pictures and `summaryPending`: the next call lists
    /// them. At most `coverPickLimit` (then forgotten at once).
    var summaryDue: Set<String> = []
    /// Shares' listings in a row without a name in time (or with an I/O error), by `volumeKey`; and the shares
    /// offline, with when they were last listed (marked, or probed: `coverProbeInterval`). At most `coverVolumeLimit`
    /// each.
    var coverVolumeTimeouts: [String: Int] = [:]
    var offlineVolumes: [String: ContinuousClock.Instant] = [:]
    var coverProbeInterval = ThumbnailStore.coverOfflineProbeInterval
    /// Folders (by `memoKey`) given up or timing out because their share did not answer, with the share's key: their
    /// notes go when it comes back. At most `coverPickLimit` (then forgotten at once).
    var awayFolders: [String: String] = [:]
    /// Folder summaries made by covers, waiting for the next batch (`commit`), by volume and path; read before the
    /// catalog. At most `summaryBatch`: a full batch is written at once.
    var pendingSummaries: [String: (location: ThumbnailLocation, summary: FolderSummary)] = [:]
    /// Covers' blocking calls (listings, resolves) on their own threads, per lane, those given up on included (one
    /// hung on a dead share stays).
    nonisolated let coverThreads = CoverThreads(limit: ThumbnailStore.coverThreadsPerLane)

    // MARK: Database

    enum Disk {
        case unopened
        case open(ThumbnailDatabase)
        /// Memory only, by setting or because the database cannot be opened.
        case none
    }

    var disk = Disk.unopened
    /// Bytes in `Thumbs.db` as far as this store knows: summed at open, grown by each batch, so the full
    /// scan of `enforceLimit` runs only when the limit is actually passed.
    var storedBytes = 0
    /// Made thumbnails waiting for the next batch.
    var uncommitted: Set<URL> = []
    /// Files whose thumbnails were shown, for `last_access` in the next batch.
    var touched: Set<Int64> = []
    var commitTimer: Task<Void, Never>?
    var recovering = false
    var warned = false
    /// Counts database connections given up (files made anew under the running store, or closed): a batch
    /// can tell its write failed on files that are gone now (and should go to the new ones) rather than
    /// for good, and a clean-up that ids it read before an await may be void.
    var databaseEpoch = 0
    /// Test hooks: `put` calls made (batches with thumbnails), and thumbnails waiting for one.
    var commitCount = 0
    var pendingWrites: Int { uncommitted.count }

    // MARK: Generator

    struct Job {
        let token: UInt64
        let url: URL
        let task: Task<Void, Never>
        var cancelled = false
        /// Holds one of the `readLimit` reads: from its start until its read returns, and again for the whole
        /// file after a coarse prefix.
        var reading = true
    }

    enum Outcome: Sendable {
        case made(jpeg: Data, info: ImageInfo, stamp: FileStamp)
        case failed
        case cancelled
    }

    var activity = CacheActivity.idle
    /// Covers' thumbnail reads in flight (`coverCell`), by number: cancelled when the viewer's current photo needs the
    /// share (`setActivity(.current)`), and made again once the viewer is idle.
    var coverReads: [UInt64: Task<(Outcome, Timing), Never>] = [:]
    var nextCoverRead: UInt64 = 0
    /// When the viewer cache last became idle; nil while it is not.
    var idleSince: ContinuousClock.Instant? = .now
    var idleWake: Task<Void, Never>?
    /// By token. At most `readLimit` reading, plus one decoding beyond them: bytes read stay bounded while the
    /// decodes keep up (they take ~90 ms against ~250 ms of share time per 11 MB JPEG).
    var jobs: [UInt64: Job] = [:]
    /// Jobs waiting for a free read to read the whole file after their prefix, oldest token first.
    var readWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    var nextToken: UInt64 = 0
    var queue: [URL] = []
    var queuePosition = 0
    var queueIsStale = true
    /// The user paused the work ahead (`pauseAhead`): only the windows' visible files are made.
    var aheadPaused = false

    /// `directory == nil` or `limitBytes == 0`: memory only, nothing is written anywhere (and with limit 0,
    /// databases an earlier session left in `directory` are deleted). The database opens on first use, not
    /// here, so creating the store costs the caller (the app's launch) no SQLite work.
    /// `cachedBytes` hands over the viewer cache's bytes of a photo if they were read at the given (listing)
    /// stamp, a thumbnail without a read; `locate` is `ThumbnailLocation.resolve` but for tests, like `idleDelay`,
    /// `commitDelay` and `memoryCap`; `readLimit` other than `maxReads` only for the bench, which compares one read
    /// with two, and `decodes` other than `defaultDecodes` for the bench and the tests.
    public init(directory: URL?, reader: any FileReading, thumbSize: Int, limitBytes: Int,
                decoder: @escaping @Sendable (Data) -> any ImageDecoder = DecoderRegistry.decoder(for:),
                cachedBytes: @escaping @Sendable (URL, FileStamp) async -> Data? = { _, _ in nil },
                locate: @escaping @Sendable (URL) -> ThumbnailLocation? = { ThumbnailLocation.resolve($0) },
                shareLocate: @escaping @Sendable (URL) -> ThumbnailLocation? = ThumbnailStore.shareLocation,
                idleDelay: Duration = .milliseconds(100), commitDelay: Duration = .seconds(1),
                readLimit: Int = maxReads, decodes: Int = defaultDecodes, memoryCap: Int = defaultMemoryCap,
                log: (@Sendable (String) -> Void)? = nil) {
        self.directory = directory
        self.reader = reader
        self.thumbSize = thumbSize
        self.limitBytes = limitBytes
        self.decoder = decoder
        self.cachedBytes = cachedBytes
        self.locate = locate
        self.shareLocate = shareLocate
        self.idleDelay = idleDelay
        self.commitDelay = commitDelay
        self.readLimit = max(1, readLimit)
        decodeLimit = DecodePool(slots: max(1, decodes), reserved: 0, qos: .utility)
        self.memoryCap = memoryCap
        self.log = log
        // `thumb-cache-size=0` means no traces: what an earlier session with a cache left goes now. Two
        // unlinks in Caches, cheap enough for the caller's thread.
        if let directory, limitBytes == 0 { ThumbnailDatabase.removeFiles(in: directory) }
    }

    /// `handler` hears of every file whose status changed to `.ready` (a thumbnail was made, or turned up in
    /// the database for a cell asked for earlier) or `.unavailable` (it could not be made), so the strip can
    /// swap the placeholder for the picture or for the "no thumbnail" mark.
    public func setOnThumbnail(_ handler: @escaping @Sendable (URL) -> Void) {
        onThumbnail = handler
    }

    // MARK: - Requests

    /// What window `window` (an id the caller picks) needs now; nil when it closed. A new listing (other files
    /// or other stamps) syncs its folders into the catalog, once even for several windows on one folder;
    /// anything else (position, visible cells, key window) only reorders the queue. Files without a stamp
    /// (the one-file playlist shown before the listing arrives) wait for one to be made; a folder with none stamped
    /// (a share's names-only listing) serves what the catalog has of them meanwhile (`openProvisional`), read only.
    /// Returns the files served that way whose stamps, now known, differ from the catalog's (forgotten: the caller
    /// asks for them again).
    @discardableResult
    public func setRequest(window: Int, _ request: ThumbnailRequest?, stamps: [URL: FileStamp]) async -> [URL] {
        defer { replan() }
        guard let request else {
            windows[window] = nil
            closeUnshownFolders()
            await reopenWalkFolders()
            return []
        }
        // Equal arrays and dictionaries of one playlist compare by identity first: free on every step.
        if let old = windows[window], old.request.files == request.files, old.stamps == stamps {
            windows[window]?.request = request
            return []
        }
        let listings = Self.listings(request.files, stamps)
        let unstamped = Self.unstamped(request.files, stamps, except: listings)
        windows[window] = Window(request: request, stamps: stamps, listings: listings, provisional: Set(unstamped.keys))
        await openListings(listings) { $0.windows[window]?.listings }
        await openProvisional(unstamped) { $0.windows[window]?.provisional }
        await reopenWalkFolders()
        // This request's files among them (another call may have opened some meanwhile: each takes its own).
        let changed = request.files.filter { provisionalChanged.contains($0) }
        provisionalChanged.subtract(changed)
        return changed
    }

    /// The folders of a window's new `listings` synced into the catalog, each located first. `current` gives the
    /// window's listings as they are after the awaits (nil: the window closed); `partial`: the listings hold only some
    /// of their folders' files; `kept`: names listed without a stamp, by folder.
    func openListings(_ listings: [URL: [ListedFile]], partial: Bool = false, kept: [URL: Set<String>] = [:],
                      current: (isolated ThumbnailStore) -> [URL: [ListedFile]]?) async {
        // A folder left stops generating now, not after the new one is located.
        closeUnshownFolders()
        replan()
        func stale(_ dir: URL, _ listing: [ListedFile]) -> Bool {
            guard let folder = folders[dir] else { return true }
            return folder.provisional || folder.listing != listing || folder.partial != partial
                || folder.kept != kept[dir] ?? []
        }
        for (dir, listing) in listings where stale(dir, listing) {
            let location = wantsDisk ? await location(of: dir, sample: listing[0].url) : nil
            // The await let other calls in: sync what the window lists now, unless another one already did.
            guard let now = current(self)?[dir], stale(dir, now) else { continue }
            open(dir, now, location: location, partial: partial, kept: kept[dir] ?? [])
        }
    }

    /// The viewer cache's activity: new reads wait until `.idle` has held for `idleDelay`, `.current` cancels the
    /// jobs still reading or waiting to (their files go back in the queue) and lets the decodes finish: their bytes
    /// are already here, and decodes take their own slot. `.current` also cancels the covers' thumbnail reads in flight
    /// (`coverCell` reads them again once idle). Home's covers start none while the viewer is not idle (the
    /// user is stepping through photos): `coverQueue` is paused, after the thumbnails' own state is set.
    public func setViewerActivity(_ activity: CacheActivity) async {
        setActivity(activity)
        await coverQueue.pause(activity != .idle)
    }

    private func setActivity(_ activity: CacheActivity) {
        self.activity = activity
        switch activity {
        case .idle:
            if idleSince == nil { idleSince = .now }
            pump()
        case .neighbours, .current:
            idleSince = nil
            idleWake?.cancel()
            idleWake = nil
            if activity == .current {
                cancelReads()
                cancelCoverReads()
            }
        }
    }

    // MARK: - Pictures

    /// The thumbnail at most `maxPixel` on its long side, from memory or the database; nil while it is not
    /// made (making it is the queue's business, not the caller's). Counts as an access for the size limit.
    /// Thumbnails are stored turned by the photo's EXIF orientation; with `applyingOrientation` false
    /// (`exif-orientation=no`) the cell is turned back to the stored layout, as the viewer shows the photo.
    public func cell(_ url: URL, maxPixel: Int, applyingOrientation: Bool = true) async -> CGImage? {
        let key = ThumbnailCells.Key(url: url, maxPixel: maxPixel, applyingOrientation: applyingOrientation)
        if let image = cells.image(key) {
            touch(url)
            used(url)
            return image
        }
        guard let (jpeg, info) = storedThumbnail(url) else {
            if !unavailable.contains(url) { missed.insert(url) }
            return nil
        }
        let epoch = cellEpoch
        let turnedBack = applyingOrientation ? ImageOrientation.up : info.orientation
        let image = await Self.offActor {
            ThumbnailMaker.decodeCell(jpeg, maxPixel: maxPixel).map { ThumbnailMaker.unturned($0, from: turnedBack) ?? $0 }
        }
        if let image, epoch == cellEpoch { cells.insert(image, for: key) }
        return image
    }

    /// The thumbnail at its stored size; nil while it is not made. The colour corrector's source (M3c spec §3.1),
    /// which waits for `onThumbnail` after a nil: a miss is remembered like a cell's, so one that turns up in the
    /// database is announced even with the strip hidden.
    public func image(_ url: URL) async -> CGImage? { await imageOrStatus(url).image }

    /// `image`, and with a nil image the file's `status`: `.unavailable` when the thumbnail cannot be made (the
    /// corrector stops waiting until `onThumbnail` tells of the file again). In the same turn of the actor as the miss,
    /// so an announcement of the file always comes after the answer.
    public func imageOrStatus(_ url: URL) async -> (image: CGImage?, status: ThumbnailStatus) {
        guard let jpeg = storedJPEG(url) else {
            if !unavailable.contains(url) { missed.insert(url) }
            return (nil, status(url))
        }
        let image = await Self.offActor { ThumbnailMaker.decodeImage(jpeg) }
        return (image, .ready)
    }

    /// The thumbnail of `url` as a level of its photo's pyramid, with the photo's stored `ImageInfo`, for
    /// `ImageCache.seed` (spec §5.1): from memory or the database only, never a read of the photo. Nil while it is
    /// not made, or when it does not fit the photo's aspect (`ThumbnailMaker.seedLevel`). Decoded off the actor
    /// like a cell, not in the viewer's decode slots: a ~50 KB JPEG and one resample, a few ms.
    public func seed(_ url: URL) async -> (info: ImageInfo, level: LevelImage)? {
        guard let (jpeg, info) = storedThumbnail(url) else { return nil }
        guard let level = await Self.offActor({ ThumbnailMaker.seedLevel(jpeg, info: info) }) else { return nil }
        return (info, level)
    }

    /// Width / height of the sources of those `urls` whose `ImageInfo` is known: thumbnails in memory, then
    /// the catalog (one query for the rest). As shown: turned by EXIF orientation like the thumbnails (M3b spec
    /// §2.2), or as stored when `applyingOrientation` is false (`exif-orientation=no`). The strip lays out
    /// native-aspect cells with these; `setOnThumbnail` says when another one may be known.
    public func aspects(_ urls: [URL], applyingOrientation: Bool = true) -> [URL: Double] {
        var result: [URL: Double] = [:]
        var byID: [Int64: URL] = [:]
        for url in urls {
            if let size = made[url]?.info.displaySize(applying: applyingOrientation) {
                if let aspect = Self.aspect(size) { result[url] = aspect }
            } else if let id = ids[url] {
                byID[id] = url
            }
        }
        if !byID.isEmpty, let sizes = perform("aspects", { try $0.displaySizes(Array(byID.keys), applyingOrientation: applyingOrientation) }) {
            for (id, size) in sizes {
                if let url = byID[id], let aspect = Self.aspect(size) { result[url] = aspect }
            }
        }
        return result
    }

    private static func aspect(_ size: PixelSize) -> Double? {
        size.width > 0 && size.height > 0 ? Double(size.width) / Double(size.height) : nil
    }

    public func status(_ url: URL) -> ThumbnailStatus {
        if made[url] != nil || stored.contains(url) { return .ready }
        return unavailable.contains(url) ? .unavailable : .pending
    }

    // MARK: - Settings and menu items

    /// A new thumbnail size voids every thumbnail (the database empties `Thumbs.db` on reopening at another
    /// size). A limit of 0 is the "no traces" setting: both databases are deleted and thumbnails live in
    /// memory from now on (those already there stay); back above 0, new databases are made and get them.
    /// Async: folders opened while memory only are located when the disk comes back.
    public func setSettings(thumbSize: Int, limitBytes: Int) async {
        defer { replan() }
        let sizeChanged = thumbSize != self.thumbSize
        let toMemory = self.limitBytes > 0 && limitBytes == 0
        if sizeChanged || limitBytes == 0 { closeDatabase() }
        if toMemory, let directory { ThumbnailDatabase.removeFiles(in: directory) }
        self.thumbSize = thumbSize
        self.limitBytes = limitBytes
        if sizeChanged {
            cancelJobs()   // their results would be the old size: `finish` drops them
            removeAllMade()
            uncommitted = []
            unavailable = []
            evicted = []
            forgetCells()
        }
        guard wantsDisk else { disk = .none; return }
        if case .open = disk {
            if storedBytes > limitBytes { enforceLimit() }
            return
        }
        disk = .unopened
        // Folders opened while memory only were never located.
        for (dir, folder) in folders where folder.location == nil {
            guard let sample = folder.listing.first?.url, let location = await location(of: dir, sample: sample) else { continue }
            folders[dir]?.location = location
        }
        resyncFolders()   // which also queues what memory holds for the database
    }

    /// "Clean Up Thumbnails": drops the catalog rows (and thumbnails) of files that are gone from volumes
    /// mounted now. Listing every catalogued folder takes a while on a share, so only that runs off the
    /// actor (strips keep getting their cells meanwhile); the rows are read and deleted on the store's own
    /// connection, the one writer (spec §3.2).
    public func cleanUp() async {
        defer { replan() }
        guard database() != nil else { return }
        commit()
        guard let rows = perform("clean-up", { try $0.catalogedFiles() }) else { return }
        let epoch = databaseEpoch
        let gone = await Self.offActor { () -> [Int64] in
            let files = MountedFiles()
            return rows.filter { files.isPresent($0.location) == false }.map(\.id)
        }
        // Databases made anew meanwhile number their files afresh: these ids would hit other files.
        guard !gone.isEmpty, epoch == databaseEpoch, case .open = disk else { return }
        _ = perform("clean-up", { try $0.deleteFiles(gone) })
        if let bytes = perform("count", { try $0.storedBytes() }) { storedBytes = bytes }
        refreshStored()
    }

    /// "Clear Thumbnail Cache": every thumbnail goes, in memory and in `Thumbs.db` (the catalog stays); the
    /// open folders' thumbnails are made again.
    public func clear() async {
        defer { replan() }
        commitTimer?.cancel()
        commitTimer = nil
        uncommitted = []
        touched = []
        if perform("clear", { try $0.clearThumbnails() }) != nil { storedBytes = 0 }
        removeAllMade()
        stored = []
        unavailable = []
        evicted = []
        forgetCells()
    }

    // MARK: - Folders

    var wantsDisk: Bool { directory != nil && limitBytes > 0 }

    static func listings(_ files: [URL], _ stamps: [URL: FileStamp]) -> [URL: [ListedFile]] {
        var result: [URL: [ListedFile]] = [:]
        for url in files {
            guard let stamp = stamps[url] else { continue }
            result[url.deletingLastPathComponent(), default: []].append(ListedFile(url: url, stamp: stamp))
        }
        return result
    }

    /// The folder's place in the catalog, resolved off the actor and once per folder (concurrent asks share
    /// the lookup). A share's comes from the mount table, no I/O (`shareLocate`); a failure is not remembered: the
    /// next listing of the folder tries again.
    func location(of dir: URL, sample: URL) async -> ThumbnailLocation? {
        if let known = locations[dir] { return known }
        if let share = shareLocate(sample) {
            locations[dir] = share
            shareLocated.insert(dir)
            return share
        }
        if let task = locating[dir] { return await task.value }
        let locate = self.locate
        let task = Task.detached(priority: .utility) { locate(sample) }
        locating[dir] = task
        let result = await task.value
        locating[dir] = nil
        if let result { locations[dir] = result }
        return result
    }

    /// A folder (re)listed: what changed or left is forgotten, failures get another try (spec §3.7), and the
    /// catalog learns the listing.
    func open(_ dir: URL, _ listing: [ListedFile], location: ThumbnailLocation?, partial: Bool = false,
              kept: Set<String> = []) {
        let stamps = Dictionary(listing.map { ($0.url, $0.stamp) }, uniquingKeysWith: { first, _ in first })
        // Served from the catalog before its stamps (`openProvisional`): the stamps it was catalogued at are its
        // listing's, so only what changed since is forgotten, and told to the caller.
        let wasProvisional = folders[dir]?.provisional == true
        if wasProvisional { provisional.subtract(folders[dir]?.listing.map(\.url) ?? []) }
        // Changed or gone: whatever was made of it, in memory or as a cell, shows the old picture.
        for file in folders[dir]?.listing ?? [] where stamps[file.url] != file.stamp {
            listed[file.url] = nil
            ids[file.url] = nil
            stored.remove(file.url)
            forget(file.url)
            if wasProvisional { provisionalChanged.insert(file.url) }
        }
        for file in listing {
            listed[file.url] = file.stamp
            unavailable.remove(file.url)
            evicted.remove(file.url)
            if let thumbnail = made[file.url], thumbnail.stamp != file.stamp { forget(file.url) }
        }
        folders[dir] = Folder(listing: listing, location: location, partial: partial, kept: kept)
        if !checkReopen() { sync(dir) }
    }

    /// The folder's ids and stored thumbnails from the catalog.
    func sync(_ dir: URL) {
        guard let folder = folders[dir], let location = folder.location else { return }
        // Names only: read again, never written.
        guard !folder.provisional else {
            return lookUpProvisional(dir, folder.asked, location: location, fresh: true)
        }
        let files = folder.listing.map { (name: $0.url.lastPathComponent, stamp: $0.stamp) }
        guard let (names, have) = perform("sync", { db -> ([String: Int64], Set<Int64>) in
            let names = try db.sync(folder: location, files: files, removingOthers: !folder.partial,
                                    keeping: folder.kept)
            return (names, try db.hasThumbnail(Array(names.values)))
        }) else { return }
        // Synced under the mount table's key: it holds for the session (`knowLocation` leaves it).
        shareLocated.remove(dir)
        for file in folder.listing {
            guard let id = names[file.url.lastPathComponent] else { continue }
            ids[file.url] = id
            if have.contains(id) { stored.insert(file.url) } else { stored.remove(file.url) }
            // Made while there was no id for it (memory only, a catalog made anew): the database gets it now.
            if made[file.url]?.stamp == file.stamp { uncommitted.insert(file.url) }
        }
        if !uncommitted.isEmpty { scheduleCommit() }
        for url in missed where stored.contains(url) {
            missed.remove(url)
            onThumbnail?(url)
        }
    }

    func resyncFolders() {
        for dir in folders.keys { sync(dir) }
    }

    /// Folders no window shows any more leave the maps (their thumbnails still waiting for a batch are
    /// written first, while their ids are known). Memory-only thumbnails stay: memory is all they have (up to
    /// `memoryCap`, least recently used out first).
    func closeUnshownFolders() {
        var shown = Set(windows.values.flatMap(\.listings.keys)).union(windows.values.flatMap(\.provisional))
        if let walk = walkWindow { shown.formUnion(walk.listings.keys) }
        let gone = folders.filter { !shown.contains($0.key) }
        guard !gone.isEmpty else { return }
        let goneFiles = gone.values.flatMap { $0.listing.map(\.url) }
        if goneFiles.contains(where: uncommitted.contains) { commit() }
        for url in goneFiles {
            listed[url] = nil
            ids[url] = nil
            stored.remove(url)
            unavailable.remove(url)
            evicted.remove(url)
            missed.remove(url)
            uncommitted.remove(url)
            provisional.remove(url)
            provisionalChanged.remove(url)
        }
        for dir in gone.keys { folders[dir] = nil }
    }

    // MARK: - Helpers

    func forget(_ url: URL) {
        removeMade(url)
        uncommitted.remove(url)
        cells.remove(url)
        cellEpoch += 1   // a decode of the old JPEG still running must not be cached
    }

    func forgetCells() {
        cells.removeAll()
        cellEpoch += 1
    }

    /// Once per session on stderr: the thumbnails keep working from memory, so a message per batch would
    /// only be noise.
    func warn(_ message: String) {
        guard !warned else { return }
        warned = true
        FileHandle.standardError.write(Data("loupe: \(message)\n".utf8))
    }

    /// Short blocking work (an ImageIO decode of a ~50 KB JPEG, the clean-up) on a GCD thread, so neither the
    /// actor nor the decode slots the viewer needs are held by it.
    static func offActor<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                      _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
        }
    }
}
