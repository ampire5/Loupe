import Testing
import LoupeCore

/// A drag that starts on the current photo's cell: that photo is the scrub's origin, and every step of the drag
/// keeps it as the previous photo (it keeps its full resolution, M2 §11.1.7).
@Test func scrubFromTheCurrentCellKeepsItAsPrevious() {
    var scrub = StripScrub()
    var step: StripScrub.Step
    step = scrub.reach(5, current: 5)
    #expect(step == .none)
    #expect(!scrub.isOn)
    step = scrub.reach(6, current: 5)
    #expect(step == .move(previous: 5))
    #expect(scrub.isOn)
    step = scrub.reach(7, current: 6)
    #expect(step == .move(previous: 5))
    step = scrub.reach(9, current: 7)
    #expect(step == .move(previous: 5))
}

/// A press on another cell starts at the photo shown; passing over files never makes them the previous one.
@Test func scrubFromAnotherCellKeepsTheStartAsPrevious() {
    var scrub = StripScrub()
    var step: StripScrub.Step
    step = scrub.reach(20, current: 3)
    #expect(step == .move(previous: 3))
    step = scrub.reach(21, current: 20)
    #expect(step == .move(previous: 3))
    let ended = scrub.end()
    #expect(ended)
    #expect(!scrub.isOn)
    // After a rest ended it, the next file scrubs again from the photo rested on.
    step = scrub.reach(22, current: 21)
    #expect(step == .move(previous: 21))
}

/// A click on the current cell is nothing: no scrub to end, so no focus, seed or dwell reset follows.
@Test func clickOnTheCurrentCellIsANoOp() {
    var scrub = StripScrub()
    let step = scrub.reach(4, current: 4)
    #expect(step == .none)
    let ended = scrub.end()
    #expect(!ended)
}

/// A scrub back onto the file already current (a re-read moved the list under it) stays where it is.
@Test func scrubOntoTheCurrentFileStays() {
    var scrub = StripScrub()
    var step = scrub.reach(8, current: 2)
    #expect(step == .move(previous: 2))
    step = scrub.reach(8, current: 8)
    #expect(step == .stay)
    #expect(scrub.isOn)
}
