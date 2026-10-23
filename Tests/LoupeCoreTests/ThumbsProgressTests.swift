import HomeScreenModel
import Testing
@testable import LoupeCore

/// The one progress of Home's preparation for the toolbar's pill (thumbs-ahead spec, "Пилюля в тулбаре"): the
/// current stage's count, and the pause.
@Suite struct ThumbsProgressTests {
    private static func covers(inView: WorkCount = WorkCount(), margin: WorkCount = WorkCount(),
                               ahead: WorkCount = WorkCount()) -> CoverProgress {
        CoverProgress(inView: inView, margin: margin, ahead: ahead)
    }

    @Test func textNamesTheCurrentStage() {
        let files = ThumbsProgress.join(generator: GeneratorProgress(all: WorkCount(done: 120, total: 480)),
                                        covers: Self.covers(ahead: WorkCount(done: 0, total: 48)),
                                        walk: nil, pausedByUser: false, browsing: false)
        #expect(files.stage == .thumbnails)
        #expect(files.text == "Thumbnails 120 / 480")

        let subfolders = ThumbsProgress.join(generator: GeneratorProgress(all: WorkCount(done: 480, total: 480)),
                                             covers: Self.covers(ahead: WorkCount(done: 5, total: 48)),
                                             walk: nil, pausedByUser: false, browsing: false)
        #expect(subfolders.stage == .subfolders)
        #expect(subfolders.text == "Subfolders 5 / 48")

        let paused = ThumbsProgress.join(generator: GeneratorProgress(all: WorkCount(done: 120, total: 480)), covers: Self.covers(),
                                         walk: nil, pausedByUser: true, browsing: false)
        #expect(paused.paused == .user)
        #expect(paused.text == "Paused · 120 / 480")

        let done = ThumbsProgress.join(generator: GeneratorProgress(all: WorkCount(done: 480, total: 480)),
                                       covers: Self.covers(inView: WorkCount(done: 24, total: 24),
                                                           ahead: WorkCount(done: 48, total: 48)),
                                       walk: nil, pausedByUser: false, browsing: false)
        #expect(done.stage == nil)
        #expect(done.text == nil)
    }

    /// The popover's three rows: what is in view (the cards in view and their margin, and the photos in view and the
    /// margin), the rest of the folder's photos, the subfolders; the pill's text counts all of the folder's photos.
    @Test func rowsCountEachPart() {
        let generator = GeneratorProgress(visible: WorkCount(done: 10, total: 16), all: WorkCount(done: 106, total: 232))
        let progress = ThumbsProgress.join(generator: generator,
                                           covers: Self.covers(inView: WorkCount(done: 6, total: 6),
                                                               margin: WorkCount(done: 2, total: 2),
                                                               ahead: WorkCount(done: 0, total: 48)),
                                           walk: nil, pausedByUser: false, browsing: false)
        #expect(progress.inView == WorkCount(done: 18, total: 24))
        #expect(progress.rest == WorkCount(done: 96, total: 216))
        #expect(progress.subfolders == WorkCount(done: 0, total: 48))
        #expect(progress.photos == WorkCount(done: 106, total: 232))
        #expect(progress.current == WorkCount(done: 106, total: 232))
        #expect(progress.text == "Thumbnails 106 / 232")
    }

    @Test func browsingPauseIsReported() {
        let browsing = ThumbsProgress.join(generator: GeneratorProgress(all: WorkCount(done: 3, total: 10)), covers: Self.covers(),
                                           walk: nil, pausedByUser: false, browsing: true)
        #expect(browsing.paused == .browsing)
        #expect(browsing.text == "Paused · 3 / 10")
        // The user's pause is the one named when both hold.
        let both = ThumbsProgress.join(generator: GeneratorProgress(all: WorkCount(done: 3, total: 10)), covers: Self.covers(),
                                       walk: nil, pausedByUser: true, browsing: true)
        #expect(both.paused == .user)
        let running = ThumbsProgress.join(generator: GeneratorProgress(all: WorkCount(done: 3, total: 10)), covers: Self.covers(),
                                          walk: nil, pausedByUser: false, browsing: false)
        #expect(running.paused == nil)
    }

    /// On command the walk's folders join the subfolders, the denominator growing as it lists; one that stopped early
    /// ("Too many folders") leaves no work counted.
    @Test func theWalkCountsAsSubfolders() {
        let walk = WalkProgress(folders: WorkCount(done: 12, total: 240), files: WorkCount(done: 500, total: 900))
        let progress = ThumbsProgress.join(generator: GeneratorProgress(all: WorkCount(done: 10, total: 10)), covers: Self.covers(),
                                           walk: walk, pausedByUser: false, browsing: false)
        #expect(progress.text == "Subfolders 12 / 240")

        var stopped = walk
        stopped.stopped = "Too many folders — prepared 12"
        let after = ThumbsProgress.join(generator: GeneratorProgress(all: WorkCount(done: 10, total: 10)), covers: Self.covers(),
                                        walk: stopped, pausedByUser: false, browsing: false)
        #expect(after.subfolders == WorkCount(done: 12, total: 12))
        #expect(after.text == nil)
    }
    /// The walk's own word for the popover: why it waits ("Waiting for the share"), else why it stopped early.
    @Test func theWalkSaysWhyItWaits() {
        let generator = GeneratorProgress(all: WorkCount(done: 10, total: 10))
        let waiting = ThumbsProgress.join(generator: generator, covers: Self.covers(),
                                          walk: WalkProgress(folders: WorkCount(done: 1, total: 4), waiting: "Waiting for the share"),
                                          pausedByUser: false, browsing: false)
        #expect(waiting.walkNote == "Waiting for the share")
        let stopped = ThumbsProgress.join(generator: generator, covers: Self.covers(),
                                          walk: WalkProgress(folders: WorkCount(done: 3, total: 9), stopped: "Too many folders"),
                                          pausedByUser: false, browsing: false)
        #expect(stopped.walkNote == "Too many folders")
        let none = ThumbsProgress.join(generator: generator, covers: Self.covers(), walk: nil, pausedByUser: false,
                                       browsing: false)
        #expect(none.walkNote == nil)
    }

    /// What the toolbar's pill and popover draw: the current stage's text and share, the three rows, the pause and its
    /// note (the user's, the viewer's, else the walk's word); nothing once all is done.
    @Test func stateForThePill() {
        let running = ThumbsProgress(inView: WorkCount(done: 24, total: 24), rest: WorkCount(done: 96, total: 216),
                                     photos: WorkCount(done: 120, total: 240), subfolders: WorkCount(done: 0, total: 48))
        let state = running.state
        #expect(state == ThumbsProgressState(fraction: 0.5, text: "Thumbnails 120 / 240", paused: false, rows: [
            .init(title: "In view", done: 24, total: 24), .init(title: "Rest of folder", done: 96, total: 216),
            .init(title: "Subfolders", done: 0, total: 48),
        ], pauseNote: nil, pausedByUser: false))

        var user = running
        user.paused = .user
        #expect(user.state?.paused == true)
        #expect(user.state?.pausedByUser == true)
        #expect(user.state?.pauseNote == "Paused")
        #expect(user.state?.text == "Paused · 120 / 240")

        var browsing = running
        browsing.paused = .browsing
        #expect(browsing.state?.paused == true)
        #expect(browsing.state?.pausedByUser == false)
        #expect(browsing.state?.pauseNote == "Paused while you browse")

        var walking = running
        walking.photos = WorkCount(done: 240, total: 240)
        walking.subfolders = WorkCount(done: 12, total: 48)
        walking.walkNote = "Waiting for the share"
        #expect(walking.state?.fraction == 0.25)
        #expect(walking.state?.text == "Subfolders 12 / 48")
        #expect(walking.state?.pauseNote == "Waiting for the share")
        walking.paused = .user
        #expect(walking.state?.pauseNote == "Paused")

        #expect(ThumbsProgress().state == nil)
    }
}
