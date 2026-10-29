import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

// Smart zoom stage 2 review: the finder's queue is bounded, drops what a step left behind, never runs two jobs, and
// does not start while the photo on screen is decoding (no polling: freeing the foreground takes the next job).

private struct J: SubjectJob {
    let url: URL
    var asks = 1
    mutating func merge(_ other: J) { asks += other.asks }
}
private func u(_ n: Int) -> URL { URL(fileURLWithPath: "/p/\(n).jpg") }

@Test func queueTakesTheCurrentFirstThenAhead() {
    var q = SubjectQueue<J>(aheadLimit: 2)
    q.ask(J(url: u(2)), ahead: true)
    q.ask(J(url: u(1)), ahead: false)
    #expect(q.take()?.url == u(1))
    #expect(q.take() == nil)                 // one at a time
    q.finish()
    #expect(q.take()?.url == u(2))
}

@Test func queueWaitsForTheForeground() {
    var q = SubjectQueue<J>(aheadLimit: 2)
    q.busy = true
    q.ask(J(url: u(1)), ahead: false)
    #expect(q.take() == nil)
    q.busy = false
    #expect(q.take()?.url == u(1))
}

@Test func queueKeepsTheNearestAheadAndDropsWhatIsLeft() {
    var q = SubjectQueue<J>(aheadLimit: 2)
    for n in [2, 3, 4] { q.ask(J(url: u(n)), ahead: true) }
    #expect(q.pending.map(\.url) == [u(2), u(3)])          // the farther one is not queued past the limit
    q.ask(J(url: u(1)), ahead: false)
    q.keepOnly([u(3)])
    #expect(q.pending.map(\.url) == [u(3)])
    q.ask(J(url: u(3)), ahead: true)
    #expect(q.pending.count == 1)                            // asked twice, queued once
}

@Test func glideOnlyWhileTheViewIsTheOneThePhotoCameWith() {
    let came = ViewTransform(imageSize: CGSize(width: 100, height: 200), viewSize: CGSize(width: 400, height: 300))
    var finer = came
    finer.imageSize = CGSize(width: 1000, height: 2000)       // a finer level laid out: still untouched
    #expect(SubjectGlide.shouldGlide(shownAt: 0, now: 0.2, cameWith: came, now: finer, samePhoto: true))
    #expect(!SubjectGlide.shouldGlide(shownAt: 0, now: 0.2, cameWith: came, now: came.withMode(.actual(1)), samePhoto: true))
    var panned = came
    panned.center = CGPoint(x: 0.4, y: 0.5)
    #expect(!SubjectGlide.shouldGlide(shownAt: 0, now: 0.2, cameWith: came, now: panned, samePhoto: true))
    #expect(!SubjectGlide.shouldGlide(shownAt: 0, now: 0.35, cameWith: came, now: came, samePhoto: true))
    #expect(!SubjectGlide.shouldGlide(shownAt: 0, now: 0.1, cameWith: came, now: came, samePhoto: false))
}

@Test func queueMergesASecondAskForTheSamePhoto() {
    var q = SubjectQueue<J>(aheadLimit: 2)
    q.ask(J(url: u(1)), ahead: false)
    q.ask(J(url: u(1)), ahead: false)                       // ⇧Z while the step's own ask waits: one job, both answered
    #expect(q.pending.count == 1 && q.pending[0].asks == 2)
    q.ask(J(url: u(2)), ahead: true)
    q.ask(J(url: u(2)), ahead: false)                       // a photo ahead becomes the one on screen, keeping its asks
    #expect(q.pending.map(\.url) == [u(2)] && q.pending[0].asks == 2)
}
