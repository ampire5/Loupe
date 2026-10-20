import CoreGraphics

/// Recognises a three-finger horizontal swipe from raw trackpad touches. The system gesture is
/// usually off (or taken by Spaces), so AppKit never sends `swipe(with:)`; the view feeds this type
/// the normalised positions (0...1 over the trackpad) of every finger currently touching instead.
///
/// A swipe is exactly three fingers whose mean position moved more than `distance` horizontally since
/// the third one landed, mostly horizontally (|dx| > 2·|dy|). One gesture gives one `Step`: after
/// firing it is latched until every finger is lifted, so a long drag never pages through the folder.
/// Any change of the finger count before firing drops the baseline: the fingers that arrive or leave
/// shift the mean without anyone swiping.
///
/// The same fingers swiped up or down give `.up` / `.down` (by the same distance and dominance, vertically), and three
/// fingers put down and lifted again within `tapTime` without moving `tapDrift` give `.tap` when the last one lifts
/// (never more than three on the pad, nothing fired).
public struct ThreeFingerSwipe: Sendable {
    public enum Step: Sendable, Equatable { case next, previous, up, down, tap }

    /// The longest a tap may last, from the third finger landing to the last one lifting, in seconds.
    public static let tapTime = 0.3
    /// How far the three fingers' mean may move in a tap, in trackpad widths.
    public static let tapDrift = 0.02

    /// Mean horizontal travel, in trackpad widths, that counts as a swipe.
    public static let distance = 0.08
    /// How much more horizontal than vertical the movement must be.
    public static let dominance = 2.0

    /// Mean position of the three fingers when the third one landed (or the count last became 3).
    private var baseline: CGPoint?
    /// Fired already; cleared only when no finger touches the trackpad.
    private var latched = false
    /// The touch so far may still be a tap: when the third finger landed; nil once it cannot (moved, a fourth finger).
    private var tapStart: Double?
    /// The most fingers on the pad since it was last empty.
    private var most = 0

    public init() {}

    /// Forgets the baseline and the latch. For when touches stop being delivered without every finger
    /// having been seen lifting (cancelled touches, the window losing key status, moving to another
    /// window): a stale latch would swallow the next swipe, a stale baseline would fire a phantom one.
    public mutating func reset() {
        baseline = nil
        latched = false
        tapStart = nil
        most = 0
    }

    /// Call on every touch event with the positions of all fingers currently touching and the event's time in seconds.
    /// Swiping left (fingers move towards x = 0) is `.next`, right is `.previous`, like Photos; up (towards y = 1) is
    /// `.up`, down `.down`.
    public mutating func update(touches: [CGPoint], at time: Double = 0) -> Step? {
        if touches.isEmpty {
            let tap = !latched && most == 3 && tapStart.map { time - $0 <= Self.tapTime } == true
            reset()
            return tap ? .tap : nil
        }
        most = max(most, touches.count)
        if most > 3 { tapStart = nil }
        guard touches.count == 3 else {
            baseline = nil
            return nil
        }
        guard !latched else { return nil }
        let mean = CGPoint(x: touches.reduce(0) { $0 + $1.x } / 3, y: touches.reduce(0) { $0 + $1.y } / 3)
        guard let start = baseline else {
            baseline = mean
            if most == 3, tapStart == nil, !latched { tapStart = time }
            return nil
        }
        let dx = mean.x - start.x, dy = mean.y - start.y
        if hypot(dx, dy) > Self.tapDrift { tapStart = nil }
        if abs(dx) > Self.distance, abs(dx) > Self.dominance * abs(dy) {
            latched = true
            return dx < 0 ? .next : .previous
        }
        if abs(dy) > Self.distance, abs(dy) > Self.dominance * abs(dx) {
            latched = true
            return dy > 0 ? .up : .down
        }
        return nil
    }
}
