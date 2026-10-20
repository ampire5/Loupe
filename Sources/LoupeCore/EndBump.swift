import Foundation

/// When a previous / next step that stopped at an end of the folder plays `haptic-end` (M4c spec §10.5): one bump per
/// push against the end. The first blocked step bumps; auto-repeats of a held key and further notches of a spinning
/// wheel into the same end do not, until a step moves, a step goes against the other end (a one-photo folder), or a
/// fresh press comes. Fresh: a key press that is not an auto-repeat, a mouse-button press, or a wheel notch after a
/// pause of `wheelPause` (`isFreshNotch`).
public struct EndBump: Sendable {
    /// The seconds without a notch after which the next notch is a new push: longer than the gaps between the notches
    /// of a spin, shorter than a deliberate second turn.
    public static let wheelPause: TimeInterval = 0.3

    /// The direction of the end last bumped against, nil once a step moved.
    private var bumped: Int?

    public init() {}

    /// A step was tried: `moved` false when it stopped at an end; `direction` its sign. True: play `haptic-end`.
    public mutating func stepped(moved: Bool, direction: Int, fresh: Bool) -> Bool {
        guard !moved else {
            bumped = nil
            return false
        }
        let d = direction.signum()
        if bumped == d, !fresh { return false }
        bumped = d
        return true
    }

    /// Whether a wheel notch at `time` starts a new push: the first notch, or one `wheelPause` after the previous.
    public static func isFreshNotch(at time: TimeInterval, previous: TimeInterval?) -> Bool {
        guard let previous else { return true }
        return time - previous >= wheelPause
    }
}
