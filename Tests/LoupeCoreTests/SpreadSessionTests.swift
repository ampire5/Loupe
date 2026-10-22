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
    #expect(SpreadSizes.pageSize(known: .zero, aspect: nil, other: other) == nil)   // waits for its header
    #expect(SpreadSizes.pageSize(known: nil, aspect: nil, other: other, failed: true) == other)
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
    #expect(SpreadKeys.toggledDirection(config) == "rtl")
    #expect(SpreadKeys.toast(rightToLeft: true) == "Right to left")
    #expect(SpreadKeys.toast(rightToLeft: false) == "Left to right")
    var rtl = config
    #expect(rtl.set(SpreadKeys.directionKey, SpreadKeys.toggledDirection(config)) == .ok && rtl.spreadRightToLeft)
    #expect(SpreadKeys.toggledDirection(rtl) == "ltr")
    #expect(SpreadRules(config: config).on)
    #expect(SpreadRules(config: config).options.shift)
    #expect(!SpreadRules.off.on)
}

/// Two pages on: the page at the left keeps its spot and its drawn scale in the wider picture; and back.
@Test func zoomFollowsThePageIntoAndOutOfAPair() {
    let page = CGSize(width: 1000, height: 1500)
    let single = ViewTransform(imageSize: page, viewSize: CGSize(width: 1600, height: 1000), mode: .free(3),
                               center: CGPoint(x: 0.25, y: 0.75))
    let layout = SpreadLayout(first: page, second: CGSize(width: 500, height: 750), rightToLeft: false)
    let pair = SpreadZoom.carried(single, from: nil, to: layout.virtualSize, at: layout.rects[0])
    #expect(layout.virtualSize == CGSize(width: 2000, height: 1500))
    #expect(pair.center == CGPoint(x: 0.125, y: 0.75))
    #expect(abs(pair.scale - single.scale) < 1e-9)
    let back = SpreadZoom.carried(pair, from: layout.rects[0], to: page, at: nil)
    #expect(abs(back.center.x - 0.25) < 1e-12 && abs(back.center.y - 0.75) < 1e-12)
    #expect(abs(back.scale - single.scale) < 1e-9)
    // The right page, shorter than the picture: its scale is kept, the picture's grows by the height ratio.
    let small = ViewTransform(imageSize: CGSize(width: 500, height: 750), viewSize: single.viewSize, mode: .free(2))
    let right = SpreadZoom.carried(small, from: nil, to: layout.virtualSize, at: layout.rects[1])
    #expect(right.center == CGPoint(x: 0.75, y: 0.5))
    #expect(abs(right.scale - small.scale * 750 / 1500) < 1e-9)
}

@Test func namedModesStayWhenAPageMoves() {
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1500), viewSize: CGSize(width: 1600, height: 1000),
                          mode: .actual(1), center: CGPoint(x: 0.5, y: 0.5))
    let moved = SpreadZoom.carried(t, from: nil, to: CGSize(width: 2000, height: 1500),
                                   at: CGRect(x: 1000, y: 0, width: 1000, height: 1500))
    #expect(moved.mode == .actual(1))
    #expect(moved.center == CGPoint(x: 0.75, y: 0.5))
    #expect(SpreadZoom.carried(t, from: nil, to: .zero, at: nil).imageSize == .zero)   // degenerate: no NaN
}

/// A restore shown on a stand-in size waits from that show: the user's zoom since then still drops it.
@Test func restoreWaitsFromTheProvisionalShow() {
    let url = URL(fileURLWithPath: "/f/a.jpg")
    let size = CGSize(width: 2000, height: 1500)
    let saved = SavedView(mode: .actual(2), center: CGPoint(x: 0.3, y: 0.6), imageSize: size)
    let arrival = ViewTransform(imageSize: CGSize(width: 900, height: 600), viewSize: CGSize(width: 1600, height: 1000))
    let provisional = ViewTransform(imageSize: CGSize(width: 1990, height: 1500), viewSize: arrival.viewSize,
                                    mode: .free(1.5))
    let r = ViewRestore(file: url, view: saved, arrival: arrival)
    #expect(r.target(imageSize: provisional.imageSize) == nil)   // the stand-in size: the saved view does not apply yet
    let waiting = r.rearrived(at: provisional)
    #expect(waiting.transform(for: url, imageSize: size, over: provisional.withImageSize(size))?.mode == .actual(2))
    #expect(waiting.transform(for: url, imageSize: size, over: provisional.withMode(.fit).withImageSize(size)) == nil)
}

private let waitURL = URL(fileURLWithPath: "/f/w.jpg")
private let realSize = CGSize(width: 2000, height: 1500)
private let standIn = CGSize(width: 1990, height: 1500)
private let viewSize = CGSize(width: 1600, height: 1000)
private let savedPair = SavedView(mode: .actual(2), center: CGPoint(x: 0.3, y: 0.6), imageSize: realSize)
private let arrived = ViewTransform(imageSize: CGSize(width: 900, height: 600), viewSize: viewSize)

/// A zoom key pressed while the photo loaded: the show carries the key's mode, and the restore is dropped, not re-armed.
@Test func zoomKeyWhileLoadingDropsTheWaitingRestore() {
    let r = ViewRestore(file: waitURL, view: savedPair, arrival: arrived)
    let keyed = arrived.withMode(.actual(1))
    let shown = keyed.withImageSize(standIn)
    #expect(r.waiting(atShowOf: standIn, provisional: true, before: keyed, shown: shown) == nil)
    // Untouched: it waits, and applies once the real size is in.
    let waiting = r.waiting(atShowOf: standIn, provisional: true, before: arrived, shown: arrived.withImageSize(standIn))
    #expect(waiting != nil)
    #expect(waiting?.transform(for: waitURL, imageSize: realSize, over: arrived.withImageSize(standIn))?.mode == .actual(2))
    // Not provisional, or a stand-in the view already fits: decided now.
    #expect(r.waiting(atShowOf: standIn, provisional: false, before: arrived, shown: arrived) == nil)
    #expect(r.waiting(atShowOf: realSize, provisional: true, before: arrived, shown: arrived) == nil)
}

/// A zoom or pan after the first show, then a finer level shown: the restore is dropped.
@Test func zoomAfterTheFirstShowDropsTheWaitingRestore() {
    let first = arrived.withImageSize(standIn)
    let waiting = ViewRestore(file: waitURL, view: savedPair, arrival: arrived)
        .waiting(atShowOf: standIn, provisional: true, before: arrived, shown: first)
    let zoomed = first.withMode(.free(2))
    #expect(waiting?.waiting(atShowOf: standIn, provisional: true, before: zoomed, shown: zoomed) == nil)
    let panned = ViewTransform(imageSize: standIn, viewSize: viewSize, mode: .fit, center: CGPoint(x: 0.4, y: 0.5))
    #expect(waiting?.waiting(atShowOf: standIn, provisional: true, before: panned, shown: panned) == nil)
    // Untouched, a finer level keeps it waiting.
    #expect(waiting?.waiting(atShowOf: standIn, provisional: true, before: first, shown: first) != nil)
}

/// Another stand-in moves the view (`SpreadZoom.carried` shifts the centre even in Fit): the restore follows it and
/// still applies with the real size; after the user's own zoom it is dropped.
@Test func standInChangeKeepsTheRestoreWaiting() {
    let first = arrived.withImageSize(standIn)
    let waiting = ViewRestore(file: waitURL, view: savedPair, arrival: arrived)
        .waiting(atShowOf: standIn, provisional: true, before: arrived, shown: first)!
    let other = CGSize(width: 2400, height: 1500)
    let carried = SpreadZoom.carried(first, from: CGRect(x: 0, y: 0, width: 1000, height: 1500), to: other,
                                     at: CGRect(x: 0, y: 0, width: 1000, height: 1500))
    #expect(carried.center != first.center)
    #expect(!waiting.isUntouched(by: carried))
    let followed = waiting.following(from: first, to: carried)
    #expect(followed?.transform(for: waitURL, imageSize: realSize, over: carried.withImageSize(realSize))?.mode
            == .actual(2))
    #expect(waiting.following(from: first.withMode(.free(3)), to: carried) == nil)
}

/// The first page alone after its pair: carried at the show from the window of then, so a resize meanwhile keeps the
/// current view size; a zoom key meanwhile, another photo or size drop it.
@Test func collapseFollowsTheWindowAndYieldsToAZoomKey() {
    let first = URL(fileURLWithPath: "/f/12.jpg")
    let page = CGSize(width: 1000, height: 1500)
    let layout = SpreadLayout(first: page, second: page, rightToLeft: false)
    let pair = ViewTransform(imageSize: layout.virtualSize, viewSize: CGSize(width: 2400, height: 1200), mode: .free(4),
                             center: CGPoint(x: 0.25, y: 0.5))
    let collapse = SpreadCollapse(page: first, rect: layout.rects[0], pageSize: page, from: pair)
    let resized = pair.withViewSize(CGSize(width: 1000, height: 1200))   // narrower than tall: the collapse's cause
    let shown = collapse.transform(for: first, size: page, over: resized)
    #expect(shown?.viewSize == resized.viewSize)
    #expect(shown?.center == CGPoint(x: 0.5, y: 0.5))
    #expect(shown.map { abs($0.scale - resized.scale) < 1e-9 } == true)
    #expect(collapse.transform(for: first, size: page, over: pair.withMode(.actual(1))) == nil)   // a zoom key
    #expect(collapse.transform(for: first, size: CGSize(width: 999, height: 1500), over: pair) == nil)
    #expect(collapse.transform(for: URL(fileURLWithPath: "/f/13.jpg"), size: page, over: pair) == nil)
}
