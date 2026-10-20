import Foundation
import Testing
@testable import LoupeCore

/// A store stand-in, a clock that moves only when told, and a sleep that records and returns at once.
@MainActor private final class FakeSource {
    var now = ContinuousClock.now
    var sleeps: [Duration] = []
    var fetches: [[String]] = []
    var table: [URL: Double] = [:]
    /// What the store answers with `exif-orientation=no`, and the flag each fetch was made with.
    var storedTable: [URL: Double] = [:]
    var applied: [Bool] = []
    var changes = 0

    func make() -> StripAspects {
        let aspects = StripAspects(
            fetch: { urls, applies in
                self.fetches.append(urls.map(\.lastPathComponent).sorted())
                self.applied.append(applies)
                return (applies ? self.table : self.storedTable).filter { urls.contains($0.key) }
            },
            now: { self.now },
            sleep: { self.sleeps.append($0) })
        aspects.onChange = { self.changes += 1 }
        return aspects
    }
}

@MainActor @Suite struct StripAspectsTests {
    private let a = URL(fileURLWithPath: "/p/a.jpg"), b = URL(fileURLWithPath: "/p/b.jpg")
    private let c = URL(fileURLWithPath: "/p/c.jpg"), d = URL(fileURLWithPath: "/p/d.jpg")

    /// Lets the strip's fetch tasks run (they hop to the main actor between steps).
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
        return condition()
    }

    private func values(_ aspects: StripAspects) -> [Double]? { aspects.layoutAspects?.values }

    @Test func playlistFetchesAtOnceAndGuessesTheMedian() async {
        let fake = FakeSource()
        fake.table = [a: 1.5, b: 0.5, c: 2]
        let aspects = fake.make()
        aspects.setPlaylist([a, b, c, d])
        #expect(values(aspects) == [1.5, 1.5, 1.5, 1.5])   // nothing known: 3:2
        #expect(await eventually { fake.changes == 1 })
        #expect(fake.fetches == [["a.jpg", "b.jpg", "c.jpg", "d.jpg"]])
        #expect(fake.sleeps.isEmpty)
        #expect(values(aspects) == [1.5, 0.5, 2, 1.5])   // d: the median of 0.5, 1.5, 2
    }

    @Test func arrivalsCoalesceToOneChangePerInterval() async {
        let fake = FakeSource()
        fake.table = [a: 1.5, b: 0.5]
        let aspects = fake.make()
        aspects.setPlaylist([a, b, c, d])
        #expect(await eventually { fake.changes == 1 })

        // Two thumbnails made right after the first change: one fetch, 250 ms after it.
        fake.table[c] = 0.75
        fake.table[d] = 2
        aspects.thumbnailArrived(c)
        aspects.thumbnailArrived(d)
        aspects.thumbnailArrived(URL(fileURLWithPath: "/elsewhere/x.jpg"))   // another window's file
        #expect(await eventually { fake.changes == 2 })
        #expect(fake.sleeps == [.milliseconds(250)])
        #expect(fake.fetches.count == 2)
        #expect(fake.fetches[1] == ["c.jpg", "d.jpg"])
        #expect(values(aspects) == [1.5, 0.5, 0.75, 2])

        // Once the interval has passed, the next arrival is fetched without a wait.
        fake.now += .milliseconds(300)
        fake.table[a] = 1.25
        aspects.thumbnailArrived(a)
        #expect(await eventually { fake.changes == 3 })
        #expect(fake.sleeps == [.milliseconds(250)])
        #expect(values(aspects)?.first == 1.25)
    }

    @Test func nothingNewIsNoChange() async {
        let fake = FakeSource()
        fake.table = [a: 1.5]
        let aspects = fake.make()
        aspects.setPlaylist([a, b])
        #expect(await eventually { fake.changes == 1 })
        aspects.thumbnailArrived(a)   // same value again
        #expect(await eventually { fake.fetches.count == 2 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(fake.changes == 1)
    }

    /// `exif-orientation=no` (spec M3b §2.1): the aspects are the stored ones, asked for again at the toggle and
    /// again when it goes back; the same value twice asks for nothing.
    @Test func exifOrientationToggleAsksForTheOtherAspects() async {
        let fake = FakeSource()
        fake.table = [a: 0.75, b: 2]        // oriented: a is a turned photo
        fake.storedTable = [a: 1.5, b: 2]   // as stored
        let aspects = fake.make()
        aspects.setPlaylist([a, b])
        #expect(await eventually { fake.changes == 1 })
        #expect(values(aspects) == [0.75, 2])

        aspects.setAppliesOrientation(false)
        aspects.setAppliesOrientation(false)
        #expect(await eventually { fake.changes == 2 })
        #expect(values(aspects) == [1.5, 2])
        #expect(fake.applied == [true, false])
        #expect(fake.fetches[1] == ["a.jpg", "b.jpg"])

        aspects.setAppliesOrientation(true)
        #expect(await eventually { fake.changes == 3 })
        #expect(values(aspects) == [0.75, 2])
        #expect(fake.applied == [true, false, true])
    }

    @Test func pausedDefersTheChangeToTheRelease() async {
        let fake = FakeSource()
        fake.table = [a: 0.5]
        let aspects = fake.make()
        aspects.setPlaylist([a, b])
        #expect(await eventually { fake.changes == 1 })
        #expect(values(aspects) == [0.5, 0.5])

        aspects.paused = true
        fake.table[b] = 2
        aspects.thumbnailArrived(b)
        #expect(await eventually { fake.fetches.count == 2 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(fake.changes == 1)
        #expect(values(aspects) == [0.5, 0.5])

        aspects.paused = false
        #expect(fake.changes == 2)
        #expect(values(aspects) == [0.5, 2])
    }

    @Test func firstCellPictureAsksForEveryUnknownFile() async {
        let fake = FakeSource()
        let aspects = fake.make()
        aspects.setPlaylist([a, b, c])   // before the folder synced: the store knows nothing yet
        #expect(await eventually { fake.fetches.count == 1 })
        #expect(fake.changes == 0)

        fake.table = [a: 1, b: 2, c: 0.5]
        aspects.cellPictureArrived(a)
        #expect(await eventually { fake.changes == 1 })
        #expect(fake.fetches[1] == ["a.jpg", "b.jpg", "c.jpg"])
        aspects.cellPictureArrived(b)   // known now: nothing to ask
        try? await Task.sleep(for: .milliseconds(20))
        #expect(fake.fetches.count == 2)
    }

    @Test func cropModeHasNoAspectsAndFetchesNothing() async {
        let fake = FakeSource()
        fake.table = [a: 0.5]
        let aspects = fake.make()
        aspects.setMode(.crop)
        aspects.setPlaylist([a, b])
        aspects.thumbnailArrived(a)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(aspects.layoutAspects == nil)
        #expect(fake.fetches.isEmpty)

        aspects.setMode(.native)
        #expect(await eventually { fake.changes == 1 })
        #expect(values(aspects) == [0.5, 0.5])
    }

    @Test func closedFetchesNothing() async {
        let fake = FakeSource()
        fake.table = [a: 0.5]
        let aspects = fake.make()
        aspects.close()
        aspects.setPlaylist([a])
        try? await Task.sleep(for: .milliseconds(20))
        #expect(fake.fetches.isEmpty && fake.changes == 0)
    }
}
