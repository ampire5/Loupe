import Foundation
import LoupeCore

/// `LoupeBench marks [--photos N] [--runs N]` (photo-cards spec §4): the photo cards' marks of a folder of N photos
/// (default 10 000) as `FolderBrowserSource.sendPhotoMarks` makes them: the order (`Playlist` + `sorted`, off the main
/// thread in the app), then `PhotoMarks.pairs` and `PhotoMarks.unseen` (on it). Two pages on, `spread-landscape =
/// alone`, every seventh page wide; the remembered photo halfway.
enum MarksBench {
    static func main(_ arguments: [String]) -> Never {
        var photos = 10_000, runs = 5
        var args = arguments[...]
        while let arg = args.popFirst() {
            if arg == "--photos", let n = args.popFirst().flatMap(Int.init), n > 0 { photos = n; continue }
            if arg == "--runs", let n = args.popFirst().flatMap(Int.init), n > 0 { runs = n; continue }
            fail("marks: unknown argument \(arg)")
        }
        let folder = URL(fileURLWithPath: "/Volumes/T/x")
        let files = (0..<photos).map { folder.appendingPathComponent("p\($0).jpg") }
        let stamps = Dictionary(uniqueKeysWithValues: files.enumerated().map {
            ($1, FileStamp(modified: Date(timeIntervalSinceReferenceDate: Double($0)), size: 1))
        })
        let visit = FolderVisit(index: photos / 2, count: photos, visited: Date(timeIntervalSinceReferenceDate: Double(photos)))
        let rules = SpreadRules(on: true, options: SpreadOptions(shift: true, rightToLeft: false, landscapeAlone: true))
        let aspects: [Double?] = files.indices.map { $0 % 7 == 0 ? 1.5 : 0.7 }
        let remembered = "p\(photos / 2).jpg"
        print("run\torder ms\tpairs ms\tunseen ms")
        for run in 1...runs {
            let start = ContinuousClock.now
            let playlist = Playlist(files: files, current: files[0], stamps: stamps).sorted(.standard)
            let ordered = ContinuousClock.now
            let pairs = PhotoMarks.pairs(order: playlist.files, rules: rules, aspects: aspects)
            let paired = ContinuousClock.now
            let partner = playlist.files.first { $0.lastPathComponent == remembered }.flatMap { pairs[$0] }
            let unseen = PhotoMarks.unseen(order: playlist.files, remembered: remembered, visit: visit,
                                           modified: { playlist.stamps[$0]?.modified }, partner: partner)
            let end = ContinuousClock.now
            precondition(!unseen.isEmpty && !pairs.isEmpty)
            print("\(run)\t\(ms(ordered - start))\t\(ms(paired - ordered))\t\(ms(end - paired))")
        }
        exit(0)
    }

    private static func ms(_ d: Duration) -> String { String(format: "%.2f", Double(d / .microseconds(1)) / 1000) }
}
