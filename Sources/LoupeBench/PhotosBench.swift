import Darwin
import Foundation
import HomeScreenModel
import LoupeCore

/// Synthetic sequence costs only: no Photos authorization, personal library, image requests or UI.
/// The real signed-app/Intel/iCloud checklist lives in docs/benchmarks/photos-albums.md.
enum PhotosBench {
    static func main(_ arguments: [String]) -> Never {
        var count = 10_000, rounds = 5
        var args = arguments[...]
        while let arg = args.popFirst() {
            if arg == "--files", let n = args.popFirst().flatMap(Int.init), n > 0 { count = n; continue }
            if arg == "--rounds", let n = args.popFirst().flatMap(Int.init), n > 0 { rounds = n; continue }
            fail("photos: unknown argument \(arg)")
        }
        let assets = (0..<count).map {
            PhotosAsset(id: "asset-\($0)/0", modified: .distantPast, created: nil, width: 4000, height: 3000,
                        filename: "Image-\($0).HEIC")
        }
        let start = cpu()
        let entries = PhotosAlbumListing.entries(assets, album: "album/0")
        let files = entries.map(\.url)
        print("synthetic photos: \(count), physical cores: \(Machine.physicalCores)")
        print(String(format: "worker entry preparation CPU ms: %.3f", cpu() - start))
        print("round\tplaylist CPU ms\t10000 steps CPU ms\tgrid ordering CPU ms")
        for round in 1...rounds {
            autoreleasepool {
                let start = cpu()
                var list = Playlist(ordered: files, current: files[0])!
                let playlist = cpu() - start
                let steps = cpu()
                for _ in 0..<10_000 {
                    if !list.move(by: 1) { list.moveToFirst() }
                }
                let navigation = cpu() - steps
                let sorting = cpu()
                let ordered = BrowserSort.standard.order(entries)
                let sorted = cpu() - sorting
                guard ordered.map(\.url) == files else { fail("photos: grid order changed") }
                print(String(format: "%d\t%.3f\t%.3f\t%.3f", round, playlist, navigation, sorted))
            }
        }
        exit(0)
    }
    private static func cpu() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }
}
