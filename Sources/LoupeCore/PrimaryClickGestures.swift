import CoreGraphics
import Foundation

/// Separates raw finger taps from completed plain mouse presses. Force Touch sends its
/// pressure events separately, so a press can be disqualified before or after mouse-down.
public struct PrimaryClickGestures: Sendable {
    private struct Start: Sendable {
        let point: CGPoint
        let time: TimeInterval
    }

    private struct Press: Sendable {
        let start: Start
        var physical: Bool
        var valid = true
    }

    private static let tapMouseEventLag: TimeInterval = 0.08

    private var contact = false
    private var tapStart: Start?
    private var lastTap: TimeInterval?
    private var recentLightTap: TimeInterval?
    private var lastClick: Start?
    private var press: Press?
    private var pressureStage = 0
    private var forced = false

    public init() {}

    /// True after the second brief, still single-finger contact.
    public mutating func touches(_ points: [CGPoint], at time: TimeInterval, interval: TimeInterval) -> Bool {
        guard let point = points.first else {
            guard contact else { return false }
            contact = false
            defer { tapStart = nil }
            guard let start = tapStart, time - start.time <= ThreeFingerSwipe.tapTime else {
                lastTap = nil
                return false
            }
            recentLightTap = time
            lastClick = nil
            if let lastTap, time - lastTap <= interval {
                self.lastTap = nil
                return true
            }
            lastTap = time
            return false
        }
        if !contact {
            contact = true
            if points.count == 1, pressureStage == 0 {
                tapStart = Start(point: point, time: time)
            }
        }
        if points.count != 1 || tapStart.map({ distance($0.point, point) > ThreeFingerSwipe.tapDrift }) == true {
            tapStart = nil
            lastTap = nil
        }
        return false
    }

    public mutating func mouseDown(at point: CGPoint, time: TimeInterval, touching: Bool) {
        // Tap-to-click may deliver mouse-down just after the raw finger lifts. Only a
        // pressure stage can qualify that trackpad event as a physical click.
        let followsTap = recentLightTap.map { time >= $0 && time - $0 <= Self.tapMouseEventLag } ?? false
        let physical = pressureStage > 0 || (!touching && !followsTap)
        press = Press(start: Start(point: point, time: time), physical: physical, valid: !forced)
        if physical { clearTaps() }
    }

    public mutating func mouseDragged(to point: CGPoint) {
        if let press, distance(press.start.point, point) >= GestureAxisLock.slop {
            self.press?.valid = false
            lastClick = nil
        }
    }

    /// True once per force press, even when the finger oscillates between pressure stages.
    public mutating func pressure(stage: Int) -> Bool {
        pressureStage = stage
        guard stage > 0 else { forced = false; return false }
        clearTaps()
        press?.physical = true
        guard stage >= 2, !forced else { return false }
        forced = true
        press?.valid = false
        lastClick = nil
        return true
    }

    /// True after two nearby, completed plain clicks. A force press never enters the pair.
    public mutating func mouseUp(at point: CGPoint, interval: TimeInterval) -> Bool {
        defer { press = nil }
        guard let press, press.physical, press.valid,
              distance(press.start.point, point) < GestureAxisLock.slop else {
            lastClick = nil
            return false
        }
        let start = press.start
        if let lastClick, start.time >= lastClick.time, start.time - lastClick.time <= interval,
           distance(lastClick.point, start.point) < GestureAxisLock.slop {
            self.lastClick = nil
            return true
        }
        lastClick = start
        return false
    }

    private mutating func clearTaps() {
        tapStart = nil
        lastTap = nil
        recentLightTap = nil
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}
