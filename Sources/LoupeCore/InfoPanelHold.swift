import Foundation

/// Whether the info panel still shows the previous photo after a step: the new photo's File and Capture facts arrive in
/// parts (its size from a stat, the header, the metadata read, 1–30 ms each even over SMB, M4a bench), and showing each
/// part as it comes rebuilt the panel two or three times per step, its height jumping each time. So the panel keeps
/// what it shows until the new photo is `ready` (metadata read and header known) and swaps it all at once, waiting
/// at most `limit` from the first step of a run: a held arrow key still updates it every `limit`. Times are seconds
/// on any monotonic clock.
public struct InfoPanelHold: Equatable, Sendable {
    public static let limit: TimeInterval = 0.25

    /// When the hold began; nil while nothing is held.
    private var since: TimeInterval?

    public init() {}

    /// The current photo changed at `now`. A step during a hold keeps its start, so fast steps do not push the limit
    /// back.
    public mutating func photoChanged(at now: TimeInterval) {
        if since == nil { since = now }
    }

    /// Whether the panel should keep showing what it shows. A hold ends when the new photo is ready or the limit has
    /// passed; after that every update shows at once until the next step.
    public mutating func holds(ready: Bool, now: TimeInterval) -> Bool {
        guard let since else { return false }
        if ready || now - since >= Self.limit {
            self.since = nil
            return false
        }
        return true
    }

    /// When the hold ends whatever arrives (the panel then shows what is known); nil while nothing is held.
    public var deadline: TimeInterval? { since.map { $0 + Self.limit } }

    /// Ends a hold (the panel closed).
    public mutating func cancel() { since = nil }
}
