import Darwin
import Foundation
import LoupeCore

// LoupeBench sharesim [--rounds N] [--neighbours N] [--link-mibps N] [--delay-ms N] [--flagless] <folder>
//
// The current photo's read against running neighbour reads on a share, simulated on local files (docs/bench/
// 2026-10-23-current-first.md): the app's FileReader (four threads, the viewer's two among them) on its chunked share
// path, every 1 MiB chunk holding one link shared by all reads for 1 MiB / link-mibps (10 ms at the default 100 MiB/s,
// a 1 GbE share). Each round reads `neighbours` files as neighbours (unflagged, plan ranks 3, 4, …), and `delay-ms`
// later the next file as the current photo (`ReadPriority.isCurrent`); it times the current read from its request to
// its bytes. `--flagless` asks for it unflagged, as one more neighbour. Rounds take the folder's files (Finder order)
// `neighbours + 1` at a time; the folder needs that many per round.

enum ShareSimBench {
    struct Options {
        var rounds = 6
        var neighbours = 3
        var linkMiBps = 100.0
        var delay = Duration.milliseconds(100)
        var flagless = false
        var folder = ""
    }

    static let usage = "usage: LoupeBench sharesim [--rounds N] [--neighbours N] [--link-mibps N] [--delay-ms N] "
        + "[--flagless] <folder>"

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
        func positive(_ name: String) -> Int {
            guard let v = args.popFirst(), let n = Int(v), n > 0 else { fail("\(name) needs a positive integer") }
            return n
        }
        while let arg = args.popFirst() {
            switch arg {
            case "--rounds": o.rounds = positive(arg)
            case "--neighbours": o.neighbours = positive(arg)
            case "--link-mibps": o.linkMiBps = Double(positive(arg))
            case "--delay-ms": o.delay = .milliseconds(positive(arg))
            case "--flagless": o.flagless = true
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

    /// One link all chunk reads take turns on.
    private final class Link: @unchecked Sendable {
        private let lock = NSLock()
        private let chunkMicros: UInt32
        init(miBps: Double) { chunkMicros = UInt32((1_000_000 / miBps).rounded()) }
        func pass() { lock.lock(); usleep(chunkMicros); lock.unlock() }
    }

    private static func run(_ o: Options) async {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: o.folder)) ?? [])
            .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let perRound = o.neighbours + 1
        guard names.count >= o.rounds * perRound else {
            fail("\(o.folder): \(names.count) images, \(o.rounds * perRound) needed (\(o.rounds) rounds of \(perRound))")
        }
        let folder = URL(fileURLWithPath: o.folder)
        var times: [Double] = []
        var lines: [String] = []
        for round in 0..<o.rounds {
            let files = names[(round * perRound)..<((round + 1) * perRound)].map { folder.appendingPathComponent($0) }
            let link = Link(miBps: o.linkMiBps)
            let reader = FileReader(threads: 4, timeout: .seconds(30), isLocal: { _ in false },
                                    chunkReader: { fd, buffer, count, offset in
                link.pass()
                return FileReader.pread(fd, buffer, count, offset)
            })
            let neighbours = files.dropLast().enumerated().map { i, url in
                Task { try await reader.read(url, priority: ReadPriority(3 + i)) }
            }
            try? await Task.sleep(for: o.delay)
            let priority = ReadPriority(0)
            priority.isCurrent = !o.flagless
            let start = ContinuousClock.now
            let bytes = try? await reader.read(files[files.count - 1], priority: priority)
            let ms = msSince(start)
            for task in neighbours { _ = try? await task.value }
            let mib = Double(bytes?.data.count ?? 0) / 1_048_576
            times.append(ms)
            lines.append(String(format: "| %d | %.1f | %.0f | %.0f |", round + 1, mib, mib / o.linkMiBps * 1000, ms))
        }
        let sorted = times.sorted()
        print("sharesim: \(o.neighbours) neighbours, current asked \(Int(o.delay / .milliseconds(1))) ms later, "
              + "link \(Int(o.linkMiBps)) MiB/s, current read \(o.flagless ? "unflagged" : "flagged")\n")
        print("| round | current MiB | alone ms | read ms |\n|---:|---:|---:|---:|")
        lines.forEach { print($0) }
        print(String(format: "\nmin %.0f, p50 %.0f, max %.0f ms", sorted.first ?? 0, sorted[sorted.count / 2],
                     sorted.last ?? 0))
    }
}
