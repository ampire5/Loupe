import Foundation
import LoupeCore

/// `LoupeBench strip [--files N]` (strip spec 2026-10-21, «Производительность»): the main thread's work per scroll
/// event of the Photos-style strip — `StripScroll.event` and the window of cells `StripScrollLayout.cells` gives the
/// view — over a folder of N files (default 10 000) at 68 pt in an 1800 pt strip, every cell narrow. 2 000 events of
/// a gesture that sweeps the folder and its momentum; prints the median and p99 µs per event and the most cells one
/// event shows. Half the aspects known, a few very narrow, so the layout's prefix sums are in play.
enum StripBench {
    static func main(_ arguments: [String]) -> Never {
        var files = 10_000
        var args = arguments[...]
        while let arg = args.popFirst() {
            if arg == "--files", let n = args.popFirst().flatMap(Int.init), n > 0 { files = n; continue }
            fail("strip: unknown argument \(arg)")
        }
        let aspects: [Double?] = (0..<files).map { $0 % 2 == 1 ? nil : ($0 % 97 == 0 ? 0.3 : ($0 % 6 == 0 ? 0.75 : 1.5)) }
        let start = ContinuousClock.now
        let layout = StripScrollLayout(fileCount: files, width: 1800, cellHeight: 68, maxAspect: 1.5, aspects: aspects)
        let layoutMs = Double((ContinuousClock.now - start) / .microseconds(1)) / 1000
        var scroll = StripScroll()
        var current = files / 2, times: [Double] = [], most = 0, scrubs = 0
        for i in 0..<2000 {
            let phase: ScrollPhase = i == 0 ? .began : (i < 1200 ? .changed : (i == 1200 ? .ended : []))
            let momentum: ScrollPhase = i <= 1200 ? [] : (i == 1201 ? .began : (i == 1999 ? .ended : .changed))
            // A sweep left and back, then a coast that slows down.
            let dx = i < 600 ? -12.0 : (i < 1200 ? 9.0 : 14.0 * Double(2000 - i) / 800)
            let t0 = ContinuousClock.now
            let outcome = scroll.event(fingerDX: dx, dy: 0, phase: phase, momentum: momentum, layout: layout,
                                       current: current, now: Double(i) / 120)
            let cells = layout.cells(offset: scroll.offset ?? layout.centre(of: current), current: current,
                                     expansion: scroll.isMoving ? 0 : 1)
            times.append(Double((ContinuousClock.now - t0) / .nanoseconds(1)) / 1000)
            if let file = outcome.file {
                current = file
                scrubs += 1
            }
            most = max(most, cells.count)
        }
        times.sort()
        let median = times[times.count / 2], p99 = times[times.count * 99 / 100]
        print("files\tlayout ms\tevents\tmedian µs\tp99 µs\tmax µs\tmax cells\tfiles reached")
        print("\(files)\t\(String(format: "%.2f", layoutMs))\t\(times.count)\t\(String(format: "%.1f", median))"
              + "\t\(String(format: "%.1f", p99))\t\(String(format: "%.1f", times.last ?? 0))\t\(most)\t\(scrubs)")
        exit(0)
    }
}
