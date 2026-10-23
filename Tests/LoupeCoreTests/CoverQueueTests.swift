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

    // MARK: Work ahead (thumbs-ahead plan, stage 4: the visible cards' subfolders)

    /// The subfolders of the visible cards (`ahead`) go after every client's margin: in view of all, then margins of
    /// all, then the work ahead, each client's in its order.
    @Test func aheadRunsAfterEveryMargin() async {
        let queue = CoverQueue(listingLimit: 1, networkListingLimit: 1)
        let log = CoverLog()
        let gate = HoldGate()
        let work: @Sendable (String) async -> Bool = { id in
            log.begin(id, network: false)
            if id == "h" { try? await gate.wait() }
            log.end(id, network: false, cancelled: false)
            return true
        }
        await queue.want(["h", "m1"], visible: 1, ahead: ["h/a1", "h/a2"], client: 1, isNetwork: { _ in false },
                         work: work)
        #expect(await eventually { log.started == ["h"] })
        await queue.want(["v2", "m2"], visible: 1, ahead: ["v2/b1"], client: 2, isNetwork: { _ in false }, work: work)
        gate.open()
        #expect(await eventually { log.ended.count == 7 })
        #expect(log.started == ["h", "v2", "m1", "m2", "h/a1", "h/a2", "v2/b1"])
    }

    /// A card that left the visible set takes its subfolders with it: those waiting are dropped, the one running is
    /// cancelled.
    @Test func subfoldersLeaveWithTheirParent() async {
        let queue = CoverQueue(listingLimit: 1, networkListingLimit: 1)
        let log = CoverLog()
        await queue.want(["p"], visible: 1, isNetwork: { _ in false }, work: Self.work(log, time: .milliseconds(1)))
        #expect(await eventually { log.ended.contains("p") })
        // Its subfolders come; "p/a" hangs until cancelled.
        await queue.want(["p"], visible: 1, ahead: ["p/a", "p/b"], isNetwork: { _ in false },
                         work: Self.work(log, time: .seconds(30)))
        #expect(await eventually { log.started.contains("p/a") })
        await queue.want(["q"], visible: 1, isNetwork: { _ in false }, work: Self.work(log, time: .milliseconds(1)))
        #expect(await eventually { log.ended.contains("q") })
        #expect(log.cancelled == ["p/a"])
        #expect(!log.started.contains("p/b"))
        #expect(await queue.pendingCount == 0)
        #expect(await eventually { await queue.runningCount == 0 })
    }

    /// On a share the work ahead keeps to the one listing in flight: never two network tasks at once, whatever the
    /// tiers.
    @Test func shareKeepsOneListingWithSubfolders() async {
        let queue = CoverQueue(listingLimit: 2, networkListingLimit: 1)
        let log = CoverLog()
        let ids = ["net1", "net2", "local1"]
        let ahead = (1...4).map { "net1/s\($0)" } + (1...2).map { "net2/s\($0)" } + ["local1/s1"]
        await queue.want(ids, visible: 2, ahead: ahead, isNetwork: Self.isNetwork, work: Self.work(log))
        #expect(await eventually { log.ended.count == ids.count + ahead.count })
        #expect(log.peak(network: true) == 1)
        #expect(log.peak(network: false) == 2)
    }

    /// Each tier counts what is wanted and what is done, per client.
    @Test func progressCountsEachTier() async {
        let queue = CoverQueue(listingLimit: 4, networkListingLimit: 1)
        let gate = HoldGate()
        let work: @Sendable (String) async -> Bool = { id in
            if id.hasPrefix("m") { try? await gate.wait() }
            return true
        }
        await queue.want(["v1", "v2", "m1"], visible: 2, ahead: ["v1/a"], client: 3, isNetwork: { _ in false },
                         work: work)
        #expect(await eventually {
            await queue.progress(client: 3) == CoverProgress(inView: WorkCount(done: 2, total: 2),
                                                              margin: WorkCount(done: 0, total: 1),
                                                              ahead: WorkCount(done: 1, total: 1))
        })
        gate.open()
        #expect(await eventually { await queue.progress(client: 3).margin == WorkCount(done: 1, total: 1) })
        #expect(await queue.progress(client: 4) == CoverProgress())
        // Wanted again without the margin and the work ahead: they drop out of the count.
        await queue.want(["v1"], visible: 1, client: 3, isNetwork: { _ in false }, work: work)
        #expect(await queue.progress(client: 3) == CoverProgress(inView: WorkCount(done: 1, total: 1)))
    }

    /// The progress handler hears the client whose counts may have changed.
    @Test func progressIsAnnounced() async {
        let queue = CoverQueue(listingLimit: 2, networkListingLimit: 1)
        let heard = HeardClients()
        await queue.setOnProgress { heard.add($0) }
        await queue.want(["v1"], visible: 1, ahead: ["v1/a"], client: 7, isNetwork: { _ in false }) { _ in true }
        #expect(await eventually { await queue.progress(client: 7).ahead.done == 1 })
        #expect(heard.all.count >= 3)   // the want, and each card done
        #expect(Set(heard.all) == [7])
    }

    /// The user's pause of the work ahead (thumbs-ahead spec, "Пауза"): the cards in view and the margin go on, the
    /// work ahead waits, and the walk's check says so; off again, the work ahead starts.
    @Test func pauseKeepsTheViewAlive() async {
        let queue = CoverQueue(listingLimit: 4, networkListingLimit: 1, resumeDelay: .zero)
        let log = CoverLog()
        await queue.pauseAhead(true)
        #expect(await queue.aheadPaused)
        await queue.want(["v1", "m1"], visible: 1, ahead: ["v1/a"], isNetwork: { _ in false },
                         work: Self.work(log, time: .zero))
        #expect(await eventually { log.ended.count == 2 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(Set(log.started) == ["v1", "m1"])
        await queue.pauseAhead(false)
        #expect(await !queue.aheadPaused)
        #expect(await eventually { log.ended.count == 3 })
        #expect(log.started.last == "v1/a")
    }

    /// Work that waits for the work ahead (the walk's stamps) waits on the queue's resume, not a poll: it returns at
    /// once while nothing holds it, stays while either pause holds, and goes on when the last one ends or its task is
    /// cancelled.
    @Test func aheadWaitersWakeOnResume() async {
        let queue = CoverQueue(listingLimit: 4, networkListingLimit: 1, resumeDelay: .milliseconds(20))
        await queue.waitWhileAheadPaused()   // nothing holds it: at once
        await queue.pauseAhead(true)
        await queue.pause(true)
        let woke = Locked(false)
        let waiter = Task {
            await queue.waitWhileAheadPaused()
            woke.update { $0 = true }
        }
        #expect(await eventually { await queue.aheadWaiterCount == 1 })
        await queue.pauseAhead(false)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!woke.get)   // the viewer's pause still holds
        await queue.pause(false)
        #expect(await eventually { woke.get })   // after the resume delay
        await waiter.value
        #expect(await queue.aheadWaiterCount == 0)
        // Cancelled while waiting: it returns, and its place goes.
        await queue.pauseAhead(true)
        let cancelled = Task { await queue.waitWhileAheadPaused() }
        #expect(await eventually { await queue.aheadWaiterCount == 1 })
        cancelled.cancel()
        await cancelled.value
        #expect(await eventually { await queue.aheadWaiterCount == 0 })
        #expect(await queue.aheadPaused)
    }

    /// The viewer's pause and the user's are apart: the end of one leaves the other.
    @Test func browsingResumeKeepsTheUsersPause() async {
        let queue = CoverQueue(listingLimit: 4, networkListingLimit: 1, resumeDelay: .zero)
        let log = CoverLog()
        await queue.pauseAhead(true)
        await queue.pause(true)
        #expect(await queue.browsingPaused)
        await queue.want(["v1"], visible: 1, ahead: ["v1/a"], isNetwork: { _ in false }, work: Self.work(log, time: .zero))
        await queue.pause(false)
        #expect(await !queue.browsingPaused)
        #expect(await eventually { log.ended.count == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.started == ["v1"])
        #expect(await queue.aheadPaused)
    }

    /// Either pause beginning or ending changes what every client's progress shows: each is told, once per change.
    @Test func pausesAreAnnounced() async {
        let queue = CoverQueue(listingLimit: 2, networkListingLimit: 1, resumeDelay: .zero)
        let heard = HeardClients()
        let slow: @Sendable (String) async -> Bool = { _ in
            try? await Task.sleep(for: .seconds(60))
            return true
        }
        await queue.want(["a"], visible: 1, client: 1, isNetwork: { _ in false }, work: slow)
        await queue.want(["b"], visible: 1, client: 2, isNetwork: { _ in false }, work: slow)
        await queue.setOnProgress { heard.add($0) }
        await queue.pause(true)
        #expect(heard.all.count == 2)
        #expect(Set(heard.all) == [1, 2])
        await queue.pause(true)   // no change: no word
        #expect(heard.all.count == 2)
        await queue.pause(false)
        #expect(heard.all.count == 4)
        await queue.pauseAhead(true)
        #expect(heard.all.count == 6)
        await queue.pauseAhead(true)
        #expect(heard.all.count == 6)
        await queue.setOnProgress { _ in }
        await queue.want([], visible: 0, client: 1, isNetwork: { _ in false }, work: slow)
        await queue.want([], visible: 0, client: 2, isNetwork: { _ in false }, work: slow)
    }
}

/// Clients the progress handler heard.
private final class HeardClients: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [Int] = []
    func add(_ client: Int) { lock.withLock { clients.append(client) } }
    var all: [Int] { lock.withLock { clients } }
}

/// When each try happened.
private final class TryTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [ContinuousClock.Instant] = []
    func add() { lock.withLock { times.append(.now) } }
    var all: [ContinuousClock.Instant] { lock.withLock { times } }
}
