import Foundation
import FilmstripModel
import HomeScreenModel
import LoupeCore

// LoupeBench hotpaths [--files N] [--runs N] [--only NAME]
//
// The main-thread and cache-actor work that grows with the folder (audit, owner, 2026-10-28), on a synthetic folder of
// N files (default 50 000, as a big NAS folder) with half their sizes and aspects known: what one call of each costs,
// median of --runs (default 9) after one warm-up. No disk: the listing, the stamps and the facts are made up.
//   strip aspects   StripAspects on a fetch batch of 64 (each arrival in its place) and the "every unknown" filter
//                   of a fetch (the playlist's first fetch and its first cell picture only)
//   strip layout    StripController.relayout's FilmstripLayout for those aspects and its compare with the one shown
//   folder open     FolderRequest.playlist in the folder's sort (date-desc) on a remembered photo
//   folder reread   ViewerSession.apply's work on a re-read: the listed playlist in the folder's sort, replacing,
//                   the compare
//   home index      the Home grid's index of the shown files, built for one visible-range request
//   cache plan      CachePlan.make on a step, the facts looked up by URL as ImageCache does
//   zoom rules      a folder's ZoomRules from its values (Config.applying), as the viewer asks several times a frame

enum HotPathsBench {
    static func main(_ arguments: [String]) -> Never {
        var count = 50_000, runs = 9
        var only: String?
        var args = arguments[...]
        while let arg = args.popFirst() {
            switch arg {
            case "--files": count = args.popFirst().flatMap(Int.init) ?? count
            case "--runs": runs = args.popFirst().flatMap(Int.init) ?? runs
            case "--only": only = args.popFirst()
            default: fail("usage: LoupeBench hotpaths [--files N] [--runs N] [--only NAME]")
            }
        }
        let folder = URL(fileURLWithPath: "/Volumes/photos/2026/Session")
        let files = (0..<count).map { folder.appendingPathComponent(String(format: "IMG_%06d.jpg", $0)) }
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let stamps = Dictionary(uniqueKeysWithValues: files.enumerated().map {
            ($1, FileStamp(modified: base.addingTimeInterval(Double(($0 * 7919) % count)), size: 8_000_000 + $0))
        })
        var known: [URL: Double] = [:]
        for (i, url) in files.enumerated() where i % 2 == 0 { known[url] = i % 6 == 0 ? 0.75 : 1.5 }
        let sort = BrowserSort(text: "date-desc")!

        func measure(_ name: String, _ body: () -> Int) {
            // --only: the measures whose name starts so (a profile of one).
            if let only, !name.hasPrefix(only) { return }
            _ = body()
            var times: [Double] = []
            var sink = 0
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                sink &+= body()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            times.sort()
            print(String(format: "%-34@ %9.3f ms   (min %.3f, max %.3f)%@", name as NSString, times[times.count / 2],
                         times[0], times[times.count - 1], sink == .min ? " " : ""))
        }

        print("hotpaths: \(count) files, median of \(runs) runs")
        // A batch of 64 arrivals: each changes its own place (`StripAspects.positions`); it was files.map over all.
        let positions = Dictionary(files.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var shown = files.map { known[$0] }
        measure("strip aspects: a batch") {
            for url in files[(count / 2)..<(count / 2 + 64)] { if let i = positions[url] { shown[i] = 1.5 } }
            return shown.count
        }
        measure("strip aspects: unknown filter") { files.filter { known[$0] == nil }.count }
        let aspectList = files.map { known[$0] }
        let layout = FilmstripLayout(itemCount: count, length: 1800, thickness: 90, maxAspect: 2, aspects: aspectList)
        measure("strip layout") {
            let next = FilmstripLayout(itemCount: count, length: 1800, thickness: 90, maxAspect: 2, aspects: aspectList)
            return next == layout ? 1 : 0
        }
        let target = FolderTarget(folder: folder, images: files, stamps: stamps)
        let remembered = files[count / 2]
        measure("folder open") {
            FolderRequest.playlist(for: target, sort: sort) { _, _ in remembered }.files.count
        }
        let open = FolderRequest.playlist(for: target, sort: sort) { _, _ in remembered }
        // A re-read lists in the standard order (`Playlist.relist`) and changed nothing.
        let listed = Playlist(files: files, current: files[0], stamps: stamps)
        measure("folder reread") {
            let new = open.replacing(with: listed.sorted(sort))
            return new.files != open.files || new.stamps != open.stamps ? 1 : 0
        }
        measure("home index") {
            Dictionary(files.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a }).count
        }
        let facts = Dictionary(uniqueKeysWithValues: files.enumerated().map {
            ($1, EntryFacts(pixelSize: $0 % 2 == 0 ? PixelSize(width: 6000, height: 4000) : nil, fileSize: 8_000_000))
        })
        let focus = CacheFocus(count: count, current: count / 2, direction: 1, dwelling: false, needsFull: true,
                               screen: PixelSize(width: 3024, height: 1964))
        measure("cache plan") {
            CachePlan.make(focus: focus, limits: CacheLimits()) { facts[files[$0]] ?? EntryFacts() }.count
        }
        let values = ["browser-sort": "date-desc", "step-zoom": "subject", "subject-size": "70", "zoom-anchor": "subject"]
        measure("zoom rules") { ZoomRules(config: Config().applying(values).config).subjectSize > 0 ? 1 : 0 }
        exit(0)
    }
}
