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
    /// Covers' reads and decodes go behind the open folders' thumbnails (`readPriority`) in the reader's queue and
    /// the decode slots.
    public static let coverReadPriority = readPriority + 1
    /// Thumbnails a cover makes at most: the four of a folder's mosaic.
    static let coverPhotos = 4
    /// Subfolders looked into below a folder without photos: its own, and theirs.
    static let coverDepth = 2
    /// Threads in a cover's blocking call (a listing, a resolve) at most, per lane (local volumes, shares), those
    /// given up on included: one hung on a dead share stays in the kernel. Past that the lane's covers are "not now"
    /// until one returns, so a share that hangs costs a few threads, not one per card, and never the local lane's. One
    /// more than the most `CoverQueue` runs at once in either lane.
    static let coverThreadsPerLane = 3
    /// How often a cover waiting for the viewer to go idle looks again (at most a few covers wait at once).
    static let coverIdlePoll: Duration = .milliseconds(50)
    /// The covers' threads: background work, below the viewer's and the open folders' thumbnails.
    static let coverQoS = DispatchQoS.QoSClass.utility

    /// Tests: a fake listing, and the share's time limit.
    func setCoverListing(_ lister: @escaping CoverLister, networkTimeout: Duration = coverListingTimeout) {
        coverLister = lister
        coverNetworkTimeout = networkTimeout
    }

    /// Where the catalog keeps `folder`'s files (`locate(folder/_)`), for its cards' covers (`subfolder`). Resolving
    /// asks the system (realpath, statfs), which can hang on a share: it runs on a thread of the share lane, and
    /// after `coverListingTimeout` (or a cancel) the answer is nil and the thread is left to finish alone.
    public func folderLocation(_ folder: URL) async -> ThumbnailLocation? {
        let locate = self.locate
        let outcome = await Self.onThread(coverThreads, network: true, timeout: coverNetworkTimeout) {
            (_: @Sendable (ThumbnailLocation?) -> Bool) -> ThumbnailLocation? in
            locate(folder.appendingPathComponent("_"))
        }
        if case .value(let location, _) = outcome { return location }
        return nil
    }

    /// The pictures of a folder's or zip's card, at most `maxPixel` on their long side: up to four photos spread across
    /// it (the one last viewed there first). `location` is where the catalog keeps the folder's files (from the
    /// folder Home shows: `folderLocation(shown).subfolder(name)`; nil: none, and the volume is taken for a share).
    /// From the catalog when it has four of the folder's photos, else from a listing of names (limited to
    /// `coverListingTimeout` on a share) whose picks are made into thumbnails and kept in the catalog, like `cover`'s.
    /// A folder without photos shows one of each of its first four subfolders' (two levels down at most).
    ///
    /// Empty when there is nothing to show (a folder found empty is not listed again this session, nor one that
    /// cannot be listed); nil for "not now": the share's lane is full of hung calls, or its listing gave no name in
    /// time. Nothing here asks the system but the listing. New thumbnails wait while the viewer is busy; cancelling
    /// the task stops the listing and the reads.
    public func folderCover(_ folder: URL, archive: Bool, in location: ThumbnailLocation?, maxPixel: Int,
                            lastViewed: String? = nil) async -> [CGImage]? {
        await folderCover(folder, archive: archive, location: location, maxPixel: maxPixel, lastViewed: lastViewed,
                          count: Self.coverPhotos, depth: 0)
    }

    private func folderCover(_ folder: URL, archive: Bool, location: ThumbnailLocation?, maxPixel: Int,
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
        let network = location?.isNetwork ?? true
        let lister = coverLister
        let outcome = await Self.onThread(coverThreads, network: network, timeout: network ? coverNetworkTimeout : nil) {
            part in try lister(folder, archive, part)
        }
        let names: CoverNames, complete: Bool
        switch outcome {
        case .value(let listed, let ended): (names, complete) = (listed, ended)
        case .failed: return []
        case .notNow: return nil
        }
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
                                            location: location?.subfolder(name), maxPixel: maxPixel, lastViewed: nil,
                                            count: 1, depth: depth + 1)
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

    /// Runs blocking `work` on a thread of its own in the lane's place (`threads`), and waits for it at most `timeout`
    /// (nil: no limit) or until the task is cancelled, then gives up on it: the answer is what `work` handed to its
    /// `part` so far, and `part` returns false from then on so it can stop; the thread keeps its place until it
    /// returns. `.notNow` when the lane has no free place or nothing came in time.
    static func onThread<T: Sendable>(_ threads: CoverThreads, network: Bool, timeout: Duration?,
                                      _ work: @escaping @Sendable (_ part: @escaping @Sendable (T) -> Bool) throws -> T)
        async -> ThreadAnswer<T>.Outcome {
        guard threads.enter(network: network) else { return .notNow }
        let answer = ThreadAnswer<T>()
        DispatchQueue.global(qos: coverQoS).async {
            let result = Result { try work { answer.part($0) } }
            threads.leave(network: network)
            answer.finish(result)
        }
        typealias Race = ThreadAnswer<T>.Race
        return await withTaskGroup(of: Race.self, returning: ThreadAnswer<T>.Outcome.self) { group in
            group.addTask { .answered(await answer.value()) }
            if let timeout {
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return .timedOut
                }
            }
            // Whichever comes first: the timer stops the work, whose answer is then what it had so far.
            while let first = await group.next() {
                answer.stop()
                group.cancelAll()
                if case .answered(let outcome) = first { return outcome }
            }
            return .notNow
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
        /// No free thread, or given up on with nothing yet.
        case notNow
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
        return stopped ? .notNow : .failed
    }
}

/// Counts the threads in a cover's blocking call, per lane (local volumes, shares), up to `limit` in each.
final class CoverThreads: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var counts: [Bool: Int] = [:]

    init(limit: Int) { self.limit = limit }

    func enter(network: Bool) -> Bool {
        lock.withLock {
            guard counts[network, default: 0] < limit else { return false }
            counts[network, default: 0] += 1
            return true
        }
    }

    func leave(network: Bool) { lock.withLock { counts[network, default: 0] -= 1 } }

    /// Threads in a lane now, for tests.
    func count(network: Bool) -> Int { lock.withLock { counts[network, default: 0] } }
}
