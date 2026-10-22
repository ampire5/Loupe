import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

private let portrait = PixelSize(width: 3000, height: 4000)
private let landscape = PixelSize(width: 4000, height: 3000)
private let files = (1...6).map { URL(fileURLWithPath: "/f/\($0).jpg") }
private let folder = files[0].deletingLastPathComponent()
private let on = SpreadRules(on: true, options: SpreadOptions(shift: false, rightToLeft: false, landscapeAlone: true))
/// A folder seen for the first time: the thumbnail store knows no aspect yet.
private let noAspects: ([URL]) -> [Double?] = { _ in [] }

/// A window on a photo of a fresh folder, two pages off, its view landscape (an iMac's 16:9 window).
private func freshFolder(at index: Int = 0) -> SpreadState {
    var s = SpreadState()
    s.update(files: files, index: index, rules: { _ in .off }, aspects: noAspects)
    _ = s.setViewSize(CGSize(width: 3584, height: 1660))
    return s
}

/// `D`: the folder's rules turn two pages on and the plan is rebuilt (`ViewerSession.updateSpreadRules`).
private func pressD(_ s: inout SpreadState, at index: Int = 0) {
    let changed = s.setRules(on, folder: folder)
    #expect(changed)
    s.update(files: files, index: index, rebuild: true, rules: { _ in on }, aspects: noAspects)
}

@Test func firstDInAFreshFolderPairsOnceBothSizesAreKnown() {
    var s = freshFolder()
    _ = s.note(files[0], size: portrait, at: 0, aspects: [])   // the photo on screen, read with two pages off
    pressD(&s)
    #expect(s.companionURL == files[1])
    // The companion's size is unknown: its slot waits for its header instead of a stand-in of the photo's shape
    // that a wide page would take back (a flicker, then one page).
    #expect(SpreadSizes.pageSize(known: nil, aspect: nil, other: CGSize(width: 3000, height: 4000)) == nil)
    let rebuilds = s.note(files[1], size: portrait, at: 1, aspects: [])
    #expect(!rebuilds)
    #expect(s.navigation.pair(at: 0) == SpreadPair(first: 0, second: 1))
    #expect(s.navigation.refusal(at: 0) == nil)
}

/// The photo on screen is wide, and the store has no aspect for it yet: `D` shows it alone at once, and says why,
/// rather than pairing it as an unknown (portrait) page and taking the pair back when its header is asked again.
@Test func wideCurrentPageReadWithTwoPagesOffStandsAloneAtD() {
    var s = freshFolder()
    _ = s.note(files[0], size: landscape, at: 0, aspects: [])
    pressD(&s)
    #expect(s.companionURL == nil)
    #expect(s.navigation.refusal(at: 0) == .widePage)
}

@Test func wideCompanionHeaderRebuildsToOnePageWithItsReason() {
    var s = freshFolder()
    _ = s.note(files[0], size: portrait, at: 0, aspects: [])
    pressD(&s)
    let rebuilds = s.note(files[1], size: landscape, at: 1, aspects: [])
    #expect(rebuilds)   // the plan is to be rebuilt
    s.update(files: files, index: 0, rebuild: true, rules: { _ in on }, aspects: noAspects)
    #expect(s.companionURL == nil)
    #expect(s.navigation.refusal(at: 0) == .wideNext)
}

@Test func headersOfAnotherFolderAreForgotten() {
    var s = freshFolder()
    _ = s.note(files[0], size: landscape, at: 0, aspects: [])
    let other = URL(fileURLWithPath: "/g").appendingPathComponent("1.jpg")
    s.update(files: [other], index: 0, rules: { _ in .off }, aspects: noAspects)
    #expect(s.folder?.path == "/g")
    // Back in the first folder: its sizes are asked again, nothing stale is kept.
    s.update(files: files, index: 0, rules: { _ in on }, aspects: noAspects)
    #expect(s.companionURL == files[1])
}

@Test func narrowViewRefusesWithItsReason() {
    var s = freshFolder()
    pressD(&s)
    let follows = s.setViewSize(CGSize(width: 1000, height: 1600))
    #expect(follows)
    s.update(files: files, index: 0, rules: { _ in on }, aspects: noAspects)
    #expect(s.companionURL == nil)
    #expect(s.navigation.refusal(at: 0) == .narrowWindow)
    let followsAgain = s.setViewSize(CGSize(width: 1000, height: 1700))
    #expect(!followsAgain)   // still narrow: nothing to follow
}

@Test func offOrAPairHasNoRefusal() {
    var s = freshFolder()
    #expect(s.navigation.refusal(at: 0) == nil)
    pressD(&s)
    #expect(s.navigation.refusal(at: 0) == nil)
    #expect(s.navigation.refusal(at: 1) == nil)
}

@Test func refusalToasts() {
    #expect(SpreadKeys.toast(on: true, refusal: nil) == "Two pages")
    #expect(SpreadKeys.toast(on: true, refusal: .widePage) == "Two pages · this page is wide")
    #expect(SpreadKeys.toast(on: true, refusal: .wideNext) == "Two pages · next page is wide")
    #expect(SpreadKeys.toast(on: true, refusal: .narrowWindow) == "Two pages · window too narrow")
    #expect(SpreadKeys.toast(on: false, refusal: .widePage) == "One page")
    var config = Config()
    #expect(SpreadKeys.toggledLandscape(config) == "pair")
    #expect(config.set(SpreadKeys.landscapeKey, "pair") == .ok && !config.spreadLandscapeAlone)
    #expect(SpreadKeys.toggledLandscape(config) == "alone")
    #expect(SpreadKeys.toast(landscapeAlone: true) == "Landscape pages alone")
    #expect(SpreadKeys.toast(landscapeAlone: false) == "Landscape pages in pairs")
}

/// The store's aspects arriving in batches rebuild the plan; one that pairs the current photo the same is no
/// change of companion, so the session neither reads the page again nor lays it out anew.
@Test func aspectBatchThatPairsTheSameIsNoChange() {
    var s = freshFolder()
    pressD(&s)
    let portraits: ([URL]) -> [Double?] = { $0.map { _ in 0.75 } }
    let changed = s.update(files: files, index: 0, rebuild: true, rules: { _ in on }, aspects: portraits)
    #expect(!changed)
    #expect(s.companionURL == files[1])
    let wideSecond: ([URL]) -> [Double?] = { $0.indices.map { $0 == 1 ? 1.5 : 0.75 } }
    let changedAgain = s.update(files: files, index: 0, rebuild: true, rules: { _ in on }, aspects: wideSecond)
    #expect(changedAgain)
    #expect(s.companionURL == nil)
}
