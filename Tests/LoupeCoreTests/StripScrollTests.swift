import Testing
import LoupeCore

// Ten files, one 96 pt cell each (3:2 at 64 pt), centred in 2000 pt: the strip runs 520 ..< 1480.
private let perFile = StripLayout(fileCount: 10, width: 2000, cellHeight: 64)
// A hundred files sampled into ten 96 pt cells of ten files each over 0 ..< 960: 9.6 pt per file.
private let sampled = StripLayout(fileCount: 100, width: 960, cellHeight: 64)

private func step(_ scroll: inout StripScroll, _ dx: Double, _ dy: Double = 0, phase: ScrollPhase = .changed,
                  momentum: ScrollPhase = [], layout: StripLayout = perFile, current: Int,
                  now: Double = 0) -> StripScroll.Outcome {
    scroll.event(fingerDX: dx, dy: dy, phase: phase, momentum: momentum, layout: layout, current: current, now: now)
}

/// Fingers moving left take the selection to the next files, a cell's width of travel per cell, the way the
/// three-finger swipe goes (left = next); only a new file is reported.
@Test func fingersLeftMoveToTheNextFileByCellTravel() {
    var scroll = StripScroll()
    // From the middle of file 3's cell (x 856): 10 pt is still file 3.
    #expect(step(&scroll, -10, phase: .began, current: 3) == .init(file: nil, commit: false))
    // 60 pt more (x 916) reaches file 4.
    #expect(step(&scroll, -50, current: 3) == .init(file: 4, commit: false))
    // Still within file 4: nothing new.
    #expect(step(&scroll, -30, current: 4).file == nil)
    // A full cell more: file 5.
    #expect(step(&scroll, -96, current: 4).file == 5)
}

@Test func fingersRightMoveToThePreviousFile() {
    var scroll = StripScroll()
    #expect(step(&scroll, 60, phase: .began, current: 3).file == 2)
    #expect(step(&scroll, 96, current: 2).file == 1)
}

/// A sampled strip moves by file ranges: a cell's travel passes its ten files, one per 9.6 pt.
@Test func sampledStripMovesThroughTheCellsRange() {
    var scroll = StripScroll()
    // File 45: cell 4 (40 ..< 50, x 384 ..< 480), its slot centre at 436.8.
    #expect(step(&scroll, -10, phase: .began, layout: sampled, current: 45).file == 46)
    #expect(step(&scroll, -86, layout: sampled, current: 46).file == 55)
}

/// The gesture's axis is taken from its first few points of travel: a vertical swipe never scrubs, even where
/// one of its events leans sideways; the next gesture decides afresh.
@Test func verticalGestureIsIgnoredThroughout() {
    var scroll = StripScroll()
    #expect(step(&scroll, -1, 20, phase: .began, current: 3).file == nil)
    #expect(step(&scroll, -200, 5, current: 3).file == nil)
    #expect(step(&scroll, -200, 0, phase: .ended, current: 3).file == nil)
    #expect(step(&scroll, 0, -100, phase: [], momentum: .began, current: 3).file == nil)
    // A new horizontal gesture scrubs.
    #expect(step(&scroll, -60, 1, phase: .began, current: 3).file == 4)
}

/// Travel below the lock distance is kept, and applied once the axis is known.
@Test func travelBeforeTheAxisLockCounts() {
    var scroll = StripScroll()
    #expect(step(&scroll, 0, 0, phase: .mayBegin, current: 3).file == nil)
    #expect(step(&scroll, -2, 1, phase: .began, current: 3).file == nil)
    // Locked horizontal now, with all 58 pt so far applied (x 914): file 4.
    #expect(step(&scroll, -56, 0, current: 3).file == 4)
}

/// Like a scroll bar's thumb, the selection stops at the ends, and turning back moves it at once rather than
/// after unwinding the travel past the end.
@Test func endsHoldAndTurningBackMovesAtOnce() {
    var scroll = StripScroll()
    #expect(step(&scroll, -500, phase: .began, current: 9).file == nil)   // file 9 is the last
    #expect(step(&scroll, 100, current: 9).file == 8)
    var back = StripScroll()
    #expect(step(&back, 500, phase: .began, current: 0).file == nil)
    #expect(step(&back, -100, current: 0).file == 1)
}

/// Momentum after the fingers lift carries the scrub on, like a flick; its end commits. The fingers' own end
/// does not: momentum may still follow, and the controller's rest timer commits when none does.
@Test func momentumScrubsOnAndItsEndCommits() {
    var scroll = StripScroll()
    #expect(step(&scroll, -60, phase: .began, current: 3) == .init(file: 4, commit: false))
    #expect(step(&scroll, -10, phase: .ended, current: 4) == .init(file: nil, commit: false))
    #expect(step(&scroll, -96, phase: [], momentum: .began, current: 4) == .init(file: 5, commit: false))
    #expect(step(&scroll, -96, phase: [], momentum: .changed, current: 5) == .init(file: 6, commit: false))
    #expect(step(&scroll, 0, phase: [], momentum: .ended, current: 6) == .init(file: nil, commit: true))
}

@Test func cancelledCommits() {
    var scroll = StripScroll()
    #expect(step(&scroll, -60, phase: .began, current: 3).file == 4)
    #expect(step(&scroll, 0, phase: .cancelled, current: 4).commit)
    var coast = StripScroll()
    #expect(step(&coast, -60, phase: .began, current: 3).file == 4)
    #expect(step(&coast, 0, phase: [], momentum: .cancelled, current: 4).commit)
}

/// The current photo moved without the scroll (a key, a click): the next event starts from it.
@Test func anotherCurrentPhotoReanchors() {
    var scroll = StripScroll()
    #expect(step(&scroll, -60, phase: .began, current: 3).file == 4)
    #expect(step(&scroll, -60, current: 7).file == 8)   // from 7's centre (1240) to 1300
}

/// A new layout (new aspects, a resize) puts the selection back on the current file's centre.
@Test func newLayoutReanchors() {
    var scroll = StripScroll()
    #expect(step(&scroll, -40, phase: .began, current: 3).file == nil)   // 40 pt into file 3, 8 short of file 4
    scroll.layoutChanged()
    #expect(step(&scroll, -40, current: 3).file == nil)   // from the centre again: still file 3
    #expect(step(&scroll, -10, current: 3).file == 4)
}

/// Devices without phases: each event is classified by itself.
@Test func unphasedEventsAreClassifiedOneByOne() {
    var scroll = StripScroll()
    #expect(step(&scroll, -60, 0, phase: [], current: 3).file == 4)
    #expect(step(&scroll, -100, 200, phase: [], current: 4).file == nil)
    #expect(step(&scroll, -96, 2, phase: [], current: 4).file == 5)
}

@Test func noCellsNoScrub() {
    var scroll = StripScroll()
    let empty = StripLayout(fileCount: 0, width: 1000, cellHeight: 64)
    #expect(step(&scroll, -200, phase: .began, layout: empty, current: 0).file == nil)
}

/// Which scroll the strip takes: precise scrolling with no folder-gesture button held. A notched wheel steps photos
/// as everywhere, a held button is the folder gesture's (unless the strip's own press holds it), and precise
/// scrolling during the strip's own press does nothing.
@Test func scrollRoutes() {
    #expect(StripScroll.route(precise: false, held: [], folderGesture: true, pressed: false, spent: false) == .viewer)
    #expect(StripScroll.route(precise: false, held: .right, folderGesture: true, pressed: false, spent: false) == .viewer)
    #expect(StripScroll.route(precise: false, held: [], folderGesture: true, pressed: true, spent: false) == .viewer)
    #expect(StripScroll.route(precise: true, held: [], folderGesture: true, pressed: false, spent: false) == .strip)
    #expect(StripScroll.route(precise: true, held: .left, folderGesture: true, pressed: false, spent: false) == .viewer)
    #expect(StripScroll.route(precise: true, held: .right, folderGesture: true, pressed: false, spent: false) == .viewer)
    #expect(StripScroll.route(precise: true, held: .left, folderGesture: false, pressed: false, spent: false) == .strip)
    #expect(StripScroll.route(precise: true, held: .left, folderGesture: true, pressed: true, spent: false) == .ignore)
    #expect(StripScroll.route(precise: true, held: [], folderGesture: true, pressed: true, spent: false) == .ignore)
}

/// The rest of a gesture the viewer's guard has spent (a folder step fired and the click was let go while the
/// fingers swipe or coast on, a three-finger swipe) must not scrub the new folder. The guard is asked only for the
/// strip's own scroll: asking feeds it, and the wheel, a held button and a press go elsewhere first.
@Test func spentGestureIsIgnored() {
    #expect(StripScroll.route(precise: true, held: [], folderGesture: true, pressed: false, spent: true) == .ignore)
    #expect(StripScroll.route(precise: true, held: .left, folderGesture: false, pressed: false, spent: true) == .ignore)
    var asked = 0
    func spent() -> Bool {
        asked += 1
        return true
    }
    _ = StripScroll.route(precise: false, held: [], folderGesture: true, pressed: false, spent: spent())
    _ = StripScroll.route(precise: true, held: .left, folderGesture: true, pressed: false, spent: spent())
    _ = StripScroll.route(precise: true, held: [], folderGesture: true, pressed: true, spent: spent())
    #expect(asked == 0)
    _ = StripScroll.route(precise: true, held: [], folderGesture: true, pressed: false, spent: spent())
    #expect(asked == 1)
}

/// `strip-scroll-direction=reversed`: fingers left take the selection to the previous files, with them.
@Test func reversedDirectionFollowsTheFingers() {
    var scroll = StripScroll()
    scroll.direction = .reversed
    #expect(step(&scroll, -60, phase: .began, current: 3).file == 2)
    #expect(step(&scroll, 96, current: 2).file == 3)
}

/// The scrub is on from the first new file to its commit; only then is there a rest to wait for or a commit to make.
@Test func scrubIsOnFromTheFirstNewFileToTheCommit() {
    var scroll = StripScroll()
    #expect(step(&scroll, -10, phase: .began, current: 3, now: 1) == .init(file: nil, commit: false))
    #expect(!scroll.isScrubbing && scroll.restDeadline == nil)
    #expect(step(&scroll, -50, current: 3, now: 1.01).file == 4)
    #expect(scroll.isScrubbing && scroll.restDeadline == 1.01 + StripScroll.restDelay)
    // A cancel without a scrub on commits nothing.
    var idle = StripScroll()
    #expect(step(&idle, 0, phase: .cancelled, current: 3) == .init(file: nil, commit: false))
}

/// Every event while the scrub is on puts the rest off; the rest commits once the deadline has passed, and a wake
/// before it (the timer was armed for an earlier deadline) commits nothing.
@Test func restCommitsAfterTheLastEvent() {
    var scroll = StripScroll()
    #expect(step(&scroll, -60, phase: .began, current: 3, now: 1).file == 4)
    #expect(step(&scroll, -10, current: 4, now: 1.1).file == nil)
    #expect(scroll.restDeadline == 1.1 + StripScroll.restDelay)
    let early = scroll.rested(now: 1 + StripScroll.restDelay)
    #expect(!early && scroll.isScrubbing)
    let due = scroll.rested(now: 1.1 + StripScroll.restDelay)
    #expect(due && !scroll.isScrubbing && scroll.restDeadline == nil)
    let again = scroll.rested(now: 5)   // once
    #expect(!again)
    // The fingers move on after the rest: a new scrub from the photo rested on.
    #expect(step(&scroll, -96, current: 4, now: 6).file == 5)
    #expect(scroll.isScrubbing)
}

/// The momentum's end commits at once, once.
@Test func commitEndsTheScrub() {
    var scroll = StripScroll()
    #expect(step(&scroll, -60, phase: .began, current: 3).file == 4)
    #expect(step(&scroll, 0, phase: [], momentum: .ended, current: 4).commit)
    #expect(!scroll.isScrubbing && scroll.restDeadline == nil)
    #expect(!step(&scroll, 0, phase: [], momentum: .ended, current: 4).commit)
}

/// A press on the cells takes the scrub over (the session's scrub goes on under the press, whose release commits):
/// no rest and no commit of the scroll's own afterwards. `end()` (window resigns key, full screen) commits once.
@Test func pressTakesOverAndEndCommitsOnce() {
    var scroll = StripScroll()
    #expect(step(&scroll, -60, phase: .began, current: 3, now: 1).file == 4)
    scroll.takeOver()
    let rested = scroll.rested(now: 9), endedAfterTakeOver = scroll.end()
    #expect(!scroll.isScrubbing && scroll.restDeadline == nil && !rested && !endedAfterTakeOver)
    #expect(step(&scroll, -96, phase: .began, current: 7, now: 10).file == 8)
    let ended = scroll.end(), endedAgain = scroll.end()
    #expect(ended && !endedAgain)
}
