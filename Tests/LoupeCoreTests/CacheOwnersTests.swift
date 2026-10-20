import Testing
import Foundation
@testable import LoupeCore

private let now = ContinuousClock.now

private func url(_ name: String) -> URL { URL(fileURLWithPath: "/photos/\(name).jpg") }

/// A session listing `names` in order (index = position).
private func session(_ id: Int, _ names: [String], current: Int? = nil, direction: Int = 1, active: Bool = false,
                     visible: Bool = false, idleFor minutes: Int = 0, hiddenFor hidden: Int? = nil) -> CacheOwnerFacts {
    var index: [URL: Int] = [:]
    for (i, name) in names.enumerated() { index[url(name)] = i }
    return CacheOwnerFacts(id: CacheSessionID(id), fileIndex: index, current: current, direction: direction,
                           isActive: active, isVisible: visible, lastActive: now - .seconds(minutes * 60),
                           hiddenSince: hidden.map { now - .seconds($0 * 60) })
}

private func order(_ urls: [String], _ sessions: [CacheOwnerFacts]) -> [String] {
    CacheOwners.evictionOrder(urls.map(url), sessions: sessions).map { $0.deletingPathExtension().lastPathComponent }
}

@Suite struct CacheOwnersTests {
    @Test func orphansGoFirst() {
        let a = session(1, ["a0", "a1"], current: 0, idleFor: 10)
        #expect(order(["a1", "ghost", "a0"], [a]) == ["ghost", "a1", "a0"])
    }

    @Test func orphansKeepEntryOrder() {
        let a = session(1, ["a0"], active: true)
        #expect(order(["z", "a0", "y", "x"], [a]) == ["z", "y", "x", "a0"])
    }

    @Test func oldestInactiveFirst() {
        let a = session(1, ["a0", "a1"], current: 0, idleFor: 10)
        let b = session(2, ["b0", "b1"], current: 0, idleFor: 1)
        let c = session(3, ["c0", "c1"], active: true)   // no current photo: nothing of it is protected
        #expect(order(["c1", "b1", "a1", "c0", "b0", "a0"], [c, b, a]) == ["a1", "a0", "b1", "b0", "c1", "c0"])
    }

    @Test func farNeighboursBeforeCurrentWithinSession() {
        let names = ["a0", "a1", "a2", "a3", "a4"]
        let a = session(1, names, current: 2, direction: 1, idleFor: 5)
        // 0 and 4 are equally far: the one behind the direction of travel (0) goes first.
        #expect(order(names, [a]) == ["a0", "a4", "a1", "a3", "a2"])
        let back = session(1, names, current: 2, direction: -1, idleFor: 5)
        #expect(order(names, [back]) == ["a4", "a0", "a3", "a1", "a2"])
        // Direction 0 reads as +1.
        let still = session(1, names, current: 2, direction: 0, idleFor: 5)
        #expect(order(names, [still]) == ["a0", "a4", "a1", "a3", "a2"])
    }

    @Test func protectedNeverListed() {
        let a = session(1, ["a0", "a1", "a2"], current: 1, active: true)
        let b = session(2, ["b0", "b1", "b2"], current: 1, visible: true, idleFor: 3)
        let c = session(3, ["c0", "c1", "c2"], current: 1, idleFor: 9)
        let all = ["a0", "a1", "a2", "b0", "b1", "b2", "c0", "c1", "c2"]
        let sessions = [a, b, c]
        #expect(CacheOwners.protected(sessions) == [url("a1"), url("b1")])
        let result = order(all, sessions)
        #expect(!result.contains("a1") && !result.contains("b1"))
        #expect(result.contains("c1"))
        #expect(result.count == 7)
        // A visible session's other photos are ordered by its lastActive, like any inactive session's.
        #expect(Set(result.prefix(3)) == ["c0", "c1", "c2"])
        #expect(Set(result.dropFirst(3).prefix(2)) == ["b0", "b2"])
        #expect(Set(result.suffix(2)) == ["a0", "a2"])
    }

    @Test func sharedEntryGoesByBestOwner() {
        let a = session(1, ["s", "a1"], current: 1, idleFor: 20)
        let c = session(3, ["s", "c1"], current: 1, active: true)
        // `s` is listed by the old A and the active C: it goes among C's entries, after A's.
        #expect(order(["s", "a1"], [a, c]) == ["a1", "s"])
        // Alone in A it would have gone first (farthest from A's current).
        #expect(order(["s", "a1"], [a]) == ["s", "a1"])
    }

    @Test func sharedEntryUsesBestOwnersDistance() {
        // Owner B (more recent) has `p` far from its current; owner A has it next to its own.
        let a = session(1, ["p", "a1", "a2", "a3"], current: 0, idleFor: 20)
        let b = session(2, ["b0", "b1", "b2", "p"], current: 0, idleFor: 2)
        #expect(order(["b0", "p", "b1"], [a, b]) == ["p", "b1", "b0"])
    }

    @Test func holderPrefersActive() {
        let a = session(1, ["x"], idleFor: 0)
        let c = session(3, ["x"], active: true, idleFor: 30)
        #expect(CacheOwners.holder(of: url("x"), sessions: [a, c]) == CacheSessionID(3))
    }

    @Test func holderLatestOtherwise() {
        let a = session(1, ["x"], idleFor: 10)
        let b = session(2, ["x"], idleFor: 2)
        let d = session(4, ["y"], idleFor: 0)
        #expect(CacheOwners.holder(of: url("x"), sessions: [a, d, b]) == CacheSessionID(2))
    }

    @Test func holderNilForOrphan() {
        let a = session(1, ["x"], active: true)
        #expect(CacheOwners.holder(of: url("nobody"), sessions: [a]) == nil)
        #expect(CacheOwners.holder(of: url("x"), sessions: []) == nil)
    }

    @Test func idleSkipsActiveAndVisible() {
        let active = session(1, ["a"], active: true, idleFor: 120)
        let shown = session(2, ["b"], visible: true, idleFor: 120)
        let hidden = session(3, ["c"], idleFor: 120)
        #expect(CacheOwners.idle([active, shown, hidden], now: now, after: .seconds(30 * 60)) == [CacheSessionID(3)])
    }

    @Test func idleAfterThreshold() {
        let almost = session(1, ["a"], idleFor: 29)
        let exactly = session(2, ["b"], idleFor: 30)
        #expect(CacheOwners.idle([almost, exactly], now: now, after: .seconds(30 * 60)) == [CacheSessionID(2)])
    }

    /// Inactive for two hours but on screen until a minute ago (a second monitor, then a Space switch): counts
    /// from going off screen.
    @Test func idleCountsFromGoingOffScreen() {
        let justHidden = session(1, ["a"], idleFor: 120, hiddenFor: 1)
        let longHidden = session(2, ["b"], idleFor: 120, hiddenFor: 30)
        let hiddenThenUsed = session(3, ["c"], idleFor: 10, hiddenFor: 60)
        #expect(CacheOwners.idle([justHidden, longHidden, hiddenThenUsed], now: now, after: .seconds(30 * 60))
                == [CacheSessionID(2)])
    }
}
