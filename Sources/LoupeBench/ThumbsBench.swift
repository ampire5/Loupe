import Darwin
import Foundation
import LoupeCore

// LoupeBench thumbs [--from N] [--limit N] [--reads 1|2] [--size PX] <folder>
//
// Generates the thumbnails of a folder (files `from` ..< `from + limit` in Finder order) the way the app does with
// the viewer idle: a real ThumbnailStore with the real FileReader (4 threads, as in the app) and DecodePool, its
// databases in a fresh temporary
// directory (never under /Volumes; deleted afterwards). Reads go with F_NOCACHE, so a run measures the server, not
// the client's page cache; to compare settings, run each on files no earlier run has read. Prints thumbnails made
// per second (files that could not be made do not count), MB/s of whole files, and the store's per-file read and
// decode times.

enum ThumbsBench {
    static let usage = "usage: LoupeBench thumbs [--from N] [--limit N] [--reads 1|2] [--size PX] <folder>"

    struct Options {
        var folder = ""
        var from = 0
        var limit = Int.max
        var reads = ThumbnailStore.maxReads
        var size = 512
    }

    static func main(_ arguments: [String]) -> Never {
        let options = parse(arguments)
        Task {
            await run(options)
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
            case "--size": o.size = number(arg, min: 16)
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
        let store = ThumbnailStore(directory: cacheDir, reader: reader, pool: DecodePool(), thumbSize: o.size,
                                   limitBytes: 2 << 30, idleDelay: .zero, readLimit: o.reads, log: { lines.add($0) })
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
        print("### thumbs \(folder.lastPathComponent) files \(o.from)..<\(o.from + files.count), reads \(o.reads), "
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

/// Lines collected from other threads.
final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
