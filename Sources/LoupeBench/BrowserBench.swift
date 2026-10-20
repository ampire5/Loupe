import Foundation
import LoupeCore

/// `LoupeBench browser [--runs N] <folder>…` (file browser spec §6): how long the Folders tab waits for a folder — the
/// names-only listing (what a sort by name shows first) and the full one (dates, sizes) — `--runs` times each (default
/// 3), the first run cold for a share's own caches only if nothing listed the folder before.
enum BrowserBench {
    static func main(_ arguments: [String]) -> Never {
        var runs = 3
        var folders: [URL] = []
        var args = arguments[...]
        while let arg = args.popFirst() {
            if arg == "--runs", let n = args.popFirst().flatMap(Int.init), n > 0 { runs = n; continue }
            folders.append(URL(fileURLWithPath: arg, isDirectory: true))
        }
        guard !folders.isEmpty else { fail("browser: no folder given") }
        print("folder\trun\tnames ms\tnames count\tfull ms\tfull count")
        for folder in folders {
            for run in 1...runs {
                let (names, namesMs) = time { try BrowserListingSource.names(folder, archives: true) }
                let (full, fullMs) = time { try BrowserListingSource.full(folder, archives: true) }
                print("\(folder.path)\t\(run)\t\(namesMs)\t\(names?.count ?? -1)\t\(fullMs)\t\(full?.count ?? -1)")
            }
        }
        exit(0)
    }

    private static func time<T>(_ body: () throws -> T) -> (T?, Int) {
        let start = ContinuousClock.now
        let value = try? body()
        return (value, Int((ContinuousClock.now - start) / .milliseconds(1)))
    }
}
