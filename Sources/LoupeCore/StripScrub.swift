/// One window's strip scrub (M2.5 spec §4.3, §5.3): whether a scrub is on and the photo it started from. That photo
/// stays the cache's previous one for the whole scrub (it keeps its full resolution, M2 spec §11.1.7), not each file
/// the drag passes over. A press on the current photo's cell starts nothing: the scrub begins, from that photo, when
/// the drag first leaves it, so a click there changes nothing (no scrubbing focus, no seed, no dwell reset).
public struct StripScrub: Sendable {
    public enum Step: Equatable, Sendable {
        /// Not a scrub (yet): the press is on the photo already current.
        case none
        /// The scrub is on and reached the photo already current: it only needs its scrubbing focus.
        case stay
        /// Make the target current, with `previous` as the photo before it.
        case move(previous: Int)
    }

    /// The playlist index the scrub started from; nil while no scrub is on.
    private var origin: Int?

    public init() {}

    public var isOn: Bool { origin != nil }

    /// A press or drag reached `target` while `current` is the current photo.
    public mutating func reach(_ target: Int, current: Int) -> Step {
        guard let origin else {
            guard target != current else { return .none }
            origin = current
            return .move(previous: current)
        }
        return target == current ? .stay : .move(previous: origin)
    }

    /// The press ended or the cursor rested: true when a scrub was on (its photo now gets the normal plan).
    public mutating func end() -> Bool {
        defer { origin = nil }
        return origin != nil
    }
}
