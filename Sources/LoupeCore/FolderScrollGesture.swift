/// The mouse buttons the folder gesture cares about, with the bits of `NSEvent.pressedMouseButtons`.
public struct MouseButtons: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = MouseButtons(rawValue: 1 << 0)
    public static let right = MouseButtons(rawValue: 1 << 1)
}

/// Steps to the next or previous folder on a horizontal scroll made while a mouse button is held: on a
/// trackpad, a physical click held with one finger while two others swipe; on a mouse, the right button held
/// while the tilt or side wheel (or ⇧+wheel, which the system turns horizontal) scrolls. A plain scroll pans
/// and a plain wheel steps photos, so the held button is what makes the scroll mean "folder".
///
/// One gesture gives at most one step, and two steps are always at least `folder-scroll-repeat` apart (user,
/// Build 3 trial: going through several folders must not need a release and a new press each time):
/// - a notched wheel steps again on a horizontal notch once the gap since the last step has passed; notches inside
///   the gap are dropped, not saved up, so a fast spin goes one folder per gap;
/// - precise deltas step once per swipe: after a step the swipe is spent until the fingers start a new one
///   (`.began`), rest without moving for the gap, or turn back (then only the way back counts), and it needs the
///   threshold again from there. The system's coast (momentum) never steps: it is not the fingers' doing, and a
///   coast that stepped would run on through folders;
/// - a gap of 0 is one step per press (Build 2.x).
///
/// Everything belongs to one press and is forgotten when every button is released (`buttonsReleased()`); `hasFired`
/// stays true from the first step to the release, so the view keeps the held button from also zooming or panning
/// for the whole press.
///
/// Sign convention: `dx < 0` is `.next`, the way fingers moving left are in `ThreeFingerSwipe`. The view turns
/// the event's deltas into this convention (fingers for a trackpad, wheel direction for a notched wheel, both turned
/// by `folder-scroll-direction`: `FolderScrollDirection.factor`). Times
/// are seconds on the events' own clock (`NSEvent.timestamp`); only differences matter, so tests pass their own.
///
/// The view feeds every scroll event to `event(...)` and every press and release of the left and right buttons to
/// `press` / `release`; the AppKit side only reads the buttons and acts on the outcome.
public struct FolderScrollGesture: Sendable {
    /// `up` / `down`: a precise swipe that went vertical instead (dy < 0 up, dy > 0 down in the view's convention), by
    /// the same threshold, dominance, once-per-swipe and gap rules; the view binds it (`TP_CLICK_UP`, `TP_CLICK_DOWN`).
    public enum Step: Sendable, Equatable { case next, previous, up, down }

    /// What the view does with a scroll event.
    public enum Outcome: Sendable, Equatable {
        /// Not the gesture's: pan or step photos as without it.
        case pass
        /// The gesture's: no pan, no photo step.
        case consumed
        /// The gesture's, and it steps a folder now.
        case step(Step)
    }

    /// Every button the gesture can latch on.
    public static let buttons: MouseButtons = [.left, .right]

    /// Which held buttons make a scroll the gesture's. Precise deltas come from a trackpad (whose physical click is
    /// the left button) or a Magic Mouse, so both count; a notched wheel is a plain mouse, where the left button is
    /// the drag-to-pan button and only the right one counts. (A wheel whose driver sends precise deltas cannot be
    /// told from a trackpad here, so its left button counts too.)
    public static func triggers(precise: Bool) -> MouseButtons { precise ? buttons : .right }

    /// How much more horizontal than vertical the movement must be, as for the three-finger swipe.
    public static let dominance = 2.0

    /// Travel of the current swipe since the press, its re-arm, or the last release, in points.
    private var sumX = 0.0, sumY = 0.0
    /// Stepped during this press; cleared only by `buttonsReleased()`.
    public private(set) var hasFired = false
    /// The last step of this press: when and which way.
    private var lastStep: (time: Double, step: Step)?
    /// The current swipe already stepped: precise travel does not count until it re-arms.
    private var spent = false
    /// Re-armed by turning back: only travel that way counts (a twitch back must not let the spent way step again).
    private var wayBack: Step?
    /// The last precise event that moved, for the "rested for the gap" re-arm.
    private var lastMove: Double?

    public init() {}

    /// A scroll event, with the buttons held right now. `dx`/`dy` in the sign convention above: points for precise
    /// deltas, the wheel's own units for a notch. `momentum`: the system's coast after the fingers lifted.
    /// `began`: the event starts a new scroll gesture (phase `.began`). `repeatAfter`: the gap between steps, in
    /// seconds (0: one step per press). `time`: the event's time, in seconds.
    ///
    /// - No gesture button held: the press is over (its release may have gone to another view): `.pass`.
    /// - Precise deltas with a trigger held are always the gesture's (they must not pan while the button is down);
    ///   momentum is consumed and never counts, so a click that catches a coasting picture does not step either.
    /// - A notch is the gesture's when it is mostly horizontal, or once the press has fired; a vertical notch, or
    ///   a diagonal one before any step, passes and steps photos as before.
    public mutating func event(dx: Double, dy: Double, precise: Bool, momentum: Bool, began: Bool, held: MouseButtons,
                               threshold: Double, repeatAfter: Double, at time: Double) -> Outcome {
        guard !held.isDisjoint(with: Self.buttons) else {
            buttonsReleased()
            return .pass
        }
        guard !held.isDisjoint(with: Self.triggers(precise: precise)) else { return .pass }
        if precise {
            guard !momentum else { return .consumed }
            return scroll(dx: dx, dy: dy, began: began, threshold: threshold, repeatAfter: repeatAfter, at: time)
                .map(Outcome.step) ?? .consumed
        }
        guard dx != 0 else { return .pass }
        if let step = notch(dx: dx, dy: dy, repeatAfter: repeatAfter, at: time) { return .step(step) }
        return hasFired ? .consumed : .pass
    }

    /// `button` went down with `held` down now (it included). True if the press may do its own thing (pan, zoom);
    /// false while a step of this press is latched. A latch with no other gesture button down is stale (its
    /// release was lost, the window lost focus) and is dropped, so it cannot swallow this press.
    public mutating func press(_ button: MouseButtons, held: MouseButtons) -> Bool {
        if hasFired, held.subtracting(button).isDisjoint(with: Self.buttons) { buttonsReleased() }
        return !hasFired
    }

    /// `button` went up; `held` may still report it. With no other gesture button down, the press is over.
    public mutating func release(_ button: MouseButtons, held: MouseButtons) {
        if held.subtracting(button).isDisjoint(with: Self.buttons) { buttonsReleased() }
    }

    /// A precise scroll event made by the fingers (trackpad, Magic Mouse, smooth-scrolling wheel) while a button is
    /// held. Fires once the swipe's travel reaches `threshold` points horizontally and is more than twice its
    /// vertical travel, and the gap since the last step has passed; a mostly vertical swipe keeps accumulating, so
    /// turning horizontal later can still fire, and a swipe that reaches the threshold inside the gap fires on its
    /// first event after it. After a step the swipe is spent until it re-arms (see the type's doc).
    public mutating func scroll(dx: Double, dy: Double, began: Bool, threshold: Double, repeatAfter: Double,
                                at time: Double) -> Step? {
        let moved = dx != 0 || dy != 0
        defer { if moved { lastMove = time } }
        if spent || wayBack != nil {
            guard repeatAfter > 0 else { return nil }
            let rested = moved && lastMove.map { time - $0 >= repeatAfter } ?? false
            let back = lastStep.flatMap { last in
                [.next, .previous].contains(last.step) ? Self.step(dx).flatMap { $0 != last.step ? $0 : nil } : nil
            }
            if began || rested {
                rearm(wayBack: nil)
            } else if spent {
                guard let back else { return nil }
                rearm(wayBack: back)
            }
        }
        sumX += dx
        sumY += dy
        if let wayBack, let way = Self.step(sumX), way != wayBack {
            // Going the spent way again: the way back counts from where it turns.
            sumX = 0
            sumY = 0
            return nil
        }
        guard gapPassed(repeatAfter, at: time) else { return nil }
        if abs(sumX) >= threshold, abs(sumX) > Self.dominance * abs(sumY) { return fire(sumX, at: time) }
        if abs(sumY) >= threshold, abs(sumY) > Self.dominance * abs(sumX) {
            // Spent like a folder step; the way back stays a horizontal matter (`lastStep` is not a folder's).
            hasFired = true
            spent = true
            wayBack = nil
            lastStep = (time, sumY < 0 ? .up : .down)
            sumX = 0
            sumY = 0
            return lastStep!.step
        }
        return nil
    }

    /// A notched wheel event (no precise deltas) while a button is held: a mostly horizontal notch fires, the first
    /// one of the press at once and later ones once the gap since the last step has passed (inside it they are
    /// dropped). A notch is a single discrete step, so there is no threshold to reach; a vertical notch is not ours.
    public mutating func notch(dx: Double, dy: Double, repeatAfter: Double, at time: Double) -> Step? {
        guard dx != 0, abs(dx) > Self.dominance * abs(dy), gapPassed(repeatAfter, at: time) else { return nil }
        return fire(dx, at: time)
    }

    /// Every mouse button is up: the next press starts from nothing.
    public mutating func buttonsReleased() {
        sumX = 0
        sumY = 0
        hasFired = false
        lastStep = nil
        spent = false
        wayBack = nil
        lastMove = nil
    }

    /// A new swipe starts counting from nothing; `wayBack`: only that way counts.
    private mutating func rearm(wayBack: Step?) {
        spent = false
        self.wayBack = wayBack
        sumX = 0
        sumY = 0
    }

    /// Whether this press may step now: always before its first step; after it only with repeats on and the gap
    /// since the last step passed.
    private func gapPassed(_ repeatAfter: Double, at time: Double) -> Bool {
        guard let lastStep else { return true }
        return repeatAfter > 0 && time - lastStep.time >= repeatAfter
    }

    private static func step(_ dx: Double) -> Step? { dx < 0 ? .next : dx > 0 ? .previous : nil }

    private mutating func fire(_ dx: Double, at time: Double) -> Step {
        let step: Step = dx < 0 ? .next : .previous
        hasFired = true
        lastStep = (time, step)
        spent = true
        wayBack = nil
        sumX = 0
        sumY = 0
        return step
    }
}
