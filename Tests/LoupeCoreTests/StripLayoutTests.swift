import Testing
import Foundation
@testable import LoupeCore

@Test func singleFile() {
    let l = StripLayout(fileCount: 1, width: 1000, cellHeight: 64)
    #expect(l.cellWidth == 96)
    #expect(l.cells.count == 1)
    #expect(l.originX == (1000 - 96) / 2)
    #expect(l.cells[0].range == 0..<1)
    #expect(l.cells[0].file == 0)
    #expect(l.cells[0].x == l.originX)
    #expect(l.fileIndex(atX: l.originX + 48) == 0)
    #expect(l.fileIndex(atX: l.originX - 1) == nil)
    #expect(l.fileIndex(atX: l.originX + 96) == nil)
}

@Test func fewFilesCentred() {
    let l = StripLayout(fileCount: 5, width: 1000, cellHeight: 64)
    #expect(l.cells.count == 5)
    #expect(l.originX == (1000 - 5 * 96) / 2)
    for (i, c) in l.cells.enumerated() {
        #expect(c.range == i..<(i + 1))
        #expect(c.file == i)
        #expect(c.x == l.originX + Double(i) * 96)
        #expect(l.fileIndex(atX: c.x + 48) == i)
    }
}

@Test func exactFitIsOneCellPerFile() {
    let l = StripLayout(fileCount: 10, width: 960, cellHeight: 64)
    #expect(l.cells.count == 10)
    #expect(l.originX == 0)
}

@Test func sampledRangesCoverAll() {
    let l = StripLayout(fileCount: 10_000, width: 2000, cellHeight: 64)
    #expect(l.cells.count == 20)
    #expect(l.cells.first?.range.lowerBound == 0)
    #expect(l.cells.last?.range.upperBound == 10_000)
    for pair in zip(l.cells, l.cells.dropFirst()) {
        #expect(pair.0.range.upperBound == pair.1.range.lowerBound)
    }
    for c in l.cells {
        #expect(!c.range.isEmpty)
        #expect(c.range.contains(c.file))
        #expect(c.file == c.range.lowerBound + c.range.count / 2)
    }
}

@Test func linearMappingReachesEveryFile() {
    let n = 10_000
    let l = StripLayout(fileCount: n, width: 2000, cellHeight: 64)
    let span = Double(l.cells.count) * l.cellWidth
    var seen = Set<Int>()
    for i in 0..<n {
        let x = l.originX + (Double(i) + 0.5) / Double(n) * span
        let f = l.fileIndex(atX: x)
        #expect(f != nil)
        if let f { seen.insert(f) }
    }
    #expect(seen.count == n)
    #expect(l.fileIndex(atX: l.originX) == 0)
    #expect(l.fileIndex(atX: l.originX + span - 0.001) == n - 1)
    #expect(l.fileIndex(atX: l.originX - 0.001) == nil)
    #expect(l.fileIndex(atX: l.originX + span) == nil)
}

@Test func xOfFileRoundTrips() {
    for (n, width) in [(1, 500.0), (7, 1000.0), (20, 1920.0), (10_000, 2000.0), (333, 1234.5)] {
        let l = StripLayout(fileCount: n, width: width, cellHeight: 64)
        for i in stride(from: 0, to: n, by: max(1, n / 500)) + [n - 1] {
            #expect(l.fileIndex(atX: l.x(ofFile: i)) == i)
        }
    }
    let few = StripLayout(fileCount: 5, width: 1000, cellHeight: 64)
    #expect(few.x(ofFile: 2) == few.cells[2].x + 48)
}

@Test func cellContainingFile() {
    let l = StripLayout(fileCount: 10_000, width: 2000, cellHeight: 64)
    for i in stride(from: 0, to: 10_000, by: 7) + [9_999] {
        let c = l.cell(containingFile: i)
        #expect(c != nil)
        if let c { #expect(l.cells[c].range.contains(i)) }
    }
    #expect(l.cell(containingFile: -1) == nil)
    #expect(l.cell(containingFile: 10_000) == nil)
    let few = StripLayout(fileCount: 3, width: 1000, cellHeight: 64)
    #expect(few.cell(containingFile: 2) == 2)
}

@Test func zeroWidth() {
    let l = StripLayout(fileCount: 100, width: 0, cellHeight: 64)
    #expect(l.cells.isEmpty)
    #expect(l.fileIndex(atX: 0) == nil)
    #expect(l.cell(containingFile: 0) == nil)
    let narrow = StripLayout(fileCount: 100, width: 95, cellHeight: 64)
    #expect(narrow.cells.isEmpty)
}

@Test func noFiles() {
    let l = StripLayout(fileCount: 0, width: 1000, cellHeight: 64)
    #expect(l.cells.isEmpty)
    #expect(l.fileIndex(atX: 500) == nil)
}

// MARK: - Native aspect (Build 1.1)

@Test func nativeOnePerFileUsesAspects() {
    let l = StripLayout(fileCount: 3, width: 1000, cellHeight: 100, aspects: .init([1.5, 0.75, 1.0]))
    #expect(l.cells.map(\.width) == [150, 75, 100])
    #expect(l.cells.map(\.range) == [0..<1, 1..<2, 2..<3])
    #expect(l.originX == 337.5)
    #expect(l.cells.map(\.x) == [l.originX, l.originX + 150, l.originX + 225])
    #expect(l.span == 325)
    #expect(l.fileIndex(atX: l.originX + 160) == 1)
    #expect(l.fileIndex(atX: l.originX + 226) == 2)
    #expect(l.fileIndex(atX: l.originX - 0.001) == nil)
    #expect(l.fileIndex(atX: l.originX + 325) == nil)
    #expect(l.x(ofFile: 1) == l.originX + 150 + 37.5)
}

@Test func nativeSampledFillsWidthExactly() {
    let n = 10_000
    // Mean 1.5, so the capacity (from the mean width) is the crop strip's; the shown files (250, 750, …) take
    // all three values, so k stays near 1.
    let cycle = [2.0, 1.0, 1.5]
    let aspects = (0..<n).map { cycle[$0 % cycle.count] }
    let l = StripLayout(fileCount: n, width: 2000, cellHeight: 64, aspects: .init(aspects))
    let crop = StripLayout(fileCount: n, width: 2000, cellHeight: 64)
    #expect(l.cells.map(\.range) == crop.cells.map(\.range))
    #expect(l.cells.map(\.file) == crop.cells.map(\.file))
    #expect(l.originX == 0)
    #expect(abs(l.cells.reduce(0) { $0 + $1.width } - 2000) <= 1e-6)
    #expect(abs(l.span - 2000) <= 1e-6)
    for pair in zip(l.cells, l.cells.dropFirst()) {
        #expect(abs(pair.0.x + pair.0.width - pair.1.x) <= 1e-9)
    }
    // One factor for every cell: width / (aspect × height) is the same throughout.
    let k = l.cells[0].width / (aspects[l.cells[0].file] * 64)
    for c in l.cells { #expect(abs(c.width / (aspects[c.file] * 64) - k) <= 1e-9) }
}

@Test func nativeLinearWithinCell() {
    let n = 10_000
    let aspects = (0..<n).map { $0 % 3 == 0 ? 0.67 : 1.5 }
    let l = StripLayout(fileCount: n, width: 1920, cellHeight: 64, aspects: .init(aspects))
    #expect(!l.cells.isEmpty)
    for c in l.cells {
        #expect(l.fileIndex(atX: c.x) == c.range.lowerBound)
        #expect(l.fileIndex(atX: c.x + c.width - 0.001) == c.range.upperBound - 1)
    }
    var seen = Set<Int>()
    for i in 0..<n {
        let x = l.x(ofFile: i)
        #expect(l.fileIndex(atX: x) == i)
        if let f = l.fileIndex(atX: x) { seen.insert(f) }
    }
    #expect(seen.count == n)
    // A few files per cell: the cell's last whole point is its last file.
    let small = StripLayout(fileCount: 40, width: 1000, cellHeight: 64,
                            aspects: .init((0..<40).map { $0 % 2 == 0 ? 0.75 : 1.5 }))
    #expect(small.cells.count < 40)
    for c in small.cells {
        #expect(c.range.count > 1)
        #expect(small.fileIndex(atX: c.x + c.width - 1) == c.range.upperBound - 1)
    }
}

@Test func cropUnchangedWhenAspectsNil() {
    let few = StripLayout(fileCount: 7, width: 1000, cellHeight: 64, aspects: nil)
    #expect(few.cells.count == 7)
    #expect(few.originX == 164)
    #expect(few.cells[0].x == 164 && few.cells[0].width == 96 && few.cells[0].range == 0..<1)
    #expect(few.cells[6].x == 740 && few.cells[6].width == 96 && few.cells[6].range == 6..<7)
    #expect(few.span == 672)
    let sampled = StripLayout(fileCount: 333, width: 1234.5, cellHeight: 64, aspects: nil)
    #expect(sampled.cells.count == 12)
    #expect(sampled.originX == 41.25)
    #expect(sampled.cells[0].range == 0..<27 && sampled.cells[0].file == 13 && sampled.cells[0].x == 41.25)
    #expect(sampled.cells[1].range == 27..<55 && sampled.cells[1].x == 137.25)
    #expect(sampled.cells[11].range == 305..<333 && sampled.cells[11].x == 1097.25)
    #expect(sampled.cells.allSatisfy { $0.width == 96 })
    #expect(sampled.span == 1152)
}

@Test func nativeTooNarrowHasNoCells() {
    let l = StripLayout(fileCount: 100, width: 50, cellHeight: 64, aspects: .init(Array(repeating: 1.0, count: 100)))
    #expect(l.cells.isEmpty)
    #expect(l.fileIndex(atX: 10) == nil)
}

@Test func unknownAspectsTakeTheMedian() {
    #expect(StripLayout.filledAspects([nil, 2, nil, 1, 3]) == [2, 2, 2, 1, 3])
    #expect(StripLayout.filledAspects([1, nil, 2]) == [1, 1.5, 2])
    #expect(StripLayout.filledAspects([nil, nil]) == [1.5, 1.5])
    #expect(StripLayout.filledAspects([]) == [])
}

/// Each cell's scale against its photo's own width at the cell height.
private func scales(_ l: StripLayout, _ aspects: [Double]) -> [Double] {
    l.cells.map { $0.width / (aspects[$0.file] * l.cellHeight) }
}

@Test func nativeKeepsPreferredCountWhileAspectsStream() {
    let n = 10_000
    let guessed = StripLayout(fileCount: n, width: 2000, cellHeight: 64, aspects: .init(Array(repeating: 1.5, count: n)))
    #expect(guessed.cells.count == 20)
    // Narrower aspects arrive: from scratch the mean would make it 21 cells.
    let arrived = (0..<n).map { $0 % 4 == 0 ? 1.2 : 1.5 }
    #expect(StripLayout(fileCount: n, width: 2000, cellHeight: 64, aspects: .init(arrived)).cells.count == 21)
    let preferred = StripLayout.preferredCount(after: guessed, fileCount: n, width: 2000, cellHeight: 64)
    #expect(preferred == 20)
    let kept = StripLayout(fileCount: n, width: 2000, cellHeight: 64, aspects: .init(arrived), preferredCount: preferred)
    #expect(kept.cells.count == 20)
    #expect(kept.cells.map(\.range) == guessed.cells.map(\.range))
    #expect(abs(kept.span - 2000) <= 1e-6)
    #expect(scales(kept, arrived).allSatisfy { StripLayout.kRange.contains($0) })
}

@Test func nativeRecountsWhenThePreferredCountLeavesTheBand() {
    let n = 10_000
    // Every shown file of the 20-cell sample (250, 750, …) a portrait: k would be 2.3.
    let aspects = (0..<n).map { $0 % 2 == 0 ? 0.667 : 1.5 }
    let l = StripLayout(fileCount: n, width: 2000, cellHeight: 64, aspects: .init(aspects), preferredCount: 20)
    #expect(l.cells.count != 20)
    #expect(scales(l, aspects).allSatisfy { $0 >= StripLayout.kRange.lowerBound - 1e-12 && $0 <= StripLayout.kRange.upperBound + 1e-12 })
    #expect(l.span <= 2000 + 1e-6)
}

@Test func preferredCountOnlyForTheSameGeometry() {
    let n = 10_000
    let a = StripLayout.Aspects(Array(repeating: 1.5, count: n))
    let l = StripLayout(fileCount: n, width: 2000, cellHeight: 64, aspects: a)
    #expect(StripLayout.preferredCount(after: l, fileCount: n, width: 2000, cellHeight: 64) == 20)
    #expect(StripLayout.preferredCount(after: l, fileCount: n, width: 2001, cellHeight: 64) == nil)
    #expect(StripLayout.preferredCount(after: l, fileCount: n, width: 2000, cellHeight: 65) == nil)
    #expect(StripLayout.preferredCount(after: l, fileCount: n - 1, width: 2000, cellHeight: 64) == nil)
    #expect(StripLayout.preferredCount(after: nil, fileCount: n, width: 2000, cellHeight: 64) == nil)
    let few = StripLayout(fileCount: 5, width: 2000, cellHeight: 64, aspects: .init(Array(repeating: 1.5, count: 5)))
    #expect(StripLayout.preferredCount(after: few, fileCount: 5, width: 2000, cellHeight: 64) == nil)
    // A different width with a stale preference still lays out from scratch.
    let wider = StripLayout(fileCount: n, width: 3000, cellHeight: 64, aspects: a, preferredCount: nil)
    #expect(wider.cells.count == 31)
}

@Test func nativeTooNarrowSampleIsCentredNotCropped() {
    // 20 cells of 50 files: every middle file (25, 75, …) is odd, a portrait. Filling the width would take k = 1.64.
    let aspects = (0..<1000).map { $0 % 2 == 1 ? 0.667 : 1.5 }
    let l = StripLayout(fileCount: 1000, width: 1400, cellHeight: 64, aspects: .init(aspects))
    #expect(l.cells.count == 20)
    #expect(scales(l, aspects).allSatisfy { abs($0 - 1.15) <= 1e-9 })
    let expectedSpan = 20 * 0.667 * 64 * 1.15
    #expect(abs(l.span - expectedSpan) <= 1e-6)
    #expect(abs(l.originX - (1400 - expectedSpan) / 2) <= 1e-6)
    for pair in zip(l.cells, l.cells.dropFirst()) { #expect(abs(pair.0.x + pair.0.width - pair.1.x) <= 1e-9) }
    #expect(l.fileIndex(atX: l.originX - 0.01) == nil)
    #expect(l.fileIndex(atX: l.originX) == 0)
}

@Test func nativeTooWideSampleTakesFewerCells() {
    // The same, every middle file a landscape: k = 0.73 at 20 cells, so fewer cells.
    let aspects = (0..<1000).map { $0 % 2 == 1 ? 1.5 : 0.667 }
    let l = StripLayout(fileCount: 1000, width: 1400, cellHeight: 64, aspects: .init(aspects))
    #expect(l.cells.count < 20 && !l.cells.isEmpty)
    #expect(l.span <= 1400 + 1e-6)
    #expect(scales(l, aspects).allSatisfy { $0 >= StripLayout.kRange.lowerBound - 1e-12 && $0 <= StripLayout.kRange.upperBound + 1e-12 })
    #expect(l.cells.first?.range.lowerBound == 0 && l.cells.last?.range.upperBound == 1000)
}
