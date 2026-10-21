import Testing
import LoupeCore

// A hundred files at 68 pt in 1200 pt: narrow 9:16 cells (38.25 pt) and a 1.904 pt gap, 40.154 pt a file.
private let strip = StripScrollLayout(fileCount: 100, width: 1200, cellHeight: 68, maxAspect: 1.5, aspects: [])
private let pitch = strip.cellWidth + strip.gap

private func step(_ scroll: inout StripScroll, _ dx: Double, _ dy: Double = 0, phase: ScrollPhase = .changed,
                  momentum: ScrollPhase = [], layout: StripScrollLayout = strip, current: Int,
                  now: Double = 0) -> StripScroll.Outcome {
    scroll.event(fingerDX: dx, dy: dy, phase: phase, momentum: momentum, layout: layout, current: current, now: now)
}

private func near(_ a: Double?, _ b: Double, _ tolerance: Double = 0.5) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

/// Fingers moving left take the strip, and so the centre, to the next files, a file's pitch of travel per file
/// (the strip is content that follows the fingers); each file is reported once, as it reaches the centre.
@Test func fingersLeftMoveToNextFiles() {
    var scroll = StripScroll()
    #expect(scroll.offset == nil && !scroll.isMoving)
    #expect(step(&scroll, -pitch, phase: .began, current: 10).file == 11)
    #expect(scroll.isMoving)
    #expect(step(&scroll, -pitch, current: 11).file == 12)
    #expect(step(&scroll, -pitch, current: 12).file == 13)
    #expect(near(scroll.offset, strip.centre(of: 10) + 3 * pitch))
    // Less than half a pitch more: still 13, the strip moved.
    #expect(step(&scroll, -0.3 * pitch, current: 13).file == nil)
    #expect(near(scroll.offset, strip.centre(of: 10) + 3.3 * pitch))
}

@Test func reversedDirection() {
    var scroll = StripScroll()
    scroll.direction = .reversed
    #expect(step(&scroll, -pitch, phase: .began, current: 10).file == 9)
    #expect(step(&scroll, -pitch, current: 9).file == 8)
    #expect(step(&scroll, -pitch, current: 8).file == 7)
}

/// A mouse drag carries the strip with the cursor: dragging left by two files brings file 12 to the centre.
@Test func mouseDragFollowsCursor() {
    var scroll = StripScroll()
    #expect(scroll.drag(by: -2 * pitch, layout: strip, current: 10).file == 12)
    #expect(near(scroll.offset, strip.centre(of: 12)))
    #expect(scroll.isMoving)
    #expect(scroll.drag(by: pitch, layout: strip, current: 12).file == 11)
}

/// Past the first or last file a trackpad pulls the strip on at 0.3 of the travel and settles back on the end.
@Test func trackpadRubberBandsAtEnds() throws {
    var scroll = StripScroll()
    #expect(step(&scroll, 10 * pitch, phase: .began, current: 2).file == 0)
    // Two files to the first, eight beyond it at 0.3.
    #expect(near(scroll.offset, strip.centre(of: 0) - 0.3 * 8 * pitch))
    let settled = try #require(scroll.settled(layout: strip))
    #expect(settled.file == 0 && settled.offset == strip.centre(of: 0))
    var end = StripScroll()
    _ = step(&end, -4 * pitch, phase: .began, current: 98)
    #expect(near(end.offset, strip.centre(of: 99) + 0.3 * 3 * pitch))
    #expect(end.settled(layout: strip)?.file == 99)
}

@Test func mouseStopsAtEnds() throws {
    var scroll = StripScroll()
    _ = scroll.drag(by: 10 * pitch, layout: strip, current: 2)
    #expect(scroll.offset == strip.centre(of: 0))
    #expect(scroll.drag(by: -pitch, layout: strip, current: 0).file == 1)   // turning back moves at once
    let settled = try #require(scroll.settled(layout: strip))
    #expect(settled.file == 1)
}

@Test func settlesOnNearest() throws {
    var scroll = StripScroll()
    _ = scroll.drag(by: -(strip.centre(of: 20) - strip.centre(of: 10) + 0.4 * pitch), layout: strip, current: 10)
    let settled = try #require(scroll.settled(layout: strip))
    #expect(settled.file == 20 && settled.offset == strip.centre(of: 20))
    scroll.settle()
    #expect(scroll.offset == nil && !scroll.isMoving && scroll.settled(layout: strip) == nil)
}

/// Momentum after the fingers lift carries the strip on, like a flick; its end commits. The fingers' own end
/// does not: momentum may still follow, and the controller's rest timer commits when none does.
@Test func momentumEndCommits() {
    var scroll = StripScroll()
    #expect(step(&scroll, -pitch, phase: .began, current: 10) == .init(file: 11, commit: false))
    #expect(step(&scroll, -1, phase: .ended, current: 11) == .init(file: nil, commit: false))
    #expect(step(&scroll, -pitch, phase: [], momentum: .began, current: 11) == .init(file: 12, commit: false))
    #expect(step(&scroll, -pitch, phase: [], momentum: .changed, current: 12) == .init(file: 13, commit: false))
    #expect(step(&scroll, 0, phase: [], momentum: .ended, current: 13) == .init(file: nil, commit: true))
    #expect(!scroll.isMoving && !scroll.isScrubbing && scroll.restDeadline == nil)
    #expect(scroll.settled(layout: strip)?.file == 13)
    #expect(!step(&scroll, 0, phase: [], momentum: .ended, current: 13).commit)
}

@Test func cancelledCommits() {
    var scroll = StripScroll()
    #expect(step(&scroll, -pitch, phase: .began, current: 10).file == 11)
    #expect(step(&scroll, 0, phase: .cancelled, current: 11).commit)
    var coast = StripScroll()
    #expect(step(&coast, -pitch, phase: .began, current: 10).file == 11)
    #expect(step(&coast, 0, phase: [], momentum: .cancelled, current: 11).commit)
    // Nothing moved: nothing to commit.
    var idle = StripScroll()
    #expect(step(&idle, 0, phase: .cancelled, current: 10) == .init(file: nil, commit: false))
}

/// Every event while the strip moves puts the rest off; the rest commits once the deadline has passed, also when
/// the strip moved by less than a file (it still has to settle), and an early wake commits nothing.
@Test func restCommitsWithoutMomentum() {
    var scroll = StripScroll()
    #expect(step(&scroll, -pitch, phase: .began, current: 10, now: 1).file == 11)
    #expect(scroll.isScrubbing && scroll.restDeadline == 1 + StripScroll.restDelay)
    #expect(step(&scroll, -1, current: 11, now: 1.1).file == nil)
    #expect(scroll.restDeadline == 1.1 + StripScroll.restDelay)
    let early = scroll.rested(now: 1 + StripScroll.restDelay)
    #expect(!early && scroll.isMoving)
    let due = scroll.rested(now: 1.1 + StripScroll.restDelay)
    #expect(due && !scroll.isMoving && !scroll.isScrubbing && scroll.restDeadline == nil)
    let again = scroll.rested(now: 5)
    #expect(!again)
    var nudge = StripScroll()
    #expect(step(&nudge, -0.3 * pitch, phase: .began, current: 10, now: 1).file == nil)
    #expect(!nudge.isScrubbing && nudge.isMoving && nudge.restDeadline == 1 + StripScroll.restDelay)
    let nudged = nudge.rested(now: 2)
    #expect(nudged && nudge.settled(layout: strip)?.file == 10)
}

/// The gesture's axis is taken from its first few points of travel: a vertical swipe never moves the strip, even
/// where one of its events leans sideways; the next gesture decides afresh.
@Test func verticalIgnored() {
    var scroll = StripScroll()
    #expect(step(&scroll, -1, 20, phase: .began, current: 10).file == nil)
    #expect(step(&scroll, -200, 5, current: 10).file == nil)
    #expect(step(&scroll, -200, 0, phase: .ended, current: 10).file == nil)
    #expect(step(&scroll, 0, -100, phase: [], momentum: .began, current: 10).file == nil)
    #expect(scroll.offset == nil && !scroll.isMoving)
    #expect(step(&scroll, -pitch, 1, phase: .began, current: 10).file == 11)
}

/// Travel below the lock distance is kept, and applied once the axis is known.
@Test func axisLockedOnce() {
    var scroll = StripScroll()
    #expect(step(&scroll, 0, 0, phase: .mayBegin, current: 10).file == nil)
    #expect(step(&scroll, -2, 1, phase: .began, current: 10).file == nil)
    #expect(scroll.offset == nil)
    #expect(step(&scroll, -(pitch - 2), 0, current: 10).file == 11)
    #expect(near(scroll.offset, strip.centre(of: 11)))
    // Once horizontal, a vertical lean does not unlock it.
    #expect(step(&scroll, -pitch, 30, current: 11).file == 12)
}

/// Devices without phases: each event is classified by itself.
@Test func unphasedEventsAreClassifiedOneByOne() {
    var scroll = StripScroll()
    #expect(step(&scroll, -pitch, 0, phase: [], current: 10).file == 11)
    #expect(step(&scroll, -100, 200, phase: [], current: 11).file == nil)
    #expect(step(&scroll, -pitch, 2, phase: [], current: 11).file == 12)
}

/// The current photo moved without the strip (a key, the wheel): the next event starts from it.
@Test func anotherCurrentPhotoReanchors() {
    var scroll = StripScroll()
    #expect(step(&scroll, -pitch, phase: .began, current: 10).file == 11)
    #expect(step(&scroll, -pitch, current: 40).file == 41)
    #expect(near(scroll.offset, strip.centre(of: 41)))
}

/// A press during the momentum or the settling takes over: the rest of that momentum does nothing, the scroll
/// has nothing to commit; the next gesture moves the strip again.
@Test func pressDuringMomentumTakesOver() {
    var scroll = StripScroll()
    #expect(step(&scroll, -pitch, phase: .began, current: 10, now: 1).file == 11)
    #expect(step(&scroll, -pitch, phase: [], momentum: .began, current: 11, now: 1.1).file == 12)
    scroll.takeOver()
    #expect(!scroll.isMoving && !scroll.isScrubbing && scroll.restDeadline == nil)
    #expect(step(&scroll, -pitch, phase: [], momentum: .changed, current: 12, now: 1.2) == .init(file: nil, commit: false))
    #expect(step(&scroll, 0, phase: [], momentum: .ended, current: 12, now: 1.3) == .init(file: nil, commit: false))
    let rested = scroll.rested(now: 9), ended = scroll.end()
    #expect(!rested && !ended)
    scroll.settle()
    #expect(step(&scroll, -pitch, phase: .began, current: 30, now: 10).file == 31)
}

/// `end()` (window resigns key, full screen) commits a scrub that is on, once.
@Test func endCommitsOnce() {
    var scroll = StripScroll()
    #expect(step(&scroll, -pitch, phase: .began, current: 10).file == 11)
    let ended = scroll.end(), endedAgain = scroll.end()
    #expect(ended && !endedAgain && !scroll.isMoving)
}

/// The folder grew (or its aspects or the width changed) while the strip moves: the file at the centre stays.
@Test func fileCountChangeMidGestureKeepsFile() {
    var scroll = StripScroll()
    #expect(step(&scroll, -pitch, phase: .began, current: 10).file == 11)
    let grown = StripScrollLayout(fileCount: 150, width: 1200, cellHeight: 68, maxAspect: 1.5, aspects: [])
    scroll.layoutChanged(keeping: 11, layout: grown)
    #expect(scroll.offset == grown.centre(of: 11))
    #expect(step(&scroll, -(grown.cellWidth + grown.gap), layout: grown, current: 11).file == 12)
    var idle = StripScroll()
    idle.layoutChanged(keeping: 11, layout: grown)
    #expect(idle.offset == nil)
}

@Test func singleFileGestureDoesNothing() {
    let one = StripScrollLayout(fileCount: 1, width: 1200, cellHeight: 68, maxAspect: 1.5, aspects: [])
    var scroll = StripScroll()
    #expect(step(&scroll, -500, phase: .began, layout: one, current: 0) == .init(file: nil, commit: false))
    #expect(scroll.drag(by: -500, layout: one, current: 0).file == nil)
    #expect(scroll.offset == nil && !scroll.isMoving)
    let empty = StripScrollLayout(fileCount: 0, width: 1200, cellHeight: 68, maxAspect: 1.5, aspects: [])
    #expect(step(&scroll, -500, phase: .began, layout: empty, current: 0).file == nil)
    #expect(scroll.settled(layout: empty) == nil)
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

/// The controller's sequence, in the model: a gesture across five files scrubs each once, in order, and its
/// momentum's end commits once.
@Test func gestureScrubsEachFileOnceAndCommitsOnce() {
    var scroll = StripScroll()
    var current = 10, files: [Int] = [], commits = 0
    let events: [(Double, ScrollPhase, ScrollPhase)] = [(-0.5 * pitch, .began, [])]
        + Array(repeating: (-0.25 * pitch, .changed, []), count: 8)
        + [(0, .ended, [])]
        + Array(repeating: (-0.25 * pitch, [], .changed), count: 10)
        + [(0, [], .ended)]
    for (dx, phase, momentum) in events {
        let outcome = step(&scroll, dx, phase: phase, momentum: momentum, current: current)
        if let file = outcome.file {
            files.append(file)
            current = file
        }
        if outcome.commit { commits += 1 }
    }
    #expect(files == Array(11...15))
    #expect(commits == 1)
}
