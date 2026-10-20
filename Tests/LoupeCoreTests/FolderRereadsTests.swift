import Foundation
import Testing
@testable import LoupeCore

private let a = URL(fileURLWithPath: "/x/a", isDirectory: true)
private let b = URL(fileURLWithPath: "/x/b", isDirectory: true)
private let t0 = ContinuousClock.now

@Test func firstRequestStartsAtOnceAndAnotherJoins() {
    var r = FolderRereads<Int>()
    do { let v = r.request(.event, folder: a, now: t0); #expect(v == .start) }
    do { let v = r.request(.idle, folder: a, now: t0); #expect(v == .none) }
    do { let v = r.request(.open, folder: a, now: t0); #expect(v == .none) }
    #expect(r.isListing(a))
    let done = r.finish(a, took: .milliseconds(1), now: t0, outcome: .applied)
    #expect(done.waiters.isEmpty && done.next == .none && !r.isListing(a))
}

@Test func eventDuringAListingQueuesOneMore() {
    var r = FolderRereads<Int>()
    _ = r.request(.idle, folder: a, now: t0)
    do { let v = r.request(.event, folder: a, now: t0); #expect(v == .none) }
    do { let v = r.request(.event, folder: a, now: t0); #expect(v == .none) }   // folded into the same one
    let done = r.finish(a, took: .milliseconds(1), now: t0 + .seconds(1), outcome: .applied)
    #expect(done.next == .startAfter(.milliseconds(10)))   // ten listings after this one ended
    #expect(r.isListing(a))
    do { let v = r.begin(a, isCurrent: true); #expect(v) }
    do { let v = r.finish(a, took: .milliseconds(1), now: t0 + .seconds(2), outcome: .applied); #expect(v.next == .none) }
}

@Test func pollOrActivationDuringAListingAddsNothing() {
    var r = FolderRereads<Int>()
    _ = r.request(.event, folder: a, now: t0)
    _ = r.request(.idle, folder: a, now: t0)
    do { let v = r.finish(a, took: .milliseconds(1), now: t0, outcome: .applied); #expect(v.next == .none) }
}

@Test func stepIsAnsweredByTheNextListingToFinish() {   // never by one queued just for it, ten listings on
    var r = FolderRereads<Int>()
    do { let v = r.request(.step(1), folder: a, now: t0); #expect(v == .start) }
    do { let v = r.request(.step(2), folder: a, now: t0); #expect(v == .none) }
    let first = r.finish(a, took: .seconds(1), now: t0 + .seconds(1), outcome: .applied)
    #expect(first.waiters == [1, 2] && first.next == .none && !r.isListing(a))
}

@Test func lateStepsOnARunningListingOpenJoinedFireWithIt() {   // open joins a listing already out
    var r = FolderRereads<Int>()
    _ = r.request(.event, folder: a, now: t0)                                        // a slow listing is out
    do { let v = r.request(.open, folder: a, now: t0); #expect(v == .none) }
    do { let v = r.request(.step(1), folder: a, now: t0); #expect(v == .none) }      // interim one-file playlist
    do { let v = r.request(.step(2), folder: a, now: t0); #expect(v == .none) }
    let done = r.finish(a, took: .seconds(1), now: t0 + .seconds(1), outcome: .applied)
    #expect(done.waiters == [1, 2] && done.next == .none)                            // no queued listing for them
}

@Test func stepDuringOpensListingJoinsIt() {   // the interim one-file playlist ends at every step
    var r = FolderRereads<Int>()
    do { let v = r.request(.open, folder: a, now: t0); #expect(v == .start) }
    do { let v = r.request(.step(1), folder: a, now: t0); #expect(v == .none) }
    do { let v = r.request(.step(2), folder: a, now: t0); #expect(v == .none) }
    let done = r.finish(a, took: .milliseconds(1), now: t0, outcome: .applied)
    #expect(done.waiters == [1, 2] && done.next == .none)
}

@Test func reReadsKeepTenListingsApart() {   // a slow share: the same rule as the poll
    var r = FolderRereads<Int>()
    _ = r.request(.event, folder: a, now: t0)
    let ended = t0 + .milliseconds(500)
    _ = r.finish(a, took: .milliseconds(500), now: ended, outcome: .applied)
    do { let v = r.request(.event, folder: a, now: ended + .seconds(1)); #expect(v == .startAfter(.seconds(4))) }
    // Queued, not running: later events and steps join it.
    do { let v = r.request(.event, folder: a, now: ended + .seconds(2)); #expect(v == .none) }
    do { let v = r.request(.step(7), folder: a, now: ended + .seconds(2)); #expect(v == .none) }
    do { let v = r.begin(a, isCurrent: true); #expect(v) }
    do { let v = r.begin(a, isCurrent: true); #expect(!v) }   // once
    let done = r.finish(a, took: .milliseconds(500), now: ended + .seconds(6), outcome: .applied)
    #expect(done.waiters == [7] && done.next == .none)
    // Opening a file starts at once, gap or not; a queued listing too, and its pending begin then does nothing.
    do { let v = r.request(.open, folder: a, now: ended + .seconds(6)); #expect(v == .start) }
    _ = r.finish(a, took: .milliseconds(500), now: ended + .seconds(7), outcome: .applied)
    do { let v = r.request(.step(8), folder: a, now: ended + .seconds(7)); #expect(v == .startAfter(.seconds(5))) }
    do { let v = r.request(.open, folder: a, now: ended + .seconds(8)); #expect(v == .start) }
    do { let v = r.begin(a, isCurrent: true); #expect(!v) }
    let opened = r.finish(a, took: .milliseconds(500), now: ended + .seconds(9), outcome: .applied)
    #expect(opened.waiters == [8] && opened.next == .none)
    // Another folder has no gap.
    do { let v = r.request(.event, folder: b, now: ended + .seconds(6)); #expect(v == .start) }
    // Past the gap: at once.
    var s = FolderRereads<Int>()
    _ = s.request(.event, folder: a, now: t0)
    _ = s.finish(a, took: .milliseconds(500), now: t0, outcome: .applied)
    do { let v = s.request(.step(1), folder: a, now: t0 + .seconds(5)); #expect(v == .start) }
}

@Test func queuedListingOfALeftFolderIsDropped() {
    var r = FolderRereads<Int>()
    _ = r.request(.event, folder: a, now: t0)
    _ = r.finish(a, took: .seconds(1), now: t0, outcome: .applied)
    do { let v = r.request(.step(1), folder: a, now: t0); #expect(v == .startAfter(.seconds(10))) }
    do { let v = r.begin(a, isCurrent: false); #expect(!v) }
    #expect(!r.isListing(a))
}

@Test func returnToAFolderWhoseListingHangsWaitsForIt() {   // never two listings of one folder at once
    var r = FolderRereads<Int>()
    do { let v = r.request(.open, folder: a, now: t0); #expect(v == .start) }          // a hangs
    do { let v = r.request(.open, folder: b, now: t0); #expect(v == .start) }          // the user moved to b
    _ = r.finish(b, took: .milliseconds(1), now: t0, outcome: .applied)
    do { let v = r.request(.event, folder: a, now: t0); #expect(v == .none) }          // back to a: no second listing of a
    let done = r.finish(a, took: .seconds(1), now: t0 + .seconds(30), outcome: .applied)
    #expect(done.next == .startAfter(.seconds(10)))                  // the event's own listing follows, ten listings on
}

@Test func droppedListingDropsItsWaiters() {
    var r = FolderRereads<Int>()
    _ = r.request(.step(1), folder: a, now: t0)
    _ = r.request(.event, folder: a, now: t0)
    _ = r.request(.step(2), folder: a, now: t0)
    let done = r.finish(a, took: .milliseconds(1), now: t0, outcome: .dropped)
    #expect(done.waiters.isEmpty && done.next == .none && !r.isListing(a))
}

@Test func rerunCarriesAllWaitersToTheNextListing() {
    var r = FolderRereads<Int>()
    _ = r.request(.step(1), folder: a, now: t0)
    _ = r.request(.step(2), folder: a, now: t0)
    _ = r.request(.event, folder: a, now: t0)
    let first = r.finish(a, took: .seconds(1), now: t0 + .seconds(1), outcome: .rerun)
    #expect(first.waiters.isEmpty && first.next == .start)   // at once, no ten-listing gap
    let second = r.finish(a, took: .milliseconds(1), now: t0 + .seconds(2), outcome: .applied)
    #expect(second.waiters == [1, 2] && second.next == .none)   // the rerun started after the event
}

@Test func resetDropsListingsStillOut() {
    var r = FolderRereads<Int>()
    _ = r.request(.step(1), folder: a, now: t0)
    r.reset()
    #expect(!r.isListing(a))
    let done = r.finish(a, took: .milliseconds(1), now: t0, outcome: .applied)
    #expect(done.waiters.isEmpty && done.next == .none)
}


@Test func takenWaitersDoNotFireAgainWithTheListing() {   // the quick names pass answered the steps first
    var r = FolderRereads<Int>()
    _ = r.request(.open, folder: a, now: t0)
    _ = r.request(.step(1), folder: a, now: t0)
    #expect(r.takeWaiters(a) == [1] && r.takeWaiters(a).isEmpty && r.isListing(a))
    #expect(r.takeWaiters(b).isEmpty)
    let done = r.finish(a, took: .seconds(8), now: t0 + .seconds(8), outcome: .applied)
    #expect(done.waiters.isEmpty)
}
