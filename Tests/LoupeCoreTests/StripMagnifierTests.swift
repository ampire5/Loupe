import Foundation
import Testing
@testable import LoupeCore

@Suite struct StripMagnifierTests {
    typealias Frame = (x: Double, width: Double, height: Double)

    /// Nine 3:2 cells at a cell height of 64, edge to edge from x = 100.
    private let base: [(x: Double, width: Double)] = (0..<9).map { (x: 100 + Double($0) * 96, width: 96) }
    private let height = 64.0

    private func centre(_ f: Frame) -> Double { f.x + f.width / 2 }
    private func centre(ofCell i: Int) -> Double { 100 + Double(i) * 96 + 48 }

    /// The scale of each cell, read back from its width.
    private func scales(_ frames: [Frame], _ cells: [(x: Double, width: Double)]? = nil) -> [Double] {
        zip(frames, cells ?? base).map { $0.width / $1.width }
    }

    private func isBase(_ frames: [Frame]) -> Bool {
        frames.count == base.count && zip(frames, base).allSatisfy { f, b in
            f.x == b.x && f.width == b.width && f.height == height
        }
    }

    @Test func noCursorNoChange() {
        #expect(isBase(StripMagnifier.frames(baseCells: base, height: height, cursorX: nil, magnify: 2.5)))
        // A cursor beside the cells (a centred strip's margin) magnifies nothing either.
        #expect(isBase(StripMagnifier.frames(baseCells: base, height: height, cursorX: 50, magnify: 2.5)))
        #expect(StripMagnifier.frames(baseCells: [], height: height, cursorX: 10, magnify: 2.5).isEmpty)
    }

    @Test func hoveredScalesByMagnify() {
        let frames = StripMagnifier.frames(baseCells: base, height: height, cursorX: centre(ofCell: 4), magnify: 2.5)
        #expect(abs(frames[4].width - 96 * 2.5) < 1e-9)
        #expect(abs(frames[4].height - 64 * 2.5) < 1e-9)
        // Off its centre the cell under the cursor is a little smaller, still the largest.
        let off = scales(StripMagnifier.frames(baseCells: base, height: height, cursorX: centre(ofCell: 4) + 20,
                                               magnify: 2.5))
        #expect(off[4] < 2.5 && off[4] == off.max())
    }

    @Test func neighboursFallOff() {
        let frames = StripMagnifier.frames(baseCells: base, height: height, cursorX: centre(ofCell: 4), magnify: 2.5,
                                           reach: 3)
        let s = scales(frames)
        for (near, far) in [(3, 5), (2, 6), (1, 7), (0, 8)] {
            #expect(abs(s[near] - s[far]) < 1e-9, "d = \(4 - near) the same on both sides")
        }
        #expect(s[4] > s[3] && s[3] > s[2] && s[2] > s[1] && s[1] > 1)
        #expect(s[0] == 1 && s[8] == 1)
        // cos²(π·2 / 8) = 0.5: half the extra at d = 2.
        #expect(abs(s[2] - 1.75) < 1e-9)
        for (f, scale) in zip(frames, s) { #expect(abs(f.height - height * scale) < 1e-9) }
    }

    @Test func defaultReachIsTheConfigDefault() {
        let x = centre(ofCell: 4) + 13
        let byDefault = StripMagnifier.frames(baseCells: base, height: height, cursorX: x, magnify: 2)
        let two = StripMagnifier.frames(baseCells: base, height: height, cursorX: x, magnify: 2, reach: Config().stripMagnifyReach)
        #expect(byDefault.map(\.x) == two.map(\.x) && byDefault.map(\.width) == two.map(\.width))
        #expect(Config().stripMagnifyReach == 2)
    }

    @Test func falloffIsMonotoneInContinuousDistance() {
        var last = Double.infinity
        for step in 0...80 {
            let d = Double(step) * 0.05
            let s = StripMagnifier.scale(distance: d, magnify: 3, reach: 3)
            #expect(s <= last, "d = \(d)")
            #expect(d < 4 ? s > 1 : s == 1, "d = \(d)")
            last = s
        }
        #expect(StripMagnifier.scale(distance: 0, magnify: 3, reach: 3) == 3)
        #expect(StripMagnifier.scale(distance: 9, magnify: 3, reach: 3) == 1)
    }

    /// The largest change of any frame's x, width or height over a sweep of the cursor across every cell, in steps
    /// of `step` pt; with `fill`, through `keepingInside` with the strip filling 0...`fill`.
    private func largestStep(_ cells: [(x: Double, width: Double)], magnify: Double, step: Double,
                             fill: Double? = nil) -> Double {
        func shown(_ x: Double) -> [Frame] {
            let frames = StripMagnifier.frames(baseCells: cells, height: height, cursorX: x, magnify: magnify)
            guard let fill else { return frames }
            return StripMagnifier.keepingInside(frames, baseCells: cells, cursorX: x, width: fill)
        }
        let end = cells.last!.x + cells.last!.width
        var previous = shown(cells[0].x), largest = 0.0
        var x = cells[0].x + step
        while x < end {
            let frames = shown(x)
            for (f, p) in zip(frames, previous) {
                largest = max(largest, abs(f.x - p.x), abs(f.width - p.width), abs(f.height - p.height))
            }
            previous = frames
            x += step
        }
        return largest
    }

    private let mixed: [(x: Double, width: Double)] = {
        var x = 100.0
        return (0..<9).map { i in
            let w = i % 2 == 0 ? 64.0 : 144
            defer { x += w }
            return (x: x, width: w)
        }
    }()

    /// 96 pt cells filling 0...1920, the strip of a full-width window.
    private let filling: [(x: Double, width: Double)] = (0..<20).map { (x: Double($0) * 96, width: 96) }

    /// Lipschitz in the cursor: a step of δ moves no frame by more than `bound`·δ, at 1 pt and at 0.1 pt, across cell
    /// boundaries, for equal and for mixed widths, with and without the edge correction (which ramps over a quarter
    /// cell, hence its larger constant). A jump (the whole-cell steps of the first version, 20–140 pt, or an edge
    /// shift that snapped by 90–270 pt when the hovered cell changed) does not shrink with δ.
    @Test func framesAreLipschitzInTheCursor() {
        for (magnify, bound, edgeBound) in [(2.0, 3.0, 7.0), (2.5, 4.0, 10.0), (4.0, 8.0, 20.0)] {
            for step in [1.0, 0.1] {
                for cells in [base, mixed] {
                    let largest = largestStep(cells, magnify: magnify, step: step)
                    #expect(largest <= bound * step, "m \(magnify), δ \(step): \(largest)")
                }
                let edged = largestStep(filling, magnify: magnify, step: step, fill: 1920)
                #expect(edged <= edgeBound * step, "m \(magnify), δ \(step), filling: \(edged)")
            }
        }
    }

    /// The point under the cursor stays under it: the cursor is as far into the magnified cell as into the base one.
    @Test func pointUnderTheCursorStaysUnderIt() {
        for x in stride(from: centre(ofCell: 2), through: centre(ofCell: 6), by: 7.0) {
            let frames = StripMagnifier.frames(baseCells: base, height: height, cursorX: x, magnify: 3)
            let i = Int((x - 100) / 96)
            let inBase = (x - base[i].x) / base[i].width
            let inShown = (x - frames[i].x) / frames[i].width
            #expect(abs(inBase - inShown) < 1e-9, "x = \(x)")
            // Still edge to edge.
            for j in 1..<frames.count { #expect(abs(frames[j].x - (frames[j - 1].x + frames[j - 1].width)) < 1e-9) }
        }
    }

    @Test func extraWidthSplitBothSides() {
        // At a cell's centre the neighbours are symmetric: half the extra width each way, the centre kept.
        let frames = StripMagnifier.frames(baseCells: base, height: height, cursorX: centre(ofCell: 4), magnify: 3)
        #expect(abs(centre(frames[4]) - centre(ofCell: 4)) < 1e-9)
        let extra = frames.reduce(0) { $0 + $1.width } - 9 * 96
        #expect(abs((100 - frames[0].x) - extra / 2) < 1e-9)
        #expect(abs((frames[8].x + frames[8].width) - (100 + 9 * 96) - extra / 2) < 1e-9)
        // Left of the cursor everything moves left, right of it right.
        let off = StripMagnifier.frames(baseCells: base, height: height, cursorX: centre(ofCell: 4) - 30, magnify: 3)
        for i in 0..<4 { #expect(off[i].x < base[i].x) }
        for i in 5..<9 { #expect(off[i].x > base[i].x) }
    }

    @Test func magnifyOneIsIdentity() {
        #expect(isBase(StripMagnifier.frames(baseCells: base, height: height, cursorX: 300, magnify: 1)))
    }

    @Test func reachZeroGrowsOnlyWithinOneCell() {
        // At a cell's centre: only that cell grows, the others part to make room, half a cell each way.
        let frames = StripMagnifier.frames(baseCells: base, height: height, cursorX: centre(ofCell: 4), magnify: 2,
                                           reach: 0)
        #expect(scales(frames) == [1, 1, 1, 1, 2, 1, 1, 1, 1])
        #expect(abs(frames[3].x - (100 + 3 * 96 - 48)) < 1e-9 && abs(frames[5].x - (100 + 5 * 96 + 48)) < 1e-9)
        // Crossing towards a neighbour hands the growth over smoothly; the cells further away stay at 1.
        let between = scales(StripMagnifier.frames(baseCells: base, height: height, cursorX: 100 + 5 * 96,
                                                   magnify: 2, reach: 0))
        #expect(abs(between[4] - 1.5) < 1e-9 && abs(between[5] - 1.5) < 1e-9)
        #expect(between.enumerated().allSatisfy { $0.offset == 4 || $0.offset == 5 || $0.element == 1 })
    }

    @Test func keepingInsideShiftsTheEndsBackOnScreen() {
        func shown(_ x: Double, _ m: Double) -> [Frame] {
            StripMagnifier.keepingInside(StripMagnifier.frames(baseCells: filling, height: height, cursorX: x, magnify: m),
                                         baseCells: filling, cursorX: x, width: 1920)
        }
        for m in [2.0, 4.0] {
            // At the end cells' centres the magnified cell is wholly on screen.
            let first = shown(48, m), last = shown(1920 - 48, m)
            #expect(abs(first[0].x) < 1e-9 && first[0].width > 96)
            #expect(abs(last[19].x + last[19].width - 1920) < 1e-9)
            // Moved as one: still edge to edge.
            for i in 1..<20 { #expect(abs(first[i].x - (first[i - 1].x + first[i - 1].width)) < 1e-9) }
            // At a cell boundary nothing moves: the boundary is where the cursor is, as the base layout picks.
            let plain = StripMagnifier.frames(baseCells: filling, height: height, cursorX: 96, magnify: m)
            #expect(shown(96, m).map(\.x) == plain.map(\.x))
            // In the middle nothing moves either.
            let middle = StripMagnifier.frames(baseCells: filling, height: height, cursorX: 960 + 30, magnify: m)
            #expect(shown(960 + 30, m).map(\.x) == middle.map(\.x))
            // Everywhere the cursor stays over the cell the base layout puts it in.
            for x in stride(from: 0.5, to: 1920, by: 3.7) {
                let i = Int(x / 96), f = shown(x, m)[i]
                #expect(f.x <= x + 1e-9 && x < f.x + f.width + 1e-9, "m \(m), x \(x)")
            }
        }
        // No cursor, or one beside the cells: unchanged.
        let none = StripMagnifier.frames(baseCells: filling, height: height, cursorX: nil, magnify: 2)
        #expect(StripMagnifier.keepingInside(none, baseCells: filling, cursorX: nil, width: 1920).map(\.x) == none.map(\.x))
    }

    @Test func reachWidensTheFalloff() {
        let frames = StripMagnifier.frames(baseCells: base, height: height, cursorX: 100 + 4 * 96, magnify: 2,
                                           reach: 6)
        #expect(scales(frames).allSatisfy { $0 > 1 })
    }

    @Test func magnifiedHeightIsCappedByTheViewer() {
        // 64 pt cells in a 1000 pt viewer at the default 15 %: at most 150 pt tall, so 2.34× of the 4× asked for;
        // 2× stays 2×.
        #expect(abs(StripMagnifier.effectiveMagnify(4, cellHeight: 64, viewerHeight: 1000, limitPercent: 15)
                    - 150.0 / 64) < 1e-9)
        #expect(StripMagnifier.effectiveMagnify(2, cellHeight: 64, viewerHeight: 1000, limitPercent: 15) == 2)
        // A strip already taller than the limit does not grow; it never shrinks.
        #expect(StripMagnifier.effectiveMagnify(2, cellHeight: 240, viewerHeight: 1000, limitPercent: 15) == 1)
        #expect(StripMagnifier.effectiveMagnify(2, cellHeight: 64, viewerHeight: 0, limitPercent: 15) == 2)
        let m = StripMagnifier.effectiveMagnify(3, cellHeight: 121, viewerHeight: 1728, limitPercent: 15)
        let frames = StripMagnifier.frames(baseCells: base, height: 121, cursorX: centre(ofCell: 4), magnify: m)
        #expect(frames.allSatisfy { $0.height <= 0.15 * 1728 + 1e-9 })
    }

    /// Build 2 trial: `strip-magnify=4` on a 107–235 pt strip came out ×1.1–2.4 under the fixed 15 %; the limit is
    /// a setting now and the cap follows it.
    @Test func magnifyLimitSetsTheCap() {
        // 107 pt cells, 1000 pt viewer: 15 % allows ×1.40, 50 % the whole ×4, 30 % ×2.80.
        #expect(abs(StripMagnifier.effectiveMagnify(4, cellHeight: 107, viewerHeight: 1000, limitPercent: 15)
                    - 150.0 / 107) < 1e-9)
        #expect(StripMagnifier.effectiveMagnify(4, cellHeight: 107, viewerHeight: 1000, limitPercent: 50) == 4)
        #expect(abs(StripMagnifier.effectiveMagnify(4, cellHeight: 107, viewerHeight: 1000, limitPercent: 30)
                    - 300.0 / 107) < 1e-9)
        // 100 %: a 235 pt strip in a 1000 pt viewer grows ×4 (940 pt), the cap never below 1.
        #expect(StripMagnifier.effectiveMagnify(4, cellHeight: 235, viewerHeight: 1000, limitPercent: 100) == 4)
        #expect(StripMagnifier.effectiveMagnify(4, cellHeight: 240, viewerHeight: 1000, limitPercent: 5) == 1)
        let m = StripMagnifier.effectiveMagnify(4, cellHeight: 121, viewerHeight: 1728, limitPercent: 40)
        let frames = StripMagnifier.frames(baseCells: base, height: 121, cursorX: centre(ofCell: 4), magnify: m)
        #expect(frames.allSatisfy { $0.height <= 0.40 * 1728 + 1e-9 })
        #expect(frames.contains { $0.height > 0.15 * 1728 })
    }

    /// `strip-magnify-reach` takes fractions: the falloff spans reach + 1 cell widths.
    @Test func fractionalReachSpansReachPlusOne() {
        let c = cos(Double.pi * 1.2 / 3)
        #expect(abs(StripMagnifier.scale(distance: 1.2, magnify: 3, reach: 0.5) - (1 + 2 * c * c)) < 1e-9)
        #expect(StripMagnifier.scale(distance: 1.5, magnify: 3, reach: 0.5) == 1)
        #expect(StripMagnifier.scale(distance: 1.49, magnify: 3, reach: 0.5) > 1)
        // Between the whole reaches on either side.
        let x = centre(ofCell: 4)
        let one = scales(StripMagnifier.frames(baseCells: base, height: height, cursorX: x, magnify: 2, reach: 1))
        let half = scales(StripMagnifier.frames(baseCells: base, height: height, cursorX: x, magnify: 2, reach: 1.5))
        let two = scales(StripMagnifier.frames(baseCells: base, height: height, cursorX: x, magnify: 2, reach: 2))
        #expect(one[3] < half[3] && half[3] < two[3])
        #expect(one[2] == 1 && half[2] > 1)
    }

    @Test func scalesMatchTheFrames() {
        let x = centre(ofCell: 3) + 11
        let s = StripMagnifier.scales(baseCells: base, cursorX: x, magnify: 2.5, reach: 2)
        let frames = StripMagnifier.frames(baseCells: base, height: height, cursorX: x, magnify: 2.5)
        for (a, b) in zip(s, scales(frames)) { #expect(abs(a - b) < 1e-9) }
        #expect(StripMagnifier.scales(baseCells: base, cursorX: nil, magnify: 2.5, reach: 3) == Array(repeating: 1, count: 9))
    }
}
