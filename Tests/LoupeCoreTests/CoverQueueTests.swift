import Foundation
import Testing
@testable import LoupeCore

/// What the fake cover work saw: how many ran at once (local and network apart), in what order they started, which
/// were cancelled and which ended.
private final class CoverLog: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [Bool: Int] = [:]
    private var peaks: [Bool: Int] = [:]
    private var peakAll = 0
    var started: [String] { lock.withLock { _started } }
    private var _started: [String] = []
    private var _ended: [String] = []
    private var _cancelled: [String] = []

    func begin(_ id: String, network: Bool) {
        lock.withLock {
            _started.append(id)
            running[network, default: 0] += 1
            peaks[network] = max(peaks[network] ?? 0, running[network]!)
            peakAll = max(peakAll, running.values.reduce(0, +))
        }
    }

    func end(_ id: String, network: Bool, cancelled: Bool) {
        lock.withLock {
            running[network, default: 0] -= 1
            _ended.append(id)
            if cancelled { _cancelled.append(id) }
        }
    }

    func peak(network: Bool) -> Int { lock.withLock { peaks[network] ?? 0 } }
    var peakTogether: Int { lock.withLock { peakAll } }
    var ended: [String] { lock.withLock { _ended } }
    var cancelled: [String] { lock.withLock { _cancelled } }
}

/// Tries per id.
private final class TryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ id: String) -> Int {
        lock.withLock {
            counts[id, default: 0] += 1
            return counts[id]!
        }
    }
}

/// Home's folder and archive covers (folder covers spec, "Order and limits"): a few listings at a time, visible cards
/// first, gone cards cancelled, nothing new while the viewer is busy.
@Suite struct CoverQueueTests {
    private static func isNetwork(_ id: String) -> Bool { id.hasPrefix("net") }

    /// Work that takes `time` (or until cancelled) and logs it.
    private static func work(_ log: CoverLog, time: Duration = .milliseconds(30)) -> @Sendable (String) async -> Bool {
        { id in
            let network = isNetwork(id)
            log.begin(id, network: network)
            let cancelled = (try? await Task.sleep(for: time)) == nil
            log.end(id, network: network, cancelled: cancelled)
            return true
        }
    }

    @Test func respectsLimits() async {
        let queue = CoverQueue(listingLimit: 2, networkListingLimit: 1)
        let log = CoverLog()
        let ids = (1...6).map { "local\($0)" } + (1...3).map { "net\($0)" }
        await queue.want(ids, visible: ids.count, isNetwork: Self.isNetwork, work: Self.work(log))
        #expect(await eventually { log.ended.count == ids.count })
        #expect(log.peak(network: false) == 2)
        #expect(log.peak(network: true) == 1)
        // A slow share does not hold up the local cards: both kinds run side by side.
        #expect(log.peakTogether == 3)
        #expect(await eventually { await queue.runningCount == 0 })   // a work ends just before the queue hears of it
    }

    @Test func visibleFirst() async {
        let queue = CoverQueue(listingLimit: 1, networkListingLimit: 1)
        let log = CoverLog()
        let gate = HoldGate()
        let work: @Sendable (String) async -> Bool = { id in
            log.begin(id, network: false)
            if id == "m1" { try? await gate.wait() }
            log.end(id, network: false, cancelled: false)
            return true
        }
        await queue.want(["m1", "m2", "m3"], visible: 0, isNetwork: { _ in false }, work: work)
        #expect(await eventually { log.started == ["m1"] })
        // Scrolled: a card came into view while the margin's first one still runs; it goes before the rest of the margin.
        await queue.want(["v1", "m1", "m2", "m3"], visible: 1, isNetwork: { _ in false }, work: work)
        gate.open()
        #expect(await eventually { log.ended.count == 4 })
        #expect(log.started == ["m1", "v1", "m2", "m3"])
    }

    @Test func cancelledWhenLeft() async {
        let queue = CoverQueue(listingLimit: 1, networkListingLimit: 1)
        let log = CoverLog()
        await queue.want(["a"], visible: 1, isNetwork: { _ in false }, work: Self.work(log, time: .seconds(30)))
        #expect(await eventually { log.started == ["a"] })
        await queue.want(["b"], visible: 1, isNetwork: { _ in false }, work: Self.work(log, time: .milliseconds(1)))
        #expect(await eventually { log.ended.count == 2 })
        #expect(log.cancelled == ["a"])
        #expect(log.started == ["a", "b"])
    }

    /// Task 4: each window's Home is a client of the one queue: one's `want` leaves the other's cards alone, even one
    /// with the same id.
    @Test func clientsKeepTheirCards() async {
        let queue = CoverQueue(listingLimit: 4, networkListingLimit: 1)
        let log = CoverLog()
        await queue.want(["a"], visible: 1, client: 1, isNetwork: { _ in false }, work: Self.work(log, time: .seconds(30)))
        #expect(await eventually { log.started == ["a"] })
        await queue.want(["a", "b"], visible: 2, client: 2, isNetwork: { _ in false },
                         work: Self.work(log, time: .milliseconds(1)))
        #expect(await eventually { log.ended.count == 2 })
        #expect(log.cancelled.isEmpty)
        #expect(log.started.sorted() == ["a", "a", "b"])
        // The first window left its folder: its card alone is cancelled.
        await queue.want([], visible: 0, client: 1, isNetwork: { _ in false }, work: Self.work(log))
        #expect(await eventually { log.cancelled == ["a"] })
        #expect(await eventually { await queue.runningCount == 0 })
    }

    /// Task 4: the cards in view in every window go before any window's margin.
    @Test func visibleOfEveryClientFirst() async {
        let queue = CoverQueue(listingLimit: 1, networkListingLimit: 1)
        let log = CoverLog()
        let gate = HoldGate()
        let work: @Sendable (String) async -> Bool = { id in
            log.begin(id, network: false)
            if id == "h" { try? await gate.wait() }
            log.end(id, network: false, cancelled: false)
            return true
        }
        await queue.want(["h", "m1"], visible: 1, client: 1, isNetwork: { _ in false }, work: work)
        #expect(await eventually { log.started == ["h"] })
        await queue.want(["v2", "m2"], visible: 1, client: 2, isNetwork: { _ in false }, work: work)
        gate.open()
        #expect(await eventually { log.ended.count == 4 })
        #expect(log.started == ["h", "v2", "m1", "m2"])
    }

    /// Review fix: a card whose picture the browser dropped (a sort, a filter, a quick scroll out and back) is asked
    /// for again: once forgotten, its cover is made again; without that, done stays done.
    @Test func forgottenCardIsMadeAgain() async {
        let queue = CoverQueue(listingLimit: 1, networkListingLimit: 1)
        let log = CoverLog()
        await queue.want(["a", "b"], visible: 2, client: 3, isNetwork: { _ in false }, work: Self.work(log, time: .milliseconds(1)))
        #expect(await eventually { log.ended.count == 2 })
        await queue.want(["a", "b"], visible: 2, client: 3, isNetwork: { _ in false }, work: Self.work(log, time: .milliseconds(1)))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(log.started == ["a", "b"])
        await queue.forget(["a"], client: 3)
        await queue.forget(["a"], client: 4)   // another client's: nothing of client 3's
        #expect(await eventually { log.ended.count == 3 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(log.started == ["a", "b", "a"])
    }

    /// Fast scrolling through a hundred folders: the queue keeps only the cards wanted last, and a card that left is
    /// cancelled, so what runs and waits stays bounded.
    @Test func fastScrollStaysBounded() async {
        let queue = CoverQueue(listingLimit: 2, networkListingLimit: 1)
        let log = CoverLog()
        for start in stride(from: 0, to: 100, by: 2) {
            let ids = (start..<start + 6).map { "f\($0)" }
            await queue.want(ids, visible: 2, isNetwork: { _ in false }, work: Self.work(log, time: .seconds(30)))
            #expect(await queue.pendingCount + queue.runningCount <= 6 + 2)
        }
        #expect(await eventually { await queue.runningCount == 2 })
        await queue.want([], visible: 0, isNetwork: { _ in false }, work: Self.work(log))
        #expect(await eventually { await queue.runningCount == 0 })
        #expect(await queue.pendingCount == 0)
        #expect(Set(log.cancelled) == Set(log.started))
    }

    /// A card still wanted is not made again on the next `want`, but one that left and came back is.
    @Test func doneStaysDoneWhileWanted() async {
        let queue = CoverQueue(listingLimit: 2, networkListingLimit: 1)
        let log = CoverLog()
        await queue.want(["a", "b"], visible: 2, isNetwork: { _ in false }, work: Self.work(log, time: .zero))
        #expect(await eventually { log.ended.count == 2 })
        await queue.want(["b", "a"], visible: 2, isNetwork: { _ in false }, work: Self.work(log, time: .zero))
        await queue.want(["b"], visible: 1, isNetwork: { _ in false }, work: Self.work(log, time: .zero))
        await queue.want(["a", "b"], visible: 2, isNetwork: { _ in false }, work: Self.work(log, time: .zero))
        #expect(await eventually { log.ended.count == 3 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.started.sorted() == ["a", "a", "b"])
    }

    @Test func pausedWaits() async {
        let queue = CoverQueue(listingLimit: 2, networkListingLimit: 1, resumeDelay: .zero)
        let log = CoverLog()
        await queue.pause(true)
        await queue.want(["a", "b"], visible: 2, isNetwork: { _ in false }, work: Self.work(log, time: .zero))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.started.isEmpty)
        await queue.pause(false)
        #expect(await eventually { log.ended.count == 2 })
    }

    /// The viewer's idle signal flickers between its jobs: covers start again only once it has held for a while.
    @Test func resumesAfterDelay() async {
        let queue = CoverQueue(listingLimit: 2, networkListingLimit: 1, resumeDelay: .milliseconds(200))
        let log = CoverLog()
        await queue.pause(true)
        await queue.want(["a"], visible: 1, isNetwork: { _ in false }, work: Self.work(log, time: .zero))
        await queue.pause(false)
        await queue.pause(true)   // busy again before the delay ran out
        try? await Task.sleep(for: .milliseconds(400))
        #expect(log.started.isEmpty)
        await queue.pause(false)
        #expect(await eventually { log.ended.count == 1 })
    }

    /// A pause scheduled to end, then renewed: the first resume's wake, even one already past its timer, is stale.
    @Test func staleResumeIgnored() async {
        let queue = CoverQueue(listingLimit: 2, networkListingLimit: 1, resumeDelay: .seconds(30))
        let log = CoverLog()
        await queue.pause(true)
        await queue.want(["a"], visible: 1, isNetwork: { _ in false }, work: Self.work(log, time: .zero))
        await queue.pause(false)
        let stale = await queue.pauseGeneration
        await queue.pause(true)
        await queue.resume(stale)   // what the first wake does if it left its timer before the second pause
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.started.isEmpty)
        await queue.resume(await queue.pauseGeneration)
        #expect(await eventually { log.ended.count == 1 })
    }

    /// "Not now" from the work: the card stays wanted and is tried again after the retry delay, not marked done.
    @Test func notNowIsTriedAgain() async {
        let queue = CoverQueue(listingLimit: 1, networkListingLimit: 1, retryDelay: .milliseconds(100))
        let log = CoverLog()
        let tries = TryCount()
        let work: @Sendable (String) async -> Bool = { id in
            log.begin(id, network: false)
            log.end(id, network: false, cancelled: false)
            return tries.add(id) >= 3
        }
        let start = ContinuousClock.now
        await queue.want(["a", "b"], visible: 2, isNetwork: { _ in false }, work: work)
        #expect(await eventually { log.ended.count == 6 })
        #expect(ContinuousClock.now - start >= .milliseconds(200))
        #expect(await queue.pendingCount == 0)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(log.ended.count == 6)
    }

    /// Fix round 2: "not now" again and again waits longer each time (doubling), up to the cap. Lower bounds only, and
    /// a loose upper one: a loaded machine wakes late, never early.
    @Test func retryDelayGrows() async {
        let queue = CoverQueue(listingLimit: 1, networkListingLimit: 1, retryDelay: .milliseconds(60),
                               maxRetryDelay: .seconds(10))
        let times = TryTimes()
        await queue.want(["a"], visible: 1, isNetwork: { _ in false }) { _ in
            times.add()
            return false
        }
        #expect(await eventually { times.all.count >= 4 })
        await queue.want([], visible: 0, isNetwork: { _ in false }) { _ in true }
        let gaps = zip(times.all.dropFirst(), times.all).map { $0 - $1 }
        #expect(gaps[0] >= .milliseconds(55))
        #expect(gaps[1] >= .milliseconds(115))
        #expect(gaps[2] >= .milliseconds(235))
    }

    /// The delay stops growing at `maxRetryDelay`: five tries 100, 200, 200, 200 ms apart (700 ms), where doubling on
    /// would take 1.5 s.
    /// The delay after each "not now" in a row: the base, doubled each time, never past the cap.
    @Test func retryDelayDoublesUpToTheCap() {
        let delays = (1...6).map { CoverQueue.retryDelay(after: $0, base: .milliseconds(100), cap: .milliseconds(500)) }
        #expect(delays == [.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(500),
                           .milliseconds(500), .milliseconds(500)])
        #expect(CoverQueue.retryDelay(after: 0, base: .seconds(1), cap: .seconds(60)) == .seconds(1))
        #expect(CoverQueue.retryDelay(after: 7, base: .seconds(1), cap: .seconds(60)) == .seconds(60))
        #expect(CoverQueue.retryDelay(after: 6, base: .seconds(1), cap: .seconds(60)) == .seconds(32))
        // A long run of "not now"s does not overflow.
        #expect(CoverQueue.retryDelay(after: 10_000, base: .seconds(1), cap: .seconds(60)) == .seconds(60))
    }

    /// End to end, loosely (a busy machine only makes the tries later): the queue waits at least `retryDelay(after:)`
    /// between the tries of a card that keeps saying "not now".
    @Test func retriesWaitTheDelay() async {
        let base: Duration = .milliseconds(40), cap: Duration = .milliseconds(80)
        let queue = CoverQueue(listingLimit: 1, networkListingLimit: 1, retryDelay: base, maxRetryDelay: cap)
        let times = TryTimes()
        await queue.want(["a"], visible: 1, isNetwork: { _ in false }) { _ in
            times.add()
            return false
        }
        #expect(await eventually { times.all.count >= 4 })
        await queue.want([], visible: 0, isNetwork: { _ in false }) { _ in true }
        let all = times.all
        for n in 1..<4 {
            #expect(all[n] - all[n - 1] >= CoverQueue.retryDelay(after: n, base: base, cap: cap))
        }
    }

    /// A card that left and came back starts over with the shortest delay.
    @Test func retryDelayStartsOverWhenWantedAnew() async {
        let queue = CoverQueue(listingLimit: 1, networkListingLimit: 1, retryDelay: .milliseconds(50),
                               maxRetryDelay: .seconds(10))
        let times = TryTimes()
        let work: @Sendable (String) async -> Bool = { _ in
            times.add()
            return false
        }
        await queue.want(["a"], visible: 1, isNetwork: { _ in false }, work: work)
        #expect(await eventually { times.all.count >= 6 })   // 50 + 100 + 200 + 400 + 800 ms; the next would be 1.6 s
        await queue.want([], visible: 0, isNetwork: { _ in false }, work: work)
        try? await Task.sleep(for: .milliseconds(20))
        let before = times.all.count
        await queue.want(["a"], visible: 1, isNetwork: { _ in false }, work: work)
        #expect(await eventually { times.all.count >= before + 2 })
        let all = times.all
        #expect(all[before + 1] - all[before] < .milliseconds(800))
        await queue.want([], visible: 0, isNetwork: { _ in false }, work: work)
    }
}

/// When each try happened.
private final class TryTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [ContinuousClock.Instant] = []
    func add() { lock.withLock { times.append(.now) } }
    var all: [ContinuousClock.Instant] { lock.withLock { times } }
}
