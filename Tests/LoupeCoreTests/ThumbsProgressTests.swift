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
        // What is in view comes first: the pill names it while some of it is still to be made.
        #expect(progress.current == WorkCount(done: 18, total: 24))
        #expect(progress.text == "In view 18 / 24")
    }

    /// The covers of the cards in view and the margin are work (stages 1–2): with nothing else to do the pill is lit
    /// and names them, its ring their share.
    @Test func stateWhileCoversInViewArePending() throws {
        let progress = ThumbsProgress.join(generator: GeneratorProgress(all: WorkCount(done: 10, total: 10)),
                                           covers: Self.covers(inView: WorkCount(done: 2, total: 6),
                                                               margin: WorkCount(done: 0, total: 2)),
                                           walk: nil, pausedByUser: false, browsing: false)
        #expect(progress.stage == .inView)
        #expect(progress.text == "In view 2 / 8")
        let state = try #require(progress.state)
        #expect(state.working)
        #expect(state.fraction == 0.25)
        #expect(state.text == "In view 2 / 8")
        var paused = progress
        paused.paused = .user
        #expect(paused.text == "Paused · 2 / 8")
    }

    /// The stages in their order: what is in view, then the folder's photos, then the subfolders.
    @Test func inViewStageComesFirst() {
        func stage(inView: WorkCount, photos: WorkCount, ahead: WorkCount) -> ThumbsProgress {
            ThumbsProgress.join(generator: GeneratorProgress(visible: WorkCount(done: inView.done, total: inView.total),
                                                             all: photos),
                                covers: Self.covers(ahead: ahead), walk: nil, pausedByUser: false, browsing: false)
        }
        let all = stage(inView: WorkCount(done: 1, total: 4), photos: WorkCount(done: 1, total: 40),
                        ahead: WorkCount(done: 0, total: 9))
        #expect(all.stage == .inView)
        #expect(all.text == "In view 1 / 4")
        let photos = stage(inView: WorkCount(done: 4, total: 4), photos: WorkCount(done: 4, total: 40),
                           ahead: WorkCount(done: 0, total: 9))
        #expect(photos.stage == .thumbnails)
        #expect(photos.text == "Thumbnails 4 / 40")
        let subfolders = stage(inView: WorkCount(done: 4, total: 4), photos: WorkCount(done: 40, total: 40),
                               ahead: WorkCount(done: 3, total: 9))
        #expect(subfolders.stage == .subfolders)
        #expect(subfolders.text == "Subfolders 3 / 9")
    }

    /// On a share the listing comes names only first: the generator has no stamped photo yet (its counts are zeros),
    /// but the photos in view are waiting to be made, so they count in view and the state is working.
    @Test func visiblePhotosOfANamesOnlyListingCountInView() throws {
        let progress = ThumbsProgress.join(generator: GeneratorProgress(), covers: Self.covers(), walk: nil,
                                           pausedByUser: false, browsing: false, unlistedInView: 6)
        #expect(progress.inView == WorkCount(done: 0, total: 6))
        #expect(progress.stage == .inView)
        #expect(progress.text == "In view 0 / 6")
        #expect(try #require(progress.state).working)
        let none = ThumbsProgress.join(generator: GeneratorProgress(), covers: Self.covers(), walk: nil,
                                       pausedByUser: false, browsing: false)
        #expect(none.state == nil)
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

    /// The popover's state is there whether or not anything is being prepared (View › Thumbnails… for any folder):
    /// done, it has the counts and says it is not working, so the pill stays out; with nothing at all, zeros.
    @Test func displayStateEvenWhenDone() {
        let done = ThumbsProgress(inView: WorkCount(done: 24, total: 24), rest: WorkCount(done: 216, total: 216),
                                  photos: WorkCount(done: 240, total: 240), subfolders: WorkCount(done: 48, total: 48))
        #expect(done.state == nil)
        let shown = done.display
        #expect(!shown.working)
        #expect(shown.rows == [.init(title: "In view", done: 24, total: 24),
                               .init(title: "Rest of folder", done: 216, total: 216),
                               .init(title: "Subfolders", done: 48, total: 48)])
        let none = ThumbsProgress().display
        #expect(!none.working)
        #expect(none.rows.map(\.total) == [0, 0, 0])
        var paused = done
        paused.paused = .user
        #expect(paused.display.pausedByUser && paused.display.pauseNote == "Paused")
        let running = ThumbsProgress(photos: WorkCount(done: 1, total: 2))
        #expect(running.display.working)
        #expect(running.display == running.state)
    }

    /// While the subtree walk runs (for this window) the popover's button stops it; once it ended, it prepares again.
    @Test func runningWalkOffersStop() {
        let generator = GeneratorProgress(all: WorkCount(done: 10, total: 10))
        var walk = WalkProgress(folders: WorkCount(done: 1, total: 4))
        walk.running = true
        let running = ThumbsProgress.join(generator: generator, covers: Self.covers(), walk: walk, pausedByUser: false,
                                          browsing: false)
        #expect(running.subtreeRunning)
        #expect(running.state?.subtreeRunning == true)
        walk.running = false
        let ended = ThumbsProgress.join(generator: generator, covers: Self.covers(), walk: walk, pausedByUser: false,
                                        browsing: false)
        #expect(!ended.subtreeRunning)
        #expect(!ended.display.subtreeRunning)
        let none = ThumbsProgress.join(generator: generator, covers: Self.covers(), walk: nil, pausedByUser: false,
                                       browsing: false)
        #expect(!none.subtreeRunning)
    }

    /// What is in view waits on a share that is offline: covers retried for good, photos that cannot be read (and the
    /// folder's other photos with them). That is no work under way: the state is not working (the pill goes out) and says it waits for the share.
    @Test func inViewWaitingForTheShareIsNotWork() throws {
        let generator = GeneratorProgress(visible: WorkCount(done: 0, total: 4), all: WorkCount(done: 0, total: 4))
        let covers = Self.covers(inView: WorkCount(done: 1, total: 6))
        let waiting = ThumbsProgress.join(generator: generator, covers: covers, walk: nil, pausedByUser: false,
                                          browsing: false, shareOffline: true)
        #expect(waiting.inView == WorkCount(done: 1, total: 10))
        #expect(waiting.state == nil)
        #expect(!waiting.display.working)
        #expect(waiting.walkNote == ThumbsWalk.waitingForShare)
        #expect(waiting.display.pauseNote == ThumbsWalk.waitingForShare)
        #expect(waiting.display.rows.first == .init(title: "In view", done: 1, total: 10))
        // The share back: the same counts are work again.
        let back = ThumbsProgress.join(generator: generator, covers: covers, walk: nil, pausedByUser: false,
                                       browsing: false)
        #expect(back.stage == .inView && back.walkNote == nil)
    }

    /// A share that drops before its complete listing: the photos in view without stamps wait for it, not counted as
    /// work, while covers in view that are still being made keep the pill.
    @Test func unlistedPhotosWaitingForTheShareAreNotWork() {
        let stalled = ThumbsProgress.join(generator: GeneratorProgress(), covers: Self.covers(), walk: nil,
                                          pausedByUser: false, browsing: false, unlistedInView: 6,
                                          unlistedWaitsForShare: true)
        #expect(stalled.inView == WorkCount(done: 0, total: 6))
        #expect(stalled.state == nil)
        #expect(stalled.display.pauseNote == ThumbsWalk.waitingForShare)
        let coversRun = ThumbsProgress.join(generator: GeneratorProgress(),
                                            covers: Self.covers(inView: WorkCount(done: 1, total: 3)), walk: nil,
                                            pausedByUser: false, browsing: false, unlistedInView: 6,
                                            unlistedWaitsForShare: true)
        #expect(coversRun.stage == .inView)
        #expect(coversRun.text == "In view 1 / 9")
    }

    /// The visible cards' subfolders waiting on a share that does not answer say so, as the walk does; the walk's own
    /// word wins, and nothing is said once the subfolders are done.
    @Test func aheadWaitingForTheShareIsSaid() {
        let generator = GeneratorProgress(all: WorkCount(done: 10, total: 10))
        let waiting = ThumbsProgress.join(generator: generator, covers: Self.covers(ahead: WorkCount(done: 0, total: 12)),
                                          walk: nil, pausedByUser: false, browsing: false, aheadWaitsForShare: true)
        #expect(waiting.walkNote == ThumbsWalk.waitingForShare)
        #expect(waiting.state?.pauseNote == ThumbsWalk.waitingForShare)
        let done = ThumbsProgress.join(generator: generator, covers: Self.covers(ahead: WorkCount(done: 12, total: 12)),
                                       walk: nil, pausedByUser: false, browsing: false, aheadWaitsForShare: true)
        #expect(done.walkNote == nil)
        let stopped = ThumbsProgress.join(generator: generator, covers: Self.covers(ahead: WorkCount(done: 0, total: 12)),
                                          walk: WalkProgress(folders: WorkCount(done: 3, total: 9), stopped: "Too many folders"),
                                          pausedByUser: false, browsing: false, aheadWaitsForShare: true)
        #expect(stopped.walkNote == "Too many folders")
    }
}
