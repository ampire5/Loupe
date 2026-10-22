import FilmstripModel
import Testing
@testable import LoupeCore

/// One page: the current photo's cell; a pair: both cells, in playlist order whatever the reading order or which page
/// is the current one.
@Test func pagesAreTheCurrentRunOfCells() {
    #expect(StripPages(current: 7, pages: nil).items == 7..<8)
    #expect(StripPages(current: 7, pages: (first: 7, second: nil)).items == 7..<8)
    #expect(StripPages(current: 12, pages: (first: 12, second: 13)).items == 12..<14)
    #expect(StripPages(current: 13, pages: (first: 12, second: 13)).items == 12..<14)
    #expect(StripPages(current: 13, pages: (first: 13, second: 12)).items == 12..<14)
    #expect(StripPages(item: 4) == StripPages(current: 4, pages: nil))
    #expect(StripPages(current: 12, pages: (12, 13)).contains(13) && !StripPages(current: 12, pages: (12, 13)).contains(14))
}

/// The strip rests with the middle of the pair at its centre: between the two cells.
@Test func pairCentresBetweenItsCells() {
    let layout = FilmstripLayout(itemCount: 100, length: 1200, thickness: 68, maxAspect: 1.5, aspects: [])
    let pair = StripPages(current: 12, pages: (12, 13))
    #expect(abs(pair.offset(in: layout) - (layout.centre(of: 12) + layout.centre(of: 13)) / 2) < 1e-9)
    #expect(StripPages(item: 12).offset(in: layout) == layout.centre(of: 12))
}

/// Steps to the next pair or photo animate; a pair turning into one of its pages (or back) too; a jump does not.
@Test func stepsAreNeighbouringRuns() {
    let pair = StripPages(current: 12, pages: (12, 13))
    #expect(StripPages(current: 14, pages: (14, 15)).isStep(from: pair))
    #expect(StripPages(current: 10, pages: (10, 11)).isStep(from: pair))
    #expect(StripPages(item: 12).isStep(from: pair) && pair.isStep(from: StripPages(item: 13)))
    #expect(StripPages(item: 14).isStep(from: StripPages(item: 13)))
    #expect(!StripPages(current: 16, pages: (16, 17)).isStep(from: pair))
    #expect(!StripPages(item: 15).isStep(from: StripPages(item: 13)))
    #expect(!pair.isStep(from: nil))
}

/// A new listing keeps the run where its files went; one that lost a page, or split the pair, has none.
@Test func pagesFollowTheirFiles() {
    let pair = StripPages(current: 12, pages: (12, 13))
    #expect(pair.remapped([12: 2, 13: 3]) == StripPages(current: 2, pages: (2, 3)))
    #expect(pair.remapped([12: 2]) == nil)
    #expect(pair.remapped([12: 2, 13: 4]) == nil)
    #expect(StripPages(item: 5).remapped([5: 0]) == StripPages(item: 0))
}
