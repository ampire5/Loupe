import Testing
@testable import LoupeCore

@Suite struct GestureAxisLockTests {
    @Test func pendingTravelIsDeliveredOnceAndAxisSurvivesReversal() {
        var g = GestureAxisLock()
        #expect(g.filter(x: 0.1, y: 2, precise: true, momentum: false, began: true, at: 1) == .init(x: 0, y: 0))
        #expect(g.filter(x: 0.2, y: 3, precise: true, momentum: false, began: false, at: 1.01) == .init(x: 0, y: 5))
        #expect(g.filter(x: 100, y: -8, precise: true, momentum: false, began: false, at: 1.02) == .init(x: 0, y: -8))
        #expect(g.filter(x: 100, y: 0, precise: true, momentum: true, began: false, at: 1.03) == .init(x: 0, y: 0))
    }
    @Test func freshGestureImmediatelyReplacesMomentumAxis() {
        var g = GestureAxisLock()
        _ = g.filter(x: 0, y: 10, precise: true, momentum: false, began: true, at: 1)
        _ = g.filter(x: 0, y: 10, precise: true, momentum: true, began: false, at: 1.01)
        #expect(g.filter(x: 10, y: 1, precise: true, momentum: false, began: true, at: 1.02) == .init(x: 10, y: 0))
    }
    @Test func zeroDeltaBeginStillResetsBeforeFirstMovement() {
        var g = GestureAxisLock()
        _ = g.filter(x: 0, y: 10, precise: true, momentum: false, began: true, at: 1)
        _ = g.filter(x: 0, y: 0, precise: true, momentum: false, began: true, at: 1.01)
        #expect(g.filter(x: 10, y: 0, precise: true, momentum: false, began: false, at: 1.02) == .init(x: 10, y: 0))
    }
    @Test func restReleasesPhaselessAxisButNotHeldFingerAxis() {
        var g = GestureAxisLock()
        _ = g.filter(x: 0, y: 10, precise: true, momentum: false, began: true, at: 1)
        #expect(g.filter(x: 10, y: 0, precise: true, momentum: false, began: false, phased: true, at: 2) == .init(x: 0, y: 0))
        #expect(g.filter(x: 10, y: 0, precise: true, momentum: false, began: false, at: 3) == .init(x: 10, y: 0))
    }
    @Test func pointerCannotSwitchAxesUntilReset() {
        var g = GestureAxisLock()
        #expect(g.project(x: 5, y: 1) == .init(x: 5, y: 0))
        #expect(g.project(x: 1, y: 100) == .init(x: 1, y: 0))
        g.reset()
        #expect(g.project(x: 1, y: 5) == .init(x: 0, y: 5))
    }
}
