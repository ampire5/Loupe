import Testing
@testable import LoupeCore

private let portrait = PixelSize(width: 3000, height: 4000)
private let landscape = PixelSize(width: 4000, height: 3000)

private func plan(_ sizes: [PixelSize?], shift: Bool = false, rtl: Bool = false,
                  landscapeAlone: Bool = true) -> SpreadPlan {
    SpreadPlan(sizes: sizes, options: SpreadOptions(shift: shift, rightToLeft: rtl, landscapeAlone: landscapeAlone))
}

private func allPairs(_ p: SpreadPlan) -> [[Int]] {
    var out: [[Int]] = []
    var cur = p.first
    while let c = cur {
        out.append(c.pages)
        cur = p.next(after: c)
    }
    return out
}

@Test func pairsFromStart() {
    #expect(allPairs(plan(Array(repeating: portrait, count: 6))) == [[0, 1], [2, 3], [4, 5]])
}

@Test func shiftMakesCoverAlone() {
    #expect(allPairs(plan(Array(repeating: portrait, count: 6), shift: true)) == [[0], [1, 2], [3, 4], [5]])
}

@Test func landscapeStandsAlone() {
    #expect(allPairs(plan([portrait, portrait, landscape, portrait, portrait])) == [[0, 1], [2], [3, 4]])
}

@Test func landscapePairWhenAsked() {
    let p = plan([portrait, portrait, landscape, portrait, portrait], landscapeAlone: false)
    #expect(allPairs(p) == [[0, 1], [2, 3], [4]])
}

@Test func oddLastIsAlone() {
    #expect(allPairs(plan(Array(repeating: portrait, count: 5))) == [[0, 1], [2, 3], [4]])
}

@Test func pairContainingIndex() {
    let p = plan(Array(repeating: portrait, count: 6))
    #expect(p.pair(containing: 3)?.first == 2)
    #expect(p.pair(containing: 2)?.second == 3)
    #expect(p.pair(containing: 6) == nil)
    #expect(p.pair(containing: -1) == nil)
}

@Test func nextPreviousWalk() {
    let p = plan(Array(repeating: portrait, count: 5))
    #expect(p.previous(before: p.first!) == nil)
    #expect(p.next(after: p.last!) == nil)
    var forward: [Int] = []
    var cur = p.first
    while let c = cur { forward.append(c.first); cur = p.next(after: c) }
    var back: [Int] = []
    cur = p.last
    while let c = cur { back.append(c.first); cur = p.previous(before: c) }
    #expect(forward == [0, 2, 4])
    #expect(back == [4, 2, 0])
}

@Test func singlePageFolders() {
    #expect(allPairs(plan([portrait])) == [[0]])
    #expect(allPairs(plan(Array(repeating: landscape, count: 3))) == [[0], [1], [2]])
    #expect(plan([]).first == nil)
    #expect(plan([]).last == nil)
}

@Test func orientationDecidesLandscape() {
    // A 4000x3000 file rotated by its orientation arrives as 3000x4000: portrait.
    let rotated = PixelSize(width: 3000, height: 4000)
    #expect(allPairs(plan([rotated, rotated])) == [[0, 1]])
}

@Test func unknownSizeIsPortrait() {
    #expect(allPairs(plan([nil, portrait, nil])) == [[0, 1], [2]])
}

@Test func landscapeBreaksTheRunOfPortraits() {
    #expect(allPairs(plan([portrait, portrait, portrait, landscape])) == [[0, 1], [2], [3]])
}

@Test func shiftWithLandscapeFirstPage() {
    #expect(allPairs(plan([landscape, portrait, portrait], shift: true)) == [[0], [1, 2]])
}

@Test func emptyPlanFindsNothing() {
    let p = plan([])
    #expect(p.pair(containing: 0) == nil)
    #expect(p.first == nil && p.last == nil)
}

@Test func hugePlanIsFastToQuery() {
    let p = plan(Array(repeating: portrait, count: 100_000))
    #expect(p.last == SpreadPair(first: 99_998, second: 99_999))
    #expect(p.pair(containing: 50_001) == SpreadPair(first: 50_000, second: 50_001))
}

/// Only a clearly wide page stands alone (`SpreadPlan.landscapeAspect`): square and near-square pages (scans with
/// their margins) pair.
@Test func nearSquarePagesPair() {
    let square = PixelSize(width: 3000, height: 3000)
    let nearSquare = PixelSize(width: 3400, height: 3000)   // 1.13
    let wide = PixelSize(width: 3500, height: 3000)         // 1.17
    #expect(allPairs(plan([portrait, square, nearSquare, portrait])) == [[0, 1], [2, 3]])
    #expect(allPairs(plan([portrait, wide, portrait])) == [[0], [1], [2]])
    #expect(!SpreadSizes.changesPairing(from: nil, to: nearSquare))
    #expect(SpreadSizes.changesPairing(from: nearSquare, to: wide))
    #expect(plan([portrait, wide]).isWide(1) && !plan([portrait, wide]).isWide(0))
    #expect(!plan([portrait, wide], landscapeAlone: false).isWide(1))
}
