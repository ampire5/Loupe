/// Paces photo steps through the folder: with `wheel-step` / `key-step`, none before the photo the last step went to
/// is on screen at the quality asked for (`StepWait`). The wheel's gate (`oncePerFrame`) also lets at most one
/// notch per display frame through (spec §8.2: steps do not queue up); the keyboard's does not, since a held key
/// repeats at the system's rate and always stepped every repeat. The first request navigates at once; any other
/// while the wait holds (or, for the wheel, before the next frame) is dropped, not remembered, so a fast spin or
/// a held key never builds a backlog that keeps flipping after it stops: it just steps as fast as the photos show.
/// The wheel and the keys each have their own gate. The wheel's `frame()` is fed from a display link that runs only
/// while `isActive`; times are the events' clock (`NSEvent.timestamp`, seconds).
public struct StepGate: Sendable {
    /// A step that waits for its photo: since when, and for what.
    public struct Pending: Equatable, Sendable {
        public var wait: StepWait
        public var since: Double
    }

    /// The longest a step waits for its photo: one that is slow to come (a large file over SMB, a decode stuck
    /// behind others) holds the wheel or the keys this long at most, then the next notch or press steps anyway.
    public static let waitLimit = 1.0

    /// A step already went through in the current frame (only with `oncePerFrame`).
    public private(set) var isActive = false
    /// The last step's wait while its photo is not on screen at that quality yet; nil when there is none.
    public private(set) var pending: Pending?
    /// Whether a step waits for its photo: the cheap test before reading what the screen shows.
    public var isWaiting: Bool { pending != nil }

    /// Whether at most one step goes through per display frame (the wheel); false for keys.
    public let oncePerFrame: Bool

    public init(oncePerFrame: Bool = true) { self.oncePerFrame = oncePerFrame }

    /// A wheel notch or key press (or repeat) arrived at `now`: true if it may navigate now (no step yet in this
    /// frame for the wheel, and the last step's photo shown or waited for `waitLimit`); the caller then steps and
    /// calls `stepped`. Others are dropped.
    public mutating func request(now: Double) -> Bool {
        guard !isActive else { return false }
        if let pending, now - pending.since < Self.waitLimit { return false }
        pending = nil
        isActive = oncePerFrame
        return true
    }

    /// The request that passed stepped at `now`; the next request waits until `photoShown` satisfies `wait`.
    public mutating func stepped(waitFor wait: StepWait, now: Double) {
        pending = wait == .any ? nil : Pending(wait: wait, since: now)
    }

    /// What the screen now shows of the current photo (nil: still another photo, or nothing). The gate opens once
    /// it satisfies the wait, at once, so a photo shown before the next notch (a cached neighbour) never blocks it.
    public mutating func photoShown(_ quality: ShownQuality?) {
        if let pending, pending.wait.isSatisfied(by: quality) { self.pending = nil }
    }

    /// Forgets the wait and the frame's step (the view's display link stopped, or its window went away): the next
    /// request steps at once.
    public mutating func cancel() {
        pending = nil
        isActive = false
    }

    /// A display refresh passed: the next wheel notch may step again.
    public mutating func frame() {
        isActive = false
    }
}
