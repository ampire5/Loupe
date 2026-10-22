import Foundation
import LoupeCore
import Testing

@Test func orderAlternatesDirectionFirst() {
    #expect(ColorOrder.order(count: 10, current: 4, direction: 1, reach: 5) == [4, 5, 3, 6, 2])
    #expect(ColorOrder.order(count: 10, current: 4, direction: -1, reach: 5) == [4, 3, 5, 2, 6])
    // An even reach ends on the side of travel.
    #expect(ColorOrder.order(count: 10, current: 4, direction: 1, reach: 4) == [4, 5, 3, 6])
}

@Test func orderClampsAtEnds() {
    // The side that runs out is skipped; the other one fills the reach.
    #expect(ColorOrder.order(count: 10, current: 0, direction: 1, reach: 5) == [0, 1, 2, 3, 4])
    #expect(ColorOrder.order(count: 10, current: 0, direction: -1, reach: 5) == [0, 1, 2, 3, 4])
    #expect(ColorOrder.order(count: 10, current: 9, direction: 1, reach: 4) == [9, 8, 7, 6])
    #expect(ColorOrder.order(count: 10, current: 1, direction: -1, reach: 5) == [1, 0, 2, 3, 4])
    // A reach beyond the folder takes it all.
    #expect(ColorOrder.order(count: 3, current: 1, direction: 1, reach: 20) == [1, 2, 0])
}

@Test func orderReachOne() {
    #expect(ColorOrder.order(count: 10, current: 4, direction: 1, reach: 1) == [4])
    #expect(ColorOrder.order(count: 1, current: 0, direction: -1, reach: 20) == [0])
}

@Test func orderEmpty() {
    #expect(ColorOrder.order(count: 0, current: 0, direction: 1, reach: 5) == [])
    #expect(ColorOrder.order(count: 10, current: 4, direction: 1, reach: 0) == [])
    #expect(ColorOrder.order(count: 10, current: 10, direction: 1, reach: 5) == [])
}

private let photo = URL(fileURLWithPath: "/photos/a.jpg")

// Final review: a job that read the old thumbnail (it started before the new one arrived) must not clear the stale
// mark, or the old file's analysis stays cached under the new stamp for the session.
@Test func restampJobStartedBeforeTheThumbnailLeavesItStale() {
    var restamps = ColorRestamps()
    restamps.restamp(photo)
    let startedStale = restamps.isStale(photo)   // the job starts, reading the old thumbnail
    #expect(!startedStale)
    let madeStale = restamps.thumbnailArrived(photo)   // the new thumbnail arrives while it analyses
    #expect(madeStale)
    restamps.analysed(photo, startedStale: startedStale)
    #expect(restamps.isStale(photo))             // the next job analyses the new thumbnail
    let next = restamps.isStale(photo)
    restamps.analysed(photo, startedStale: next)
    #expect(!restamps.isStale(photo))
}

@Test func restampThumbnailFirstThenJob() {
    var restamps = ColorRestamps()
    let early = restamps.thumbnailArrived(photo)   // not restamped: nothing to do
    restamps.restamp(photo)
    let first = restamps.thumbnailArrived(photo)
    let second = restamps.thumbnailArrived(photo)  // only the first thumbnail after the change
    #expect(!early && first && !second)
    #expect(restamps.isStale(photo))
    let started = restamps.isStale(photo)
    restamps.analysed(photo, startedStale: started)
    #expect(!restamps.isStale(photo))
}

@Test func restampsForgetPhotosOutOfTheOrder() {
    var restamps = ColorRestamps()
    let other = URL(fileURLWithPath: "/photos/b.jpg")
    restamps.restamp(photo)
    restamps.restamp(other)
    _ = restamps.thumbnailArrived(other)
    restamps.keep([])
    let arrived = restamps.thumbnailArrived(photo)
    #expect(!restamps.isStale(other) && !arrived)
}

/// The other page of a pair on screen comes right after the current photo, whatever the reach, and only once.
@Test func companionComesSecond() {
    #expect(ColorOrder.order(count: 10, current: 4, direction: 1, reach: 4, companion: 3) == [4, 3, 5, 6])
    #expect(ColorOrder.order(count: 10, current: 4, direction: 1, reach: 1, companion: 5) == [4, 5])
    #expect(ColorOrder.order(count: 3, current: 1, direction: 1, reach: 9, companion: 0) == [1, 0, 2])
    #expect(ColorOrder.order(count: 10, current: 4, direction: 1, reach: 3, companion: 4) == [4, 5, 3])
    #expect(ColorOrder.order(count: 10, current: 4, direction: 1, reach: 3, companion: 12) == [4, 5, 3])
}
