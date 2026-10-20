import Foundation
import Testing
@testable import LoupeCore

@Suite struct StripResizeDragTests {
    /// A drag from the top of a cell shown at twice its 64 pt base (the cell under the cursor at the default
    /// `strip-magnify` 2), the strip floating over a viewer `window` tall.
    private func fromPeak(base: Double = 64, shown: Double = 128, magnify: Double = 2, window: Double,
                          bar: Bool = false, limit: Double = 15) -> StripResizeDrag {
        StripResizeDrag(startHeight: base, shownHeight: shown, magnify: magnify, windowHeight: window,
                        viewerShrinks: bar, padding: 4, limitPercent: limit)
    }

    private func samples(_ range: ClosedRange<Double>, by step: Double = 0.5) -> [Double] {
        Array(stride(from: range.lowerBound, through: range.upperBound, by: step))
    }

    @Test func uncappedTheGrabbedTopStaysUnderTheCursor() {
        // 1728 pt: the cap is 259.2, so the cell at x2 follows until a base of 129.6.
        let drag = fromPeak(window: 1728)
        for d in samples(-48...120) {
            #expect(abs(drag.shownHeight(atHeight: drag.height(forDrag: d)) - 128 - d) < 1e-6)
        }
        #expect(abs(drag.height(forDrag: 60) - 94) < 1e-9)
        #expect(abs(drag.height(forDrag: -48) - 40) < 1e-9)
    }

    @Test func onceTheCapHoldsTheTopTheBaseMovesOneToOne() {
        // 900 pt: the cap is 135, reached at a base of 67.5 (7 pt of drag); from there the top cannot move.
        let drag = fromPeak(window: 900)
        #expect(abs(drag.height(forDrag: 7) - 67.5) < 1e-6)
        #expect(abs(drag.height(forDrag: 107) - 167.5) < 1e-6)
        #expect(abs(drag.height(forDrag: 179.5) - 240) < 1e-6)
        // 1728 pt: 64 to 129.6 at half speed (131.2 pt of drag), then 1:1 to 240. The cap sits inside one 0.25 pt
        // integration step there, which may be off by up to that step (the height is whole points anyway).
        let tall = fromPeak(window: 1728)
        #expect(abs(tall.height(forDrag: 131.2) - 129.6) < 0.25)
        #expect(abs(tall.height(forDrag: 241.6) - 240) < 0.25)
    }

    @Test func pressedUnderTheCapAndDraggedDown() {
        // 900 pt, base 100: the cell is held at the cap (135, x1.35). Down to 67.5 the top stays (1:1), below it the
        // cell grows to x2 again and the top follows the cursor (half speed) to 40.
        let drag = fromPeak(base: 100, shown: 135, window: 900)
        #expect(abs(drag.height(forDrag: -32.5) - 67.5) < 1e-6)
        #expect(abs(drag.height(forDrag: -87.5) - 40) < 1e-6)
    }

    @Test func continuousMonotoneAndNeverSlowerThanTheCursorOnceTheTopStops() {
        for window in [900.0, 1728] {
            for bar in [false, true] {
                for (base, shown) in [(64.0, 128.0), (64, 100), (150, 150), (240, 240)] {
                    let drag = fromPeak(base: base, shown: shown, window: window, bar: bar)
                    var last = drag.height(forDrag: -400)
                    for d in samples(-399.5...400) {
                        let h = drag.height(forDrag: d)
                        // Rising with the cursor, at least half its speed (x2), at most its speed: no jump.
                        #expect(h - last >= 0.25 - 1e-9 && h - last <= 0.5 + 1e-9, "\(window) \(bar) \(base) \(d)")
                        last = h
                    }
                    #expect(drag.height(forDrag: 0) == base)
                }
            }
        }
    }

    @Test func oneToOneAtTheBaseEdgeAndWithoutMagnification() {
        for drag in [fromPeak(shown: 64, window: 1728),                  // the band's top: no cell magnified
                     fromPeak(shown: 64, magnify: 1, window: 1728),
                     fromPeak(base: 240, shown: 240, window: 900)] {     // the cap leaves no magnification
            for d in samples(-200...200, by: 7) {
                #expect(abs(drag.height(forDrag: d) - drag.height(forDrag: 0) - d) < 1e-9)
            }
        }
        let plain = fromPeak(shown: 64, window: 1728)
        for d in samples(-24...176, by: 8) { #expect(abs(plain.height(forDrag: d) - 64 - d) < 1e-9) }
    }

    /// `strip-magnify-limit` moves the cap the drag models: at 100 % a 900 pt window never caps ×2 below 240, so the
    /// top stays under the cursor where the default 15 % held it from a base of 67.5.
    @Test func theCapFollowsTheMagnifyLimit() {
        let drag = fromPeak(window: 900, limit: 100)
        for d in samples(-48...112) {
            #expect(abs(drag.shownHeight(atHeight: drag.height(forDrag: d)) - 128 - d) < 1e-6)
        }
        // 30 %: the cap is 270, reached at a base of 135 after 142 pt of drag (the top at x2), then 1:1.
        let thirty = fromPeak(window: 900, limit: 30)
        #expect(abs(thirty.height(forDrag: 142) - 135) < 0.25)
        #expect(abs(thirty.height(forDrag: 142 + 50) - 185) < 0.25)
    }
}
