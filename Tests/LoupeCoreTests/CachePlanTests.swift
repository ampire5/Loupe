import Testing
import Foundation
@testable import LoupeCore

private let screen = PixelSize(width: 6144, height: 3456)
private let big = PixelSize(width: 10502, height: 14000)      // 147 MP
private let small = PixelSize(width: 3840, height: 2161)      // fits the screen: Lfit 0
private let mb = 1_000_000

private func facts(_ size: PixelSize = big, fileSize: Int = 12 * mb) -> (Int) -> EntryFacts {
    { _ in EntryFacts(pixelSize: size, fileSize: fileSize) }
}

private func focus(count: Int = 200, current: Int = 100, direction: Int = 1, dwelling: Bool = true, needsFull: Bool = false) -> CacheFocus {
    CacheFocus(count: count, current: current, direction: direction, dwelling: dwelling, needsFull: needsFull, screen: screen)
}


private func plan(_ focus: CacheFocus = focus(), _ limits: CacheLimits = CacheLimits.at3G,
                  _ facts: (Int) -> EntryFacts = facts()) -> [CacheItem] {
    CachePlan.make(focus: focus, limits: limits, facts: facts)
}

private func names(_ items: some Sequence<CacheItem>) -> [String] { items.map { "\($0.index):\($0.goal)" } }

private func limits(_ edit: (inout CacheLimits) -> Void) -> CacheLimits {
    var l = CacheLimits.at3G
    edit(&l)
    return l
}

/// Costs as the spec defines them, computed independently of the plan.
private struct Costs {
    let grid: TileGrid
    let lfit: Int
    init(_ size: PixelSize) {
        grid = TileGrid(imageSize: size)
        lfit = grid.previewLevel(forScreen: screen)
    }
    var preview: Int { grid.byteCount(levels: lfit..<grid.levelCount) }
    var coarse: Int { grid.byteCount(levels: min(lfit + 1, grid.levelCount - 1)..<grid.levelCount) }
    var full: Int { grid.byteCount(levels: 0..<lfit) }
    var all: Int { grid.byteCount(levels: 0..<grid.levelCount) }
}

/// The current photo, n1/p1 previews, n1 full, the 24 neighbours' bytes (cache-files default) two ahead for one
/// behind, then the remaining previews (far ones coarse).
@Test func orderForward() {
    let items = plan()
    #expect(names(items.prefix(36)) == [
        "100:preview", "100:bytes", "100:full", "101:preview", "99:preview", "101:full",
        "101:bytes", "99:bytes", "102:bytes", "103:bytes", "98:bytes", "104:bytes", "105:bytes", "97:bytes",
        "106:bytes", "107:bytes", "96:bytes", "108:bytes", "109:bytes", "95:bytes", "110:bytes", "111:bytes",
        "94:bytes", "112:bytes", "113:bytes", "93:bytes", "114:bytes", "115:bytes", "92:bytes", "116:bytes",
        "102:preview", "103:preview", "98:preview", "104:coarse", "105:coarse", "97:preview",
    ])
}

@Test func orderBackwardMirrors() {
    let items = plan(focus(direction: -1))
    #expect(names(items.prefix(36)) == [
        "100:preview", "100:bytes", "100:full", "99:preview", "101:preview", "99:full",
        "99:bytes", "101:bytes", "98:bytes", "97:bytes", "102:bytes", "96:bytes", "95:bytes", "103:bytes",
        "94:bytes", "93:bytes", "104:bytes", "92:bytes", "91:bytes", "105:bytes", "90:bytes", "89:bytes",
        "106:bytes", "88:bytes", "87:bytes", "107:bytes", "86:bytes", "85:bytes", "108:bytes", "84:bytes",
        "98:preview", "97:preview", "102:preview", "96:coarse", "95:coarse", "103:preview",
    ])
}

@Test func directionZeroIsForward() {
    #expect(plan(focus(direction: 0)) == plan(focus(direction: 1)))
}

@Test func itemCostsFollowTheSpec() {
    let c = Costs(big)
    let items = plan()
    func cost(_ index: Int, _ goal: CacheGoal) -> Int? { items.first { $0.index == index && $0.goal == goal }?.cost }
    #expect(c.lfit == 2)
    #expect(cost(100, .preview) == c.preview && cost(100, .full) == c.full)
    #expect(cost(100, .bytes) == 12 * mb && cost(101, .bytes) == 12 * mb)
    #expect(cost(104, .coarse) == c.coarse && cost(102, .preview) == c.preview)
    #expect(c.coarse < c.preview)
}

/// While scrubbing the plan wants nothing, not even the photo under the cursor (spec M2.5 §5.3); dropping the flag
/// gives the plan as before.
@Test func scrubbingPlansNothing() {
    var scrubbing = focus()
    scrubbing.scrubbing = true
    #expect(scrubbing != focus())
    #expect(plan(scrubbing).isEmpty)
    #expect(plan(CacheFocus(count: 200, current: 100, direction: 1, dwelling: false, needsFull: true, screen: screen,
                            previous: 99, scrubbing: true)).isEmpty)
    scrubbing.scrubbing = false
    #expect(plan(scrubbing) == plan())
}

@Test func notDwellingHasNoFull() {
    let items = plan(focus(dwelling: false))
    #expect(!items.contains { $0.goal == .full })
    #expect(items.first == CacheItem(index: 100, goal: .preview, cost: Costs(big).preview))
}

/// A photo opened from outside (launch, Finder, File › Open) wants its full resolution at once, right after its
/// preview, without the dwell; the neighbours' full resolutions still wait for it.
@Test func openedPlansCurrentFullWithoutDwell() {
    var opened = focus(dwelling: false)
    opened.opened = true
    let items = plan(opened)
    #expect(names(items.prefix(3)) == ["100:preview", "100:bytes", "100:full"])
    #expect(items.filter { $0.goal == .full }.map(\.index) == [100])
    #expect(!plan(focus(dwelling: false)).contains { $0.goal == .full })
    // A photo whose preview is already full resolution (Lfit 0) gets no second decode of the same level.
    #expect(!plan(opened, CacheLimits.at3G, facts(small)).contains { $0.goal == .full })
}

@Test func cacheFullTiers() {
    func fulls(_ l: CacheLimits, _ size: PixelSize = big) -> [Int] {
        plan(focus(), l, facts(size)).filter { $0.goal == .full }.map(\.index)
    }
    #expect(fulls(limits { $0.full = 0 }) == [100])
    #expect(fulls(limits { $0.full = 1 }) == [100, 101])
    #expect(fulls(limits { $0.full = 2 }, small) == [100, 101, 99])
    // 3 GB cannot hold three 147 MP full-resolution photos next to the previews: p1 is skipped by the ceiling.
    let items = plan(focus(), limits { $0.full = 2 })
    #expect(items.filter { $0.goal == .full }.map(\.index) == [100, 101])
    #expect(items.reduce(0) { $0 + $1.cost } <= 3 << 30)
}

@Test func fullOfAFittingImageCostsNothing() {
    // Lfit 0: the preview already is the whole pyramid, so "full" adds no memory but is still listed.
    let items = plan(focus(), CacheLimits.at3G, facts(small))
    #expect(items.first { $0.index == 100 && $0.goal == .full }?.cost == 0)
}

@Test func twentyPreviews() {
    let items = plan()
    let photos = Set(items.filter { $0.goal == .preview || $0.goal == .coarse }.map(\.index))
    #expect(photos.count == 20)
    #expect(items.filter { $0.goal == .preview || $0.goal == .coarse }.count == 20)   // each photo once
    #expect(photos.contains(100) && photos.contains(101) && photos.contains(99))
    #expect(plan(focus(), limits { $0.previews = 1 }).filter { $0.goal == .preview || $0.goal == .coarse }.map(\.index) == [100])
    #expect(Set(plan(focus(), limits { $0.previews = 3 }).filter { $0.goal == .preview }.map(\.index)) == [100, 101, 99])
}

@Test func farPreviewsFull() {
    let items = plan(focus(), limits { $0.farPreviewsCoarse = false })
    #expect(!items.contains { $0.goal == .coarse })
    // Next to two fulls and 25 files' bytes, 3 GB holds 19 full-Lfit 147 MP previews: the 20th is cut by the ceiling.
    #expect(items.filter { $0.goal == .preview }.count == 19)
    #expect(items.reduce(0) { $0 + $1.cost } <= 3 << 30)
    #expect(plan(focus(), limits { $0.farPreviewsCoarse = false; $0.memory = 4 << 30 }).filter { $0.goal == .preview }.count == 20)
}

@Test func farPreviewIsPlainPreviewWithoutACoarserLevel() {
    // 100x100 has a single level, so there is nothing coarser than Lfit to hold a far photo at.
    let tiny = PixelSize(width: 100, height: 100)
    let items = plan(focus(), CacheLimits.at3G, facts(tiny))
    #expect(!items.contains { $0.goal == .coarse })
    #expect(items.contains { $0.index == 105 && $0.goal == .preview })
}

@Test func cacheFilesCount() {
    let l = limits { $0.files = 2 }
    let bytes = plan(focus(), l).filter { $0.goal == .bytes }.map(\.index)
    #expect(bytes == [100, 101, 99])        // the current photo's bytes are extra
    #expect(plan(focus(), limits { $0.files = 0 }).filter { $0.goal == .bytes }.map(\.index) == [100])
}

@Test func needsFullCurrent() {
    let c = Costs(big)
    let items = plan(focus(dwelling: false, needsFull: true))
    #expect(items.first == CacheItem(index: 100, goal: .full, cost: c.all))
    #expect(!items.contains { $0.index == 100 && $0.goal == .preview })
    // Dwelling adds no second full for the current photo.
    #expect(plan(focus(dwelling: true, needsFull: true)).filter { $0.index == 100 && $0.goal == .full }.count == 1)
}

@Test func largeItemSkippedSmallerKept() {
    let c = Costs(big)
    let file = 1 * mb
    // Room for the current photo's preview, bytes and full, plus 10 MB: neighbours' previews and n1's full do not fit,
    // the small bytes items still do, ten of the 24 cache-files (1 MB each) next to the current photo's.
    let memory = c.preview + file + c.full + 10 * mb
    let items = plan(focus(), limits { $0.memory = memory }, facts(big, fileSize: file))
    #expect(!items.contains { $0.index == 101 && ($0.goal == .full || $0.goal == .preview) })
    #expect(items.contains { $0.index == 101 && $0.goal == .bytes })
    #expect(items.filter { $0.goal == .bytes }.count == 11)
    #expect(items.reduce(0) { $0 + $1.cost } <= memory)
}

@Test func skippedItemDoesNotConsumeItsTiersCount() {
    // cache-files=1 and n1's file (100 MB) does not fit under the ceiling: the skipped item must not use up the
    // one slot, so p1's small file still gets planned.
    let c = Costs(big)
    let memory = c.preview + 12 * mb + c.full + 5 * mb
    let sizes: (Int) -> EntryFacts = { i in
        EntryFacts(pixelSize: big, fileSize: i == 101 ? 100 * mb : 1 * mb)
    }
    let items = plan(focus(), limits { $0.files = 1; $0.memory = memory }, sizes)
    #expect(!items.contains { $0.index == 101 })
    #expect(items.filter { $0.goal == .bytes && $0.index != 100 }.map(\.index) == [99])
}

@Test func playlistEdges() {
    let first = plan(focus(current: 0))
    #expect(first.allSatisfy { $0.index >= 0 && $0.index < 200 })
    #expect(first.first?.index == 0)
    #expect(first.contains { $0.index == 1 } && first.contains { $0.index == 19 })     // reaches forward for the missing previous side
    let last = plan(focus(current: 199, direction: -1))
    #expect(last.allSatisfy { $0.index >= 0 && $0.index < 200 })
    let one = plan(focus(count: 1, current: 0))
    #expect(Set(one.map(\.index)) == [0])
    #expect(names(one) == ["0:preview", "0:bytes", "0:full"])
}

@Test func failedSkipped() {
    let failing: (Int) -> EntryFacts = { i in EntryFacts(pixelSize: big, fileSize: 12 * mb, failed: i == 101 || i == 100) }
    let items = plan(focus(), CacheLimits.at3G, failing)
    #expect(!items.contains { $0.index == 101 })
    #expect(items.contains { $0.index == 100 && $0.goal == .preview })
    #expect(items.contains { $0.index == 99 && $0.goal == .full } == false)   // cache-full 1: only n1 would get it
}

@Test func estimateUsesMedianOfKnown() {
    let known = PixelSize(width: 4000, height: 3000)
    let partial: (Int) -> EntryFacts = { i in i == 5 ? EntryFacts(pixelSize: known, fileSize: 5 * mb) : EntryFacts() }
    let items = plan(focus(count: 10, current: 5), CacheLimits.at3G, partial)
    let c = Costs(known)
    #expect(items.first { $0.index == 6 && $0.goal == .preview }?.cost == c.preview)
    #expect(items.first { $0.index == 6 && $0.goal == .bytes }?.cost == CachePlan.defaultFileSize)
    #expect(items.first { $0.index == 5 && $0.goal == .bytes }?.cost == 5 * mb)
    // Nothing known at all: the 147 MP default.
    let none = plan(focus(count: 10, current: 5), CacheLimits.at3G, { _ in EntryFacts() })
    #expect(none.first { $0.index == 6 && $0.goal == .preview }?.cost == Costs(CachePlan.defaultPixelSize).preview)
}

@Test func medianIsByPixelCount() {
    let sizes = [PixelSize(width: 1000, height: 1000), PixelSize(width: 2000, height: 2000), PixelSize(width: 8000, height: 6000)]
    let f: (Int) -> EntryFacts = { i in i < 3 ? EntryFacts(pixelSize: sizes[i]) : EntryFacts() }
    let items = plan(focus(count: 10, current: 5), CacheLimits.at3G, f)
    #expect(items.first { $0.index == 6 && $0.goal == .preview }?.cost == Costs(sizes[1]).preview)
}

@Test func realSizeReplacesEstimate() {
    let before = plan(focus(count: 10, current: 5), CacheLimits.at3G, { _ in EntryFacts() })
    let after = plan(focus(count: 10, current: 5), CacheLimits.at3G, { i in
        i == 6 ? EntryFacts(pixelSize: PixelSize(width: 3000, height: 2000), fileSize: 2 * mb) : EntryFacts()
    })
    func cost(_ items: [CacheItem], _ goal: CacheGoal) -> Int? { items.first { $0.index == 6 && $0.goal == goal }?.cost }
    #expect(cost(after, .preview) == Costs(PixelSize(width: 3000, height: 2000)).preview)
    #expect(cost(after, .preview) != cost(before, .preview))
    #expect(cost(after, .bytes) == 2 * mb && cost(before, .bytes) == CachePlan.defaultFileSize)
}

@Test func totalNeverExceedsMemoryBeyondTheCurrentPhoto() {
    for memory in [1 << 20, 100 * mb, 500 * mb, 3 << 30] {
        let items = plan(focus(), limits { $0.memory = memory })
        let current = items.filter { $0.index == 100 }.reduce(0) { $0 + $1.cost }
        #expect(items.reduce(0) { $0 + $1.cost } <= max(memory, current))
    }
    // Plenty of room: the whole plan fits.
    #expect(plan().reduce(0) { $0 + $1.cost } <= 3 << 30)
}

@Test func currentExemptFromCeiling() {
    let c = Costs(big)
    let items = plan(focus(), limits { $0.memory = 1 * mb })
    #expect(items == [CacheItem(index: 100, goal: .preview, cost: c.preview),
                      CacheItem(index: 100, goal: .bytes, cost: 12 * mb),
                      CacheItem(index: 100, goal: .full, cost: c.full)])
    #expect(plan(focus(needsFull: true), limits { $0.memory = 1 * mb }) == [
        CacheItem(index: 100, goal: .full, cost: c.all), CacheItem(index: 100, goal: .bytes, cost: 12 * mb)])
}

@Test func playlistShorterThanPreviews() {
    let items = plan(focus(count: 5, current: 2))
    #expect(items.allSatisfy { (0..<5).contains($0.index) })
    let previewed = Set(items.filter { $0.goal == .preview || $0.goal == .coarse }.map(\.index))
    #expect(previewed == [0, 1, 2, 3, 4])
}

@Test func allNeighboursFailed() {
    let f: (Int) -> EntryFacts = { i in EntryFacts(pixelSize: big, fileSize: 12 * mb, failed: i != 100) }
    let items = plan(focus(), CacheLimits.at3G, f)
    #expect(names(items) == ["100:preview", "100:bytes", "100:full"])
}

// MARK: - The photo just left (spec §11.1.7)

private func withPrevious(_ f: CacheFocus, _ previous: Int?) -> CacheFocus {
    var f = f
    f.previous = previous
    return f
}

/// Its full resolution, when it still has it, comes right after the n1/p1 previews and ahead of n1's full.
@Test func previousFullKeptAheadOfNextFull() {
    let kept: (Int) -> EntryFacts = { EntryFacts(pixelSize: big, fileSize: 12 * mb, fullKept: $0 == 99) }
    let items = plan(withPrevious(focus(), 99), CacheLimits.at3G, kept)
    #expect(names(items.prefix(7)) == [
        "100:preview", "100:bytes", "100:full", "101:preview", "99:preview", "99:full", "101:full",
    ])
    #expect(items[5].cost == Costs(big).full)
    #expect(items.filter { $0.index == 99 && $0.goal == .full }.count == 1)
}

/// Also when it is not p1 (a jump), and never twice with `cache-full = 2` (which plans p1's full anyway).
@Test func previousFullNotDuplicated() {
    let kept: (Int) -> EntryFacts = { EntryFacts(pixelSize: big, fileSize: 12 * mb, fullKept: $0 == 99) }
    let items = plan(withPrevious(focus(), 99), limits { $0.full = 2 }, kept)
    #expect(items.filter { $0.index == 99 && $0.goal == .full }.count == 1)
    let jumped = plan(withPrevious(focus(), 40), CacheLimits.at3G,
                      { EntryFacts(pixelSize: big, fileSize: 12 * mb, fullKept: $0 == 40) })
    #expect(names(jumped.prefix(6)) == ["100:preview", "100:bytes", "100:full", "101:preview", "99:preview", "40:full"])
}

/// Without its full resolution resident or in flight it is not planned: no new decode for a photo left behind.
@Test func previousNotPlannedWhenNotKept() {
    let items = plan(withPrevious(focus(), 99))
    #expect(!items.contains { $0.index == 99 && $0.goal == .full })
    #expect(names(items.prefix(6)) == ["100:preview", "100:bytes", "100:full", "101:preview", "99:preview", "101:full"])
}

/// The plan's Lfit follows the orientation the photos are shown with: an EXIF 6 iPhone photo (stored 4032x3024) on a
/// 3024x1964 screen gets the oriented fit's level 1 as its preview, the stored level 0 with `exif-orientation=no`.
@Test func previewLevelFollowsOrientation() throws {
    let stored = PixelSize(width: 4032, height: 3024), laptop = PixelSize(width: 3024, height: 1964)
    let turned: (Int) -> EntryFacts = { _ in EntryFacts(pixelSize: stored, orientation: .right, fileSize: 3 * mb) }
    func previewCost(applying: Bool) throws -> Int {
        let f = CacheFocus(count: 3, current: 1, direction: 1, dwelling: false, needsFull: false, screen: laptop,
                           appliesOrientation: applying)
        return try #require(plan(f, CacheLimits.at3G, turned).first { $0.index == 1 && $0.goal == .preview }).cost
    }
    let grid = TileGrid(imageSize: stored)
    #expect(try previewCost(applying: true) == grid.byteCount(levels: 1..<grid.levelCount))
    #expect(try previewCost(applying: false) == grid.byteCount(levels: 0..<grid.levelCount))
}

/// An opened photo skips the second decode only when its preview already is level 0 of the stored pyramid, judged
/// with the orientation it is shown with: the EXIF 6 iPhone photo above needs its full resolution at once when turned
/// (Lfit 1), and has it in its preview with `exif-orientation=no` (Lfit 0).
@Test func openedFullFollowsOrientation() {
    let stored = PixelSize(width: 4032, height: 3024), laptop = PixelSize(width: 3024, height: 1964)
    let turned: (Int) -> EntryFacts = { _ in EntryFacts(pixelSize: stored, orientation: .right, fileSize: 3 * mb) }
    func fulls(applying: Bool) -> [Int] {
        let f = CacheFocus(count: 3, current: 1, direction: 1, dwelling: false, needsFull: false, screen: laptop,
                           appliesOrientation: applying, opened: true)
        return plan(f, CacheLimits.at3G, turned).filter { $0.goal == .full }.map(\.index)
    }
    #expect(fulls(applying: true) == [1])
    #expect(fulls(applying: false).isEmpty)
}

// MARK: - A pair on screen (spread)

private func pairFocus(current: Int = 10, companion: Int? = 11, step: Int = 2, direction: Int = 1,
                       dwelling: Bool = true) -> CacheFocus {
    var f = focus(count: 200, current: current, direction: direction, dwelling: dwelling)
    f.companion = companion
    f.step = step
    return f
}

@Test func companionFocusFollowsPlan() {
    let items = plan(pairFocus())
    // Current, then its companion, then the pairs around: ahead 12 13, behind 8 9.
    var order: [Int] = []
    for item in items where !order.contains(item.index) { order.append(item.index) }
    #expect(Array(order.prefix(6)) == [10, 11, 12, 13, 8, 9])
    // Both pages of the pair reach full on dwell.
    #expect(items.contains { $0.index == 10 && $0.goal == .full })
    #expect(items.contains { $0.index == 11 && $0.goal == .full })
}

@Test func companionBackwardMirrors() {
    let items = plan(pairFocus(current: 11, companion: 10, direction: -1))
    var order: [Int] = []
    for item in items where !order.contains(item.index) { order.append(item.index) }
    #expect(Array(order.prefix(6)) == [11, 10, 9, 8, 13, 12])
}

@Test func noCompanionUnchanged() {
    var f = focus()
    let base = plan(f)
    f.companion = nil
    f.step = 1
    #expect(plan(f) == base)
}

@Test func companionFullIsNotLimitedByCacheFull() {
    let zero = limits { $0.full = 0 }
    let items = plan(pairFocus(), zero)
    #expect(items.filter { $0.goal == .full }.map(\.index).sorted() == [10, 11])
}

@Test func companionWithoutDwellHasNoFull() {
    #expect(!plan(pairFocus(dwelling: false)).contains { $0.goal == .full })
}

@Test func openedCompanionThatFitsIsNotDecodedTwice() {
    var f = pairFocus(dwelling: false)
    f.opened = true
    let mixed: (Int) -> EntryFacts = { EntryFacts(pixelSize: $0 == 11 ? small : big, fileSize: 12 * mb) }
    let fulls = plan(f, CacheLimits.at3G, mixed).filter { $0.goal == .full }.map(\.index)
    #expect(fulls == [10])
}

@Test func justLeftCompanionIsPlannedFullOnce() {
    var f = pairFocus()
    f.previous = 11
    let kept: (Int) -> EntryFacts = { EntryFacts(pixelSize: big, fileSize: 12 * mb, fullKept: $0 == 11) }
    let items = plan(f, CacheLimits.at3G, kept)
    #expect(items.filter { $0.index == 11 && $0.goal == .full }.count == 1)
    #expect(items.filter { $0.index == 10 && $0.goal == .full }.count == 1)
}

/// Both pages of the pair just left keep their full resolution (rule 3a), not only the page that was current.
@Test func justLeftPairKeepsBothPagesFull() {
    var f = pairFocus(current: 12, companion: 13)
    f.previous = 10
    f.previousCompanion = 11
    let photo = PixelSize(width: 6000, height: 4000)   // two full ones fit the memory, unlike two 147 MP ones
    let kept: (Int) -> EntryFacts = { EntryFacts(pixelSize: photo, fileSize: 12 * mb, fullKept: $0 == 10 || $0 == 11) }
    let items = plan(f, CacheLimits.at3G, kept)
    #expect(items.contains { $0.index == 10 && $0.goal == .full })
    #expect(items.contains { $0.index == 11 && $0.goal == .full })
}

// MARK: - Two memory tiers (a discrete card)

/// Without a graphics tier (unified memory) the plan is the one made before the tiers existed: one total against
/// `cache-memory`. Pinned from the plans of the code before the tiers, for a step forward, one back at 100 %, a
/// tight `cache-memory` and `cache-full = 2` at 4 GiB, each with the photo just left holding its full resolution.
@Test func unifiedPlanUnchanged() {
    let kept: (Int) -> EntryFacts = { EntryFacts(pixelSize: big, fileSize: 12 * mb, fullKept: $0 == 99) }
    func pinned(direction: Int, needsFull: Bool, _ l: CacheLimits) -> (count: Int, cost: Int, names: String) {
        var l = l
        l.graphicsMemory = nil
        let items = plan(withPrevious(focus(direction: direction, needsFull: needsFull), 99), l, kept)
        return (items.count, items.reduce(0) { $0 + $1.cost }, names(items).joined(separator: " "))
    }
    let forward = pinned(direction: 1, needsFull: false, CacheLimits.at3G)
    #expect(forward.count == 36 && forward.cost == 3_214_965_504)
    #expect(forward.names == "100:preview 100:bytes 100:full 101:preview 99:preview 99:full 101:full 101:bytes 99:bytes "
            + "102:bytes 103:bytes 98:bytes 104:bytes 105:bytes 97:bytes 106:bytes 107:bytes 96:bytes 108:bytes 109:bytes "
            + "95:bytes 110:bytes 111:bytes 94:bytes 112:bytes 113:bytes 93:bytes 114:bytes 115:bytes 92:bytes 116:bytes "
            + "102:preview 103:preview 98:preview 104:coarse 105:coarse")
    let back = pinned(direction: -1, needsFull: true, CacheLimits.at3G)
    #expect(back.count == 46 && back.cost == 2_661_858_048)
    #expect(back.names == "100:full 100:bytes 99:preview 101:preview 99:full 99:bytes 101:bytes 98:bytes 97:bytes "
            + "102:bytes 96:bytes 95:bytes 103:bytes 94:bytes 93:bytes 104:bytes 92:bytes 91:bytes 105:bytes 90:bytes "
            + "89:bytes 106:bytes 88:bytes 87:bytes 107:bytes 86:bytes 85:bytes 108:bytes 84:bytes 98:preview 97:preview "
            + "102:preview 96:coarse 95:coarse 103:preview 94:coarse 93:coarse 104:coarse 92:coarse 91:coarse 105:coarse "
            + "90:coarse 89:coarse 106:coarse 88:coarse 87:coarse")
    let tight = pinned(direction: 1, needsFull: false, limits { $0.memory = 1 << 30 })
    #expect(tight.count == 8 && tight.cost == 1_072_809_984)
    #expect(tight.names == "100:preview 100:bytes 100:full 101:preview 99:preview 101:bytes 99:bytes 102:bytes")
    let fullTwo = pinned(direction: 1, needsFull: true, limits { $0.full = 2; $0.memory = 4 << 30 })
    #expect(fullTwo.count == 47 && fullTwo.cost == 3_489_288_960)
    #expect(fullTwo.names == "100:full 100:bytes 101:preview 99:preview 99:full 101:full 101:bytes 99:bytes 102:bytes "
            + "103:bytes 98:bytes 104:bytes 105:bytes 97:bytes 106:bytes 107:bytes 96:bytes 108:bytes 109:bytes 95:bytes "
            + "110:bytes 111:bytes 94:bytes 112:bytes 113:bytes 93:bytes 114:bytes 115:bytes 92:bytes 116:bytes "
            + "102:preview 103:preview 98:preview 104:coarse 105:coarse 97:preview 106:coarse 107:coarse 96:coarse "
            + "108:coarse 109:coarse 95:coarse 110:coarse 111:coarse 94:coarse 112:coarse 113:coarse")
}

/// On a discrete card the pyramids fill the graphics tier and the compressed files the system tier: a graphics
/// tier of two full 147 MP pyramids leaves the 24 neighbours' files (`cache-files`) all planned in 4 GiB of system
/// memory, and the pyramids planned stay within the two.
@Test func filesStayWhenPyramidsFillTheGraphicsTier() {
    let graphics = 2 * Costs(big).all
    let items = plan(focus(), limits { $0.graphicsMemory = graphics; $0.memory = 4 << 30; $0.files = 24 })
    #expect(items.filter { $0.goal == .bytes && $0.index != 100 }.count == 24)
    #expect(items.filter { $0.goal != .bytes }.reduce(0) { $0 + $1.cost } <= graphics)
    #expect(items.filter { $0.goal == .bytes }.reduce(0) { $0 + $1.cost } <= 4 << 30)
    #expect(items.contains { $0.index == 101 && $0.goal == .preview })
}

/// The current photo's full resolution is planned even when it is bigger than the whole graphics tier (a 147 MP
/// photo at 100 % on a small card): only the neighbours lose their full resolution.
@Test func currentFullExemptFromGraphicsTier() {
    let items = plan(focus(dwelling: true, needsFull: true), limits { $0.graphicsMemory = 1 << 29 })
    #expect(items.first == CacheItem(index: 100, goal: .full, cost: Costs(big).all))
    #expect(items.filter { $0.goal == .full }.map(\.index) == [100])
    // The files still go by the system tier: the 24 neighbours' fit 3 GiB.
    #expect(items.filter { $0.goal == .bytes && $0.index != 100 }.count == 24)
}
