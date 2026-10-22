import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

private let portrait = PixelSize(width: 3000, height: 4000)
private let landscape = PixelSize(width: 4000, height: 3000)

private func navigation(_ sizes: [PixelSize?], shift: Bool = false, showsTwo: Bool = true,
                        on: Bool = true) -> SpreadNavigation {
    let options = SpreadOptions(shift: shift, rightToLeft: false, landscapeAlone: true)
    return SpreadNavigation(plan: on ? SpreadPlan(sizes: sizes, options: options) : nil, showsTwo: showsTwo)
}

private let six = [PixelSize?](repeating: portrait, count: 6)

@Test func companionIsTheOtherPageOfThePairContainingCurrent() {
    let n = navigation(six)
    #expect(n.companion(of: 2) == 3)
    #expect(n.companion(of: 3) == 2)   // turned on mid-pair: the pair containing the photo
    #expect(n.focus(current: 3) == (2, 2))
}

@Test func singlePageHasNoCompanion() {
    let n = navigation([portrait, portrait, landscape, portrait])
    #expect(n.companion(of: 2) == nil)
    #expect(n.focus(current: 2) == (nil, 2))   // still stepping by pairs
}

@Test func narrowViewOrOffShowsOnePageAndStepsByOne() {
    for n in [navigation(six, showsTwo: false), navigation(six, on: false)] {
        #expect(!n.isActive)
        #expect(n.pair(at: 2) == nil)
        #expect(n.focus(current: 2) == (nil, 1))
        #expect(n.target(from: 2, by: 1, count: 6) == 3)
        #expect(n.target(from: 5, by: 1, count: 6) == nil)
        #expect(n.target(from: 0, by: -1, count: 6) == nil)
        #expect(n.last(from: 2, count: 6) == 5)
        #expect(n.first(from: 2, count: 6) == 0)
    }
}

@Test func stepsGoByPairsToTheirFirstPage() {
    let n = navigation(six)
    #expect(n.target(from: 0, by: 1, count: 6) == 2)
    #expect(n.target(from: 1, by: 1, count: 6) == 2)
    #expect(n.target(from: 3, by: -1, count: 6) == 0)
    #expect(n.target(from: 0, by: 2, count: 6) == 4)
    #expect(n.target(from: 4, by: 1, count: 6) == nil)   // the last pair: the end
    #expect(n.target(from: 1, by: -1, count: 6) == nil)
}

@Test func stepsFollowShiftAndLandscape() {
    let shifted = navigation(six, shift: true)
    #expect(shifted.target(from: 0, by: 1, count: 6) == 1)
    #expect(shifted.target(from: 2, by: 1, count: 6) == 3)
    #expect(shifted.target(from: 3, by: 1, count: 6) == 5)
    let mixed = navigation([portrait, portrait, landscape, portrait, portrait])
    #expect(mixed.target(from: 0, by: 1, count: 5) == 2)
    #expect(mixed.target(from: 2, by: 1, count: 5) == 3)
    #expect(mixed.target(from: 4, by: -1, count: 5) == 2)
}

@Test func homeAndEndLandOnTheFirstAndLastPair() {
    let n = navigation([portrait, portrait, portrait, portrait, portrait])
    #expect(n.last(from: 0, count: 5) == 4)   // the last page alone
    #expect(n.first(from: 3, count: 5) == 0)
    #expect(n.first(from: 1, count: 5) == 1)   // already in the first pair: stays
    let even = navigation(six)
    #expect(even.last(from: 0, count: 6) == 4)
    #expect(even.last(from: 5, count: 6) == 5)
    #expect(navigation([]).last(from: 0, count: 0) == nil)
}

@Test func onePageAfterAPairKeepsItsFirstPage() {
    let pair = SpreadPair(first: 12, second: 13)
    #expect(SpreadNavigation.single(after: pair, current: 13) == 12)
    #expect(SpreadNavigation.single(after: pair, current: 12) == nil)
    #expect(SpreadNavigation.single(after: SpreadPair(first: 4, second: nil), current: 4) == nil)
    #expect(SpreadNavigation.single(after: nil, current: 3) == nil)
}

@Test func sizesPreferHeadersThenAspects() {
    let files = (0..<4).map { URL(fileURLWithPath: "/f/\($0).jpg") }
    let sizes = SpreadSizes.sizes(files: files, aspects: [1.5, nil, 0.75], headers: [files[0]: portrait])
    #expect(sizes[0] == portrait)
    #expect(sizes[1] == nil)
    #expect(sizes[2].map { $0.width < $0.height } == true)
    #expect(sizes[3] == nil)   // past the aspects
    #expect(SpreadSizes.size(aspect: 0) == nil)
    #expect(SpreadSizes.size(aspect: .nan) == nil)
}

@Test func onlyACrossingOfSquareChangesPairing() {
    #expect(!SpreadSizes.changesPairing(from: nil, to: portrait))
    #expect(SpreadSizes.changesPairing(from: nil, to: landscape))
    #expect(!SpreadSizes.changesPairing(from: PixelSize(width: 2, height: 3), to: portrait))
    #expect(SpreadSizes.changesPairing(from: landscape, to: portrait))
}

@Test func unknownPageSizeIsSubstituted() {
    let other = CGSize(width: 3000, height: 4000)
    let known = CGSize(width: 10, height: 20)
    #expect(SpreadSizes.pageSize(known: known, aspect: 2, other: other) == known)
    #expect(SpreadSizes.pageSize(known: nil, aspect: 0.5, other: other) == CGSize(width: 2000, height: 4000))
    #expect(SpreadSizes.pageSize(known: .zero, aspect: nil, other: other) == other)
}

@Test func spreadKeysToastsAndValues() {
    var config = Config()
    #expect(SpreadKeys.toggled(config) == "yes")
    #expect(SpreadKeys.toggledShift(config) == "yes")
    config.spread = true
    config.spreadShift = true
    #expect(SpreadKeys.toggled(config) == "no")
    #expect(SpreadKeys.toggledShift(config) == "no")
    #expect(SpreadKeys.toast(on: true) == "Two pages")
    #expect(SpreadKeys.toast(on: false) == "One page")
    #expect(SpreadKeys.savedToast(on: true) == "Two pages · saved as default")
    #expect(SpreadKeys.savedToast(on: false) == "One page · saved as default")
    #expect(SpreadKeys.toast(shift: true) == "Pages shifted")
    #expect(SpreadKeys.toast(shift: false) == "Pages not shifted")
    #expect(SpreadRules(config: config).on)
    #expect(SpreadRules(config: config).options.shift)
    #expect(!SpreadRules.off.on)
}
