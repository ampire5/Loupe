import Darwin
import Foundation
import LoupeCore

// LoupeBench thumbs [--from N] [--limit N] [--reads 1|2] [--decodes N] [--size PX] <folder>
// LoupeBench thumbs --covers [--listings N] [--decodes N] [--size PX] <folder>
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
// thumbnails, no listing, no read). Each card gets its folder's date as the parent's listing gives it. Prints covers
// per second, the time until the first 12 cards have their cover and summary, and the process's CPU time per pass.

enum ThumbsBench {
    static let usage = "usage: LoupeBench thumbs [--from N] [--limit N] [--reads 1|2] [--decodes N] [--size PX] <folder>\n"
        + "       LoupeBench thumbs --covers [--listings N] [--decodes N] [--size PX] <folder>"

    struct Options {
        var folder = ""
        var from = 0
        var limit = Int.max
        var reads = ThumbnailStore.maxReads
        var decodes = ThumbnailStore.defaultDecodes
        var size = 512
        var covers = false
        var listings = CoverQueue.listingLimit
    }

    static func main(_ arguments: [String]) -> Never {
        let options = parse(arguments)
        Task {
            if options.covers { await runCovers(options) } else { await run(options) }
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
        print("| pass | covers | pictures | summaries | first \(firstCards) s | s | covers/s | CPU s | cores busy |")
        print("|---|---|---|---|---|---|---|---|---|")
        for pass in ["made", "catalog"] {
            let store = ThumbnailStore(directory: cacheDir, reader: reader, thumbSize: o.size, limitBytes: 2 << 30,
                                       idleDelay: .zero, decodes: o.decodes)
            let queue = CoverQueue(listingLimit: o.listings, resumeDelay: .zero)
            let pictures = LockedLines(), summaries = LockedLines()
            let ids = subfolders.map(\.path)
            let firstIDs = Set(ids.prefix(firstCards)), firstDone = LockedLines()
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
                if card.summary != nil { summaries.add(id) }
                if firstIDs.contains(id) { firstDone.add(String(msSince(start))) }
                pictures.add("\(card.images.count)")
                return true
            }
            let deadline = start + .seconds(60 + 5 * ids.count)
            while pictures.all.count < ids.count, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let seconds = msSince(start) / 1000, cpuUsed = (cpuTimeMs() - cpu) / 1000
            let made = pictures.all.compactMap(Int.init).reduce(0, +)
            let first = firstDone.all.count == firstCards ? firstDone.all.compactMap(Double.init).max().map {
                String(format: "%.2f", $0 / 1000)
            } ?? "–" : "–"
            print("| \(pass) | \(pictures.all.count) | \(made) | \(summaries.all.count) | \(first) "
                  + "| \(String(format: "%.2f", seconds)) "
                  + "| \(String(format: "%.1f", Double(pictures.all.count) / seconds)) | \(String(format: "%.1f", cpuUsed)) "
                  + "| \(String(format: "%.1f", cpuUsed / seconds)) |")
            // The summaries go to the catalog with the store's next batch (`commitDelay`, 1 s): before the next session.
            try? await Task.sleep(for: .seconds(1.5))
        }
        print()
    }
}

/// Lines collected from other threads.
final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
