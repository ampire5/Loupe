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

    /// Tests: a fake listing, and the time limits.
    func setCoverListing(_ lister: @escaping CoverLister, networkTimeout: Duration = coverListingTimeout,
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
        let locate = self.locate, network = coverVolumeIsNetwork(folder)
        let outcome = await Self.onThread(coverThreads, lane: CoverLane(network: network, resolving: true),
                                          timeout: network ? coverNetworkTimeout : coverLocalTimeout) {
            (_: @Sendable (ThumbnailLocation?) -> Bool) -> ThumbnailLocation? in
            locate(folder.appendingPathComponent("_"))
        }
        switch outcome {
        case .value(let location?, _): return .located(location)
        case .value(nil, _), .failed: return .unknown(network: network)
        case .busy, .timedOut: return .notNow
        }
    }

    /// Whether `url` is on a share, from the mount table the system keeps (`getfsstat` with `MNT_NOWAIT` asks no file
    /// system, so it never hangs): the mount point above its path, as written (a symlink to a share counts as local,
    /// which only costs it the local lane's time limit). True when no mount point matches.
    @Sendable static func mountIsNetwork(_ url: URL) -> Bool {
        let room = getfsstat(nil, 0, MNT_NOWAIT)
        guard room > 0 else { return true }
        let blank = statfs()
        var mounts = Array(repeating: blank, count: Int(room) + 4)
        let count = mounts.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        let path = url.standardizedFileURL.path
        var best: (length: Int, local: Bool)?
        for index in 0..<max(0, Int(count)) {
            let mountPoint = ThumbnailLocation.string(from: &mounts[index].f_mntonname)
            guard path == mountPoint || path.hasPrefix(mountPoint == "/" ? "/" : mountPoint + "/") else { continue }
            if mountPoint.count > best?.length ?? -1 {
                best = (mountPoint.count, mounts[index].f_flags & UInt32(MNT_LOCAL) != 0)
            }
        }
        return !(best?.local ?? false)
    }

    /// The pictures of a folder's or zip's card, at most `maxPixel` on their long side: up to four photos spread across
    /// it (the one last viewed there first). `location` is where the catalog keeps the folder's files (from the
    /// folder Home shows: `folderLocation(shown)`'s `.subfolder(name)`; nil: none). `network` says whether it is on a
    /// share when there is no location (`CoverPlace.unknown`); nil: from the location, or a share without one.
    /// From the catalog when it has four of the folder's photos, else from a listing of names (limited to
    /// `coverListingTimeout` on a share, `coverLocalListingTimeout` elsewhere) whose picks are made into thumbnails and
    /// kept in the catalog, like `cover`'s. A folder without photos shows one of each of its first four subfolders'
    /// (two levels down at most).
    ///
    /// Empty when there is nothing to show; then the folder is not listed again this session: found empty, not
    /// listable, or listed `coverTimeoutsAllowed` times without a name in time. Nil for "not now": its lane is full of
    /// hung calls, or its listing gave no name in time. Nothing here asks the system but the listing. New thumbnails
    /// wait while the viewer is busy; cancelling the task stops the listing and the reads.
    public func folderCover(_ folder: URL, archive: Bool, in location: ThumbnailLocation?, network: Bool? = nil,
                            maxPixel: Int, lastViewed: String? = nil) async -> [CGImage]? {
        await folderCover(folder, archive: archive, location: location, network: network ?? location?.isNetwork ?? true,
                          maxPixel: maxPixel, lastViewed: lastViewed, count: Self.coverPhotos, depth: 0)
    }

    private func folderCover(_ folder: URL, archive: Bool, location: ThumbnailLocation?, network: Bool, maxPixel: Int,
                             lastViewed: String?, count: Int, depth: Int) async -> [CGImage]? {
        guard !emptyCovers.contains(folder.standardizedFileURL.path) else { return [] }
        guard !Task.isCancelled else { return nil }
        if let location, let names = perform("cover", { try $0.namesWithThumbnails(in: location, limit: .max) }),
           names.count >= count {
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
        let lister = coverLister, key = folder.standardizedFileURL.path
        let outcome = await Self.onThread(coverThreads, lane: CoverLane(network: network, resolving: false),
                                          timeout: network ? coverNetworkTimeout : coverLocalTimeout) {
            part in try lister(folder, archive, part)
        }
        let names: CoverNames, complete: Bool
        switch outcome {
        case .value(let listed, let ended): (names, complete) = (listed, ended)
        case .failed:
            emptyCovers.insert(key)
            return []
        case .busy:
            return nil
        case .timedOut:
            coverTimeouts[key, default: 0] += 1
            guard coverTimeouts[key, default: 0] >= Self.coverTimeoutsAllowed else { return nil }
            coverTimeouts[key] = nil
            emptyCovers.insert(key)
            return []
        }
        coverTimeouts[key] = nil
        let plan = await Self.offActor(qos: Self.coverQoS) {
            CoverSampling.plan(names: Self.finderSorted(names.files), directories: Self.finderSorted(names.folders),
                               lastViewed: lastViewed)
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
            guard depth < Self.coverDepth else { return [] }
            var images: [CGImage] = [], notNow = false
            for name in subfolders where images.count < count && !Task.isCancelled {
                // One picture of each: the subfolder's own card makes the rest when it is shown.
                let sub = await folderCover(folder.appendingPathComponent(name, isDirectory: true), archive: false,
                                            location: location?.subfolder(name), network: network, maxPixel: maxPixel,
                                            lastViewed: nil, count: 1, depth: depth + 1)
                if let sub { images += sub.prefix(1) } else { notNow = true }
            }
            if notNow, images.count < count { return nil }
            let paths = subfolders.map { folder.appendingPathComponent($0).standardizedFileURL.path }
            if complete, paths.allSatisfy(emptyCovers.contains) { emptyCovers.insert(folder.standardizedFileURL.path) }
            return images
        case .empty:
            if complete { emptyCovers.insert(folder.standardizedFileURL.path) }
            return []
        }
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

    /// The real listing: a folder's names without a stat (`BrowserListingSource.names`), a zip's photo entries from
    /// one read of its directory. Photos (by extension) and folders; hidden names left out.
    @Sendable static func listCoverNames(_ folder: URL, archive: Bool,
                                         part: @escaping @Sendable (CoverNames) -> Bool) throws -> CoverNames {
        if archive || ArchivePath.isArchive(folder) {
            let entries = try ArchiveReader.shared.entries(of: folder)
            return CoverNames(files: entries.map(\.url.lastPathComponent), folders: [])
        }
        func names(_ entries: [BrowserEntry]) -> CoverNames {
            CoverNames(files: entries.filter { $0.kind == .file }.map(\.name),
                       folders: entries.filter { $0.kind == .folder }.map(\.name))
        }
        // Parts every 100 ms at most: what a time limit finds is never older than that.
        return names(try BrowserListingSource.names(folder, archives: false, partEvery: 64,
                                                    partAfter: .milliseconds(100)) { part(names($0)) })
    }
}

/// One blocking call of a cover on its thread, between the thread and the task waiting for it: what it handed over so
/// far, how it ended, and whether the waiter gave up on it (the thread then stops at its next `part`).
final class ThreadAnswer<T: Sendable>: @unchecked Sendable {
    enum Outcome: Sendable {
        /// All of it (`complete`), or what came before the waiter gave up.
        case value(T, complete: Bool)
        /// It threw, with nothing before.
        case failed
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
        return stopped ? .busy : .failed
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
