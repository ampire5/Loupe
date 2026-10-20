import Foundation

/// Decides, once per display-link callback, whether the render loop draws, stays awake, or lets the
/// link sleep (spec §3: idle ≈ 0 % CPU).
///
/// Pausing on the first callback that finds nothing new loses frames during a gesture: in native full
/// screen, drag and scroll events arrive at the display rate and in phase with the callback, so the
/// callback often fires just before the event is handled, sees nothing, pauses, and the event then has
/// to resume the link, which costs the frame for that vsync. So the link stays awake, skipping
/// callbacks, until nothing has changed for `grace`; a change in that time is drawn by the very next
/// callback with no resume round-trip. The clock is the display link's own timestamp, so the policy
/// is independent of wall time and testable.
public struct IdlePolicy {
    public enum Action: Equatable, Sendable {
        /// Something changed: draw this frame.
        case draw
        /// Nothing changed, but not for long enough yet: draw nothing, keep the link running.
        case skip
        /// Nothing changed for `grace`: pause the link.
        case pause
    }

    /// How long without a change before the link may pause.
    public static let grace: TimeInterval = 0.3

    /// When the last changed frame was seen; nil until the first one.
    private var lastChange: TimeInterval?

    public init() {}

    /// Call once per callback with whether a new snapshot arrived and the callback's timestamp.
    /// A callback after a resume with nothing new (the change was already drawn) pauses at once:
    /// its timestamp is already past the grace period.
    public mutating func frame(changed: Bool, at time: TimeInterval) -> Action {
        if changed {
            lastChange = time
            return .draw
        }
        guard let lastChange, time - lastChange < Self.grace else { return .pause }
        return .skip
    }
}
