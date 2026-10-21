import Testing
import Foundation
@testable import LoupeCore

private let h = 68.0
private let stripWidth = 1200.0

private func layout(_ n: Int, width: Double = stripWidth, maxAspect: Double = 1.5,
                    aspects: [Double?] = []) -> StripScrollLayout {
    StripScrollLayout(fileCount: n, width: width, cellHeight: h, maxAspect: maxAspect, aspects: aspects)
}

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

@Test func manyFilesUseNarrowCells() {
    let l = layout(1000)
    #expect(l.cellWidth == 0.5625 * h)
    let gap = StripScrollLayout.gapRatio * h
    let expected = Int((stripWidth / (l.cellWidth + gap)).rounded(.up)) + 2
    let count = l.cells(offset: l.centre(of: 500), current: 500, expansion: 0).count
    #expect(abs(count - expected) <= 1, "\(count) cells, expected \(expected) ± 1")
    let big = layout(10_000)
    #expect(big.cells(offset: big.centre(of: 5000), current: 5000, expansion: 0).count == count)
}

@Test func fewFilesWidenUpToMax() {
    #expect(layout(3).cellWidth == 1.5 * h)
    #expect(layout(20).cellWidth == 60)
    #expect(layout(3, maxAspect: 0.5625).cellWidth == 0.5625 * h)
}

@Test func cellNeverWiderThanPhoto() {
    let l = layout(3, aspects: [1.5, 0.75, nil])
    #expect(l.narrowWidth(of: 1) == 0.75 * h)
    #expect(l.narrowWidth(of: 2) == l.cellWidth)
    #expect(l.narrowWidth(of: 0) == l.cellWidth)
}

@Test func currentCentredAndExpanded() throws {
    var aspects = [Double?](repeating: nil, count: 100)
    aspects[5] = 1.5
    let l = layout(100, aspects: aspects)
    let cells = l.cells(offset: l.centre(of: 5), current: 5, expansion: 1)
    let current = try #require(cells.first { $0.file == 5 })
    #expect(near(current.width, 1.5 * h))
    #expect(near(current.x + current.width / 2, stripWidth / 2))
    #expect(current.range == 5..<6)
    func cell(_ file: Int) throws -> StripCell { try #require(cells.first { $0.file == file }) }
    let padding = StripScrollLayout.currentPaddingRatio * h, gap = StripScrollLayout.gapRatio * h
    #expect(near(current.x - (try cell(4)).x - (try cell(4)).width, padding))
    #expect(near((try cell(6)).x - current.x - current.width, padding))
    #expect(near((try cell(4)).x - (try cell(3)).x - (try cell(3)).width, gap))
    #expect(near((try cell(7)).x - (try cell(6)).x - (try cell(6)).width, gap))
}

@Test func expansionUnknownCurrentIsThreeTwo() throws {
    let l = layout(100)
    let cells = l.cells(offset: l.centre(of: 50), current: 50, expansion: 1)
    let current = try #require(cells.first { $0.file == 50 })
    #expect(near(current.width, StripScrollLayout.unknownCurrentAspect * h))
    let half = l.cells(offset: l.centre(of: 50), current: 50, expansion: 0.5)
    let between = try #require(half.first { $0.file == 50 })
    #expect(near(between.width, (l.cellWidth + 1.5 * h) / 2))
    #expect(near(between.x + between.width / 2, stripWidth / 2))
}

@Test func fewFilesClusterAroundCentre() {
    let l = layout(3)
    let cells = l.cells(offset: l.centre(of: 1), current: 1, expansion: 0)
    #expect(cells.map(\.file) == [0, 1, 2])
    for c in cells { #expect(c.x > 0 && c.x + c.width < stripWidth, "\(c)") }
    let expanded = l.cells(offset: l.centre(of: 1), current: 1, expansion: 1)
    for c in expanded { #expect(c.x > 0 && c.x + c.width < stripWidth, "\(c)") }
}

@Test func fileAtBaseIsNearestAndClamped() {
    let l = layout(100)
    #expect(l.file(atBase: l.centre(of: 7) + 0.4 * l.cellWidth) == 7)
    #expect(l.file(atBase: l.centre(of: 7) - 0.4 * l.cellWidth) == 7)
    #expect(l.file(atBase: -500) == 0)
    #expect(l.file(atBase: l.centre(of: 99) + 500) == 99)
    var aspects = [Double?](repeating: nil, count: 100)
    aspects[3] = 0.2
    let mixed = layout(100, aspects: aspects)
    for f in [0, 2, 3, 4, 50, 99] { #expect(mixed.file(atBase: mixed.centre(of: f)) == f, "\(f)") }
    #expect(mixed.file(atBase: mixed.centre(of: 4) + 0.4 * mixed.cellWidth) == 4)
}

@Test func centresAreNarrowCellsAndGaps() {
    var aspects = [Double?](repeating: nil, count: 10)
    aspects[1] = 0.25
    let l = layout(10, aspects: aspects)
    let gap = StripScrollLayout.gapRatio * h
    #expect(near(l.centre(of: 0), l.cellWidth / 2))
    #expect(near(l.centre(of: 1), l.cellWidth + gap + 0.25 * h / 2))
    #expect(near(l.centre(of: 2), l.cellWidth + gap + 0.25 * h + gap + l.cellWidth / 2))
}

@Test func offsetRangeEnds() {
    let l = layout(100)
    #expect(l.offsetRange == l.centre(of: 0)...l.centre(of: 99))
}

@Test func emptyAndSingleFile() throws {
    let empty = layout(0)
    #expect(empty.cellWidth == 0)
    #expect(empty.cells(offset: 0, current: 0, expansion: 1) == [])
    #expect(empty.file(atBase: 0) == nil)
    let one = layout(1)
    let cells = one.cells(offset: one.centre(of: 0), current: 0, expansion: 0)
    #expect(cells.count == 1)
    let cell = try #require(cells.first)
    #expect(near(cell.x + cell.width / 2, stripWidth / 2))
    #expect(one.offsetRange == one.centre(of: 0)...one.centre(of: 0))
}

@Test func widthChangeKeepsCentreFile() {
    let old = layout(500), f = 321
    let new = layout(500, width: 800)
    #expect(old.file(atBase: old.centre(of: f)) == f)
    #expect(new.file(atBase: new.centre(of: f)) == f)
    let few = layout(12), wide = layout(12, width: 2400)
    #expect(few.cellWidth != wide.cellWidth)
    #expect(wide.file(atBase: wide.centre(of: 5)) == 5)
}

@Test func changedFileCountKeepsCentreFile() {
    let old = layout(20), f = 13
    let new = layout(70)
    #expect(old.cellWidth != new.cellWidth)
    #expect(new.file(atBase: new.centre(of: f)) == f)
}

@Test func aspectsArrivingKeepCentreFile() {
    let old = layout(200), f = 120
    let aspects: [Double?] = (0..<200).map { $0 % 3 == 0 ? 0.3 : ($0 % 3 == 1 ? 1.5 : nil) }
    let new = layout(200, aspects: aspects)
    #expect(old.centre(of: f) != new.centre(of: f))
    #expect(new.file(atBase: new.centre(of: f)) == f)
}

@Test func fadeLengthIsAShareOfTheHeight() {
    #expect(layout(10).fadeLength == 0.85 * h)
}

private func medianMicroseconds(_ body: () -> Void) -> Double {
    var times: [Double] = []
    for _ in 0..<100 {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
    }
    return times.sorted()[50]
}

@Test func windowIsConstantTime() {
    let n = 1_000_000
    let uniform = layout(n)
    let offset = uniform.centre(of: 600_000)
    let plain = medianMicroseconds { _ = uniform.cells(offset: offset, current: 600_000, expansion: 1) }
    #expect(plain < 50, "\(plain) µs")
    var aspects = [Double?](repeating: nil, count: n)
    aspects[10] = 0.3
    let mixed = layout(n, aspects: aspects)
    let mixedOffset = mixed.centre(of: 600_000)
    let summed = medianMicroseconds { _ = mixed.cells(offset: mixedOffset, current: 600_000, expansion: 1) }
    #expect(summed < 200, "\(summed) µs")
}

/// A playlist that grew or was re-read keeps its files' pictures and the strip's centre: each old index's place in
/// the new list, by URL; files that went have none.
@Test func playlistIndexMapFollowsTheFiles() {
    let urls = (0..<6).map { URL(fileURLWithPath: "/p/\($0).jpg") }
    let grown = StripPlaylist.indexMap(from: Array(urls.prefix(3)), to: urls)
    #expect(grown == [0: 0, 1: 1, 2: 2])
    let inserted = StripPlaylist.indexMap(from: [urls[0], urls[2], urls[4]], to: urls)
    #expect(inserted == [0: 0, 1: 2, 2: 4])
    let removed = StripPlaylist.indexMap(from: urls, to: [urls[5], urls[1]])
    #expect(removed == [1: 1, 5: 0])
    #expect(StripPlaylist.indexMap(from: urls, to: []).isEmpty)
    #expect(StripPlaylist.indexMap(from: [], to: urls).isEmpty)
}

/// The edges fade only where more cells go on past them, and never over the current cell.
@Test func fadesOnlyWhereTheStripGoesOn() {
    let l = layout(100), fade = 0.85 * h
    // At the first file: nothing before it, so no fade on the left.
    let first = l.cells(offset: l.centre(of: 0), current: 0, expansion: 1)
    #expect(l.fades(cells: first, current: 0) == (left: 0, right: fade))
    let last = l.cells(offset: l.centre(of: 99), current: 99, expansion: 1)
    #expect(l.fades(cells: last, current: 99) == (left: fade, right: 0))
    let middle = l.cells(offset: l.centre(of: 50), current: 50, expansion: 1)
    #expect(l.fades(cells: middle, current: 50) == (left: fade, right: fade))
    // A few files that fit: no fade at all.
    let few = layout(3)
    #expect(few.fades(cells: few.cells(offset: few.centre(of: 1), current: 1, expansion: 1), current: 1) == (left: 0, right: 0))
    // A narrow strip: the fade stops at the current cell.
    let narrow = layout(100, width: 160)
    let cells = narrow.cells(offset: narrow.centre(of: 50), current: 50, expansion: 1)
    let current = cells.first { $0.file == 50 }!
    let fades = narrow.fades(cells: cells, current: 50)
    #expect(fades.left == current.x && fades.right == 160 - current.x - current.width)
    #expect(narrow.fades(cells: [], current: 0) == (left: 0, right: 0))
}
