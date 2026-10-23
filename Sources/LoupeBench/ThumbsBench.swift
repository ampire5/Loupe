import Darwin
import Foundation
import LoupeCore

// LoupeBench thumbs [--from N] [--limit N] [--reads 1|2] [--decodes N] [--size PX] <folder>
// LoupeBench thumbs --covers [--listings N] [--decodes N] [--size PX] <folder>
// LoupeBench thumbs --ahead [--listings N] [--decodes N] [--size PX] <folder>
//
// Generates the thumbnails of a folder (files `from` ..< `from + limit` in Finder order) the way the app does with
// the viewer idle: a real ThumbnailStore with the real FileReader (4 threads, as in the app) and DecodePool, its
// databases in a fresh temporary
// directory (never under /Volumes; deleted afterwards). Reads go with F_NOCACHE, so a run measures the server, not
// the client's page cache; to compare settings, run each on files no earlier run has read. Prints thumbnails made
// per second (files that could not be made do not count), MB/s of whole files, and the store's per-file read and
// decode times.
//
// With --covers: Home's folder cards of every subfolder of <folder> (Finder order, the first 12 visible, the rest the
// margin), made through a CoverQueue with `listings` covers at a time and `ThumbnailStore.folderCard` (listed with
// dates on a local volume, four photos picked, their thumbnails made and kept in the catalog, the folder's summary
// with them), then once more from a fresh store on the same catalog (the next session: a fresh summary and the four
// thumbnails, no listing, no read). Between the two, a pass on the catalog with its summaries removed: the first launch
// after folder cards came (pictures from the catalog, each folder listed for its summary). Each card gets its folder's
// date as the parent's listing gives it; a card whose summary is pending (pictures from the catalog at once) stays in
// the queue for its follow-up, as Home's does. Prints covers per second, the time until the first 12 cards have their
// pictures and until they have their summary, and the process's CPU time per pass.
//
// With --ahead (thumbs-ahead spec, stage 4): the same cards, on a fresh catalog each pass, without and then with the
// work ahead: once a card in view (the first 12) is done, its subfolders' names come from the store
// (`subfolderNames`, never a listing) and go to the queue's `ahead` tier, each made by `folderCard` at the date
// `subfolderModified` gives, as Home does. Prints the time until the cards are done, until every subfolder of the
// cards in view has its cover, and the peak cores busy (process CPU over 250 ms windows) while the cards were made
// and over the whole pass.

enum ThumbsBench {
    static let usage = "usage: LoupeBench thumbs [--from N] [--limit N] [--reads 1|2] [--decodes N] [--size PX] <folder>\n"
        + "       LoupeBench thumbs --covers [--listings N] [--decodes N] [--size PX] <folder>\n"
        + "       LoupeBench thumbs --ahead [--listings N] [--decodes N] [--size PX] <folder>"

    struct Options {
        var folder = ""
        var from = 0
        var limit = Int.max
        var reads = ThumbnailStore.maxReads
        var decodes = ThumbnailStore.defaultDecodes
        var size = 512
        var covers = false
        var ahead = false
        var listings = CoverQueue.listingLimit
    }

    static func main(_ arguments: [String]) -> Never {
        let options = parse(arguments)
        Task {
            if options.ahead {
                await runAhead(options)
            } else if options.covers {
                await runCovers(options)
            } else {
                await run(options)
            }
            exit(0)
        }
        dispatchMain()
    }

    private static func parse(_ arguments: [String]) -> Options {
        var o = Options()
        var args = arguments[...]
        var folder: String?
        func number(_ name: String, min: Int) -> Int {
            guard let v = args.popFirst(), let n = Int(v), n >= min else { fail("\(name) needs an integer >= \(min)") }
            return n
        }
        while let arg = args.popFirst() {
            switch arg {
            case "--from": o.from = number(arg, min: 0)
            case "--limit": o.limit = number(arg, min: 1)
            case "--reads":
                o.reads = number(arg, min: 1)
                guard o.reads <= ThumbnailStore.maxReads else { fail("--reads is 1 or \(ThumbnailStore.maxReads)") }
            case "--decodes": o.decodes = number(arg, min: 1)
            case "--size": o.size = number(arg, min: 16)
            case "--covers": o.covers = true
            case "--ahead": o.ahead = true
            case "--listings": o.listings = number(arg, min: 1)
            case _ where arg.hasPrefix("--"): fail("unknown option \(arg)\n\(usage)")
            default:
                guard folder == nil else { fail(usage) }
                folder = arg
            }
        }
        guard let folder else { fail(usage) }
        o.folder = folder
        return o
    }

    /// One line of the store's log: `thumb <name>: read X ms (<source>), decode Y ms`.
    struct FileTiming {
        let read: Double
        let decode: Double
        let source: String

        init?(_ line: String) {
            let parts = line.split(separator: " ")
            guard let r = parts.firstIndex(of: "read"), r + 3 < parts.count, let read = Double(parts[r + 1]),
                  let d = parts.firstIndex(of: "decode"), d + 1 < parts.count, let decode = Double(parts[d + 1]) else { return nil }
            self.read = read
            self.decode = decode
            source = parts[r + 3].trimmingCharacters(in: CharacterSet(charactersIn: "(),"))
        }
    }

    private static func run(_ o: Options) async {
        let folder = URL(fileURLWithPath: o.folder)
        let all = imageFiles(at: o.folder)
        let files = Array(all.dropFirst(o.from).prefix(o.limit))
        guard !files.isEmpty else { fail("no image files in \(o.folder) from \(o.from)") }
        var stamps: [URL: FileStamp] = [:]
        for url in files {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { fail("cannot stat \(url.path)") }
            stamps[url] = FileStamp(modified: modified, size: size)
        }
        let bytes = stamps.values.reduce(0) { $0 + $1.size }

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-thumbs-bench-\(UUID().uuidString)")
        if cacheDir.standardizedFileURL.path.hasPrefix("/Volumes/") { fail("refusing to write under /Volumes: \(cacheDir.path)") }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let reader = FileReader(threads: 4, chunkReader: { fd, buffer, count, offset in
            if offset == 0 { _ = fcntl(fd, F_NOCACHE, 1) }
            return FileReader.pread(fd, buffer, count, offset)
        })
        let lines = LockedLines()
        let store = ThumbnailStore(directory: cacheDir, reader: reader, thumbSize: o.size,
                                   limitBytes: 2 << 30, idleDelay: .zero, readLimit: o.reads, decodes: o.decodes, log: { lines.add($0) })
        let resolved = LockedLines()   // ready or unavailable: the run is over when every file is one
        await store.setOnThumbnail { resolved.add($0.path) }

        let start = ContinuousClock.now
        await store.setRequest(window: 1, ThumbnailRequest(files: files, current: 0, visible: [], isKey: true), stamps: stamps)
        let deadline = start + .seconds(60 + 5 * files.count)
        while Set(resolved.all).count < files.count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let seconds = msSince(start) / 1000
        var finished = 0, unavailable = 0
        for url in files {
            switch await store.status(url) {
            case .ready: finished += 1
            case .unavailable: unavailable += 1
            case .pending: break
            }
        }
        await store.setRequest(window: 1, nil, stamps: [:])   // the last batch goes to the database

        var read = Samples(), decode = Samples()
        var sources: [String: Int] = [:]
        for timing in lines.all.compactMap(FileTiming.init) {
            read.add(timing.read)
            decode.add(timing.decode)
            sources[timing.source, default: 0] += 1
        }
        func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "–" }
        print("### thumbs \(folder.lastPathComponent) files \(o.from)..<\(o.from + files.count), reads \(o.reads), decodes \(o.decodes), "
              + "size \(o.size), F_NOCACHE\n")
        print("| files | made | unavailable | MB | s | files/s | MB/s | read ms p50 / p90 | decode ms p50 / p90 | sources |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        let mb = Double(bytes) / 1e6
        let source = sources.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("| \(files.count) | \(finished) | \(unavailable) | \(String(format: "%.0f", mb)) | \(String(format: "%.1f", seconds)) "
              + "| \(String(format: "%.2f", Double(finished) / seconds)) | \(String(format: "%.1f", mb / seconds)) "
              + "| \(f(read.median)) / \(f(read.percentile(90))) | \(f(decode.median)) / \(f(decode.percentile(90))) "
              + "| \(source.isEmpty ? "–" : source) |")
        print()
    }
}

extension ThumbsBench {
    private static func runCovers(_ o: Options) async {
        let root = URL(fileURLWithPath: o.folder)
        // As Home's listing of the folder gives them: each subfolder with its date.
        let listed = ((try? FolderSiblings.listEntries(root)) ?? []).filter { $0.isDirectory && !$0.isPackage }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        let subfolders = listed.map(\.url)
        let dates = Dictionary(listed.map { ($0.url.path, $0.modified) }, uniquingKeysWith: { a, _ in a })
        guard !subfolders.isEmpty else { fail("no subfolders in \(o.folder)") }
        let firstCards = min(12, subfolders.count)

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-covers-bench-\(UUID().uuidString)")
        if cacheDir.standardizedFileURL.path.hasPrefix("/Volumes/") { fail("refusing to write under /Volumes: \(cacheDir.path)") }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let reader = FileReader(threads: 4, chunkReader: { fd, buffer, count, offset in
            if offset == 0 { _ = fcntl(fd, F_NOCACHE, 1) }
            return FileReader.pread(fd, buffer, count, offset)
        })

        print("### covers: \(subfolders.count) subfolders, listings \(o.listings), decodes \(o.decodes), size \(o.size), F_NOCACHE\n")
        print("| pass | covers | pictures | summaries | first \(firstCards) pictures s | first \(firstCards) summaries s "
              + "| s | covers/s | CPU s | cores busy |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        for pass in ["made", "no summaries", "catalog"] {
            if pass == "no summaries" {
                // The first launch after the update: the catalog has the thumbnails, no summary yet.
                guard let catalog = try? SQLiteConnection(path: cacheDir.appendingPathComponent("Catalog.db").path,
                                                          pragmas: []),
                      (try? catalog.execute("DELETE FROM folder_summaries")) != nil else {
                    fail("cannot clear the summaries in \(cacheDir.path)")
                }
                catalog.close()
            }
            let store = ThumbnailStore(directory: cacheDir, reader: reader, thumbSize: o.size, limitBytes: 2 << 30,
                                       idleDelay: .zero, decodes: o.decodes)
            let queue = CoverQueue(listingLimit: o.listings, resumeDelay: .zero)
            let times = CardTimes()
            let ids = subfolders.map(\.path)
            let firstIDs = Set(ids.prefix(firstCards))
            let cpu = cpuTimeMs()
            let start = ContinuousClock.now
            var place = await store.folderLocation(root)
            // The app asks again later; a bench waits, but not for good: three local time limits at most.
            let resolveDeadline = start + ThumbnailStore.coverLocalListingTimeout * 3
            while place == .notNow {
                guard ContinuousClock.now < resolveDeadline else { fail("\(o.folder) did not resolve in time") }
                try? await Task.sleep(for: .milliseconds(100))
                place = await store.folderLocation(root)
            }
            let shown: ThumbnailLocation?, network: Bool
            switch place {
            case .located(let location): (shown, network) = (location, location.isNetwork)
            case .unknown(let onShare): (shown, network) = (nil, onShare)
            case .notNow: fail("cannot resolve \(o.folder)")
            }
            await queue.want(ids, visible: firstCards, isNetwork: { _ in network }) { id in
                let folder = URL(fileURLWithPath: id, isDirectory: true)
                guard let card = await store.folderCard(folder, archive: false,
                                                        in: shown?.subfolder(folder.lastPathComponent),
                                                        network: network, maxPixel: 256,
                                                        modified: dates[id] ?? nil) else { return false }
                // As Home will: the pictures as they come; a card whose summary is pending stays in the queue ("not
                // done"), which asks again at its pace (`CoverQueue.defaultRetryDelay`).
                times.pictures(id, card.images.count, at: msSince(start))
                guard !card.summaryPending else { return false }
                times.done(id, summary: card.summary != nil, at: msSince(start))
                return true
            }
            let deadline = start + .seconds(60 + 5 * ids.count)
            while times.doneCount < ids.count, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let seconds = msSince(start) / 1000, cpuUsed = (cpuTimeMs() - cpu) / 1000
            func first(_ at: [String: Double]) -> String {
                let firsts = firstIDs.compactMap { at[$0] }
                return firsts.count == firstCards ? String(format: "%.2f", firsts.max()! / 1000) : "–"
            }
            print("| \(pass) | \(times.doneCount) | \(times.pictureCount) | \(times.summaryCount) "
                  + "| \(first(times.picturesAt)) | \(first(times.summariesAt)) | \(String(format: "%.2f", seconds)) "
                  + "| \(String(format: "%.1f", Double(times.doneCount) / seconds)) | \(String(format: "%.1f", cpuUsed)) "
                  + "| \(String(format: "%.1f", cpuUsed / seconds)) |")
            // The summaries go to the catalog with the store's next batch (`commitDelay`, 1 s): before the next session.
            try? await Task.sleep(for: .seconds(1.5))
        }
        print()
    }
}

extension ThumbsBench {
    private static func runAhead(_ o: Options) async {
        let root = URL(fileURLWithPath: o.folder)
        let listed = ((try? FolderSiblings.listEntries(root)) ?? []).filter { $0.isDirectory && !$0.isPackage }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        let dates = Dictionary(listed.map { ($0.url.path, $0.modified) }, uniquingKeysWith: { a, _ in a })
        let ids = listed.map(\.url.path)
        guard !ids.isEmpty else { fail("no subfolders in \(o.folder)") }
        let visible = min(12, ids.count)
        print("### ahead: \(ids.count) cards, \(visible) in view, listings \(o.listings), decodes \(o.decodes), "
              + "size \(o.size), F_NOCACHE\n")
        print("| pass | cards s | subfolders | subfolders covered | all subfolders s | peak cores (cards) "
              + "| peak cores (pass) | CPU s |")
        print("|---|---|---|---|---|---|---|---|")
        for withAhead in [false, true] {
            let cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("loupe-ahead-bench-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: cacheDir) }
            let reader = FileReader(threads: 4, chunkReader: { fd, buffer, count, offset in
                if offset == 0 { _ = fcntl(fd, F_NOCACHE, 1) }
                return FileReader.pread(fd, buffer, count, offset)
            })
            let store = ThumbnailStore(directory: cacheDir, reader: reader, thumbSize: o.size, limitBytes: 2 << 30,
                                       idleDelay: .zero, decodes: o.decodes)
            let queue = CoverQueue(listingLimit: o.listings, resumeDelay: .zero)
            guard case .located(let shown) = await store.folderLocation(root) else { fail("cannot resolve \(o.folder)") }
            let state = AheadState()
            let sampler = CoreSampler()
            sampler.start()
            let start = ContinuousClock.now
            let work: @Sendable (String) async -> Bool = { id in
                let folder = URL(fileURLWithPath: id, isDirectory: true)
                if let parent = state.parent(of: id) {
                    let location = shown.subfolder(parent).subfolder(folder.lastPathComponent)
                    guard case .known(let modified) = await store.subfolderModified(folder, in: location)
                    else { return false }
                    guard let card = await store.folderCard(folder, archive: false, in: location, maxPixel: 16,
                                                            modified: modified) else { return false }
                    guard !card.summaryPending else { return false }
                    state.subfolderDone(id, covered: !card.images.isEmpty, at: msSince(start))
                    return true
                }
                let location = shown.subfolder(folder.lastPathComponent)
                guard let card = await store.folderCard(folder, archive: false, in: location, maxPixel: 256,
                                                        modified: dates[id] ?? nil) else { return false }
                guard !card.summaryPending else { return false }
                if withAhead, ids.prefix(visible).contains(id),
                   let names = await store.subfolderNames(of: folder, in: location) {
                    state.add(names.map { folder.appendingPathComponent($0).path }, parent: folder.lastPathComponent)
                }
                state.cardDone(id, at: msSince(start))
                return true
            }
            var sentAhead = -1
            let deadline = start + .seconds(120 + 5 * ids.count)
            while ContinuousClock.now < deadline {
                let ahead = state.aheadIDs
                if ahead.count != sentAhead {
                    sentAhead = ahead.count
                    await queue.want(ids, visible: visible, ahead: ahead, isNetwork: { _ in false }, work: work)
                }
                if state.cardsDone == ids.count, !withAhead || state.subfoldersDone == ahead.count { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            let seconds = msSince(start) / 1000
            let cardsAt = state.cardsAt / 1000
            sampler.stop()
            let cpu = sampler.cpuSeconds
            func f(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }
            print("| \(withAhead ? "with ahead" : "cards only") | \(f(cardsAt)) | \(state.aheadIDs.count) "
                  + "| \(state.covered) | \(withAhead ? f(seconds) : "–") | \(f(sampler.peak(until: cardsAt), 1)) "
                  + "| \(f(sampler.peak(until: .infinity), 1)) | \(f(cpu, 1)) |")
            await queue.want([], visible: 0, isNetwork: { _ in false }) { _ in true }
            try? await Task.sleep(for: .seconds(1.5))
        }
        print()
    }
}

/// The work ahead of an `--ahead` pass: each subfolder's parent card, and when cards and subfolders were done.
final class AheadState: @unchecked Sendable {
    private let lock = NSLock()
    private var parents: [String: String] = [:]
    private var order: [String] = []
    private var cards: [String: Double] = [:]
    private var subfolders: [String: Bool] = [:]

    func add(_ ids: [String], parent: String) {
        lock.withLock {
            for id in ids where parents[id] == nil {
                parents[id] = parent
                order.append(id)
            }
        }
    }

    func parent(of id: String) -> String? { lock.withLock { parents[id] } }
    func cardDone(_ id: String, at ms: Double) { lock.withLock { cards[id] = ms } }
    func subfolderDone(_ id: String, covered: Bool, at ms: Double) { lock.withLock { subfolders[id] = covered } }
    var aheadIDs: [String] { lock.withLock { order } }
    var cardsDone: Int { lock.withLock { cards.count } }
    var cardsAt: Double { lock.withLock { cards.values.max() ?? 0 } }
    var subfoldersDone: Int { lock.withLock { subfolders.count } }
    var covered: Int { lock.withLock { subfolders.values.filter { $0 }.count } }
}

/// The process's CPU time sampled every 250 ms: the cores busy in each window.
final class CoreSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [(end: Double, cores: Double)] = []
    private var task: Task<Void, Never>?
    private var first = 0.0, last = 0.0

    func start() {
        let begin = ContinuousClock.now
        first = cpuTimeMs()
        task = Task.detached(priority: .high) { [self] in
            var previous = first
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let now = cpuTimeMs()
                let at = msSince(begin) / 1000
                lock.withLock { windows.append((at, (now - previous) / 250)) }
                previous = now
            }
        }
    }

    func stop() {
        task?.cancel()
        last = cpuTimeMs()
    }

    var cpuSeconds: Double { (last - first) / 1000 }

    /// The busiest window that ended by `seconds` (and the one it was in).
    func peak(until seconds: Double) -> Double {
        lock.withLock {
            var best = 0.0
            for window in windows {
                best = max(best, window.cores)
                if window.end >= seconds { break }
            }
            return best
        }
    }
}

/// When each card had its pictures and its summary, from the cover queue's tasks.
final class CardTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [String: (count: Int, at: Double)] = [:]
    private var finished: [String: (summary: Bool, at: Double)] = [:]

    /// The first delivery with pictures counts.
    func pictures(_ id: String, _ count: Int, at ms: Double) {
        lock.withLock { if shown[id] == nil, count > 0 { shown[id] = (count, ms) } }
    }

    func done(_ id: String, summary: Bool, at ms: Double) { lock.withLock { finished[id] = (summary, ms) } }

    var doneCount: Int { lock.withLock { finished.count } }
    var pictureCount: Int { lock.withLock { shown.values.reduce(0) { $0 + $1.count } } }
    var summaryCount: Int { lock.withLock { finished.values.filter(\.summary).count } }
    var picturesAt: [String: Double] { lock.withLock { shown.mapValues(\.at) } }
    var summariesAt: [String: Double] {
        lock.withLock { finished.filter(\.value.summary).mapValues(\.at) }
    }
}

/// Lines collected from other threads.
final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
