import Foundation

/// Press recognition for the mouse buttons `input.conf` binds (spec §3.2–§3.3): a pure state machine with injected
/// time. The caller feeds it presses, releases, wheel / thumb-wheel / mouse movement and timer ticks; it answers with
/// the inputs that fired (`MX_PANEL`, `MX_PANEL-long`, `MX_PANEL+WHEEL` with a step count, …).
///
/// `kinds` says which press kinds each button has a binding for; events a held button has no binding for are not
/// consumed. Nothing here touches AppKit or a timer: `ViewerView` arms a timer for `nextDeadline` and calls `tick`.
public struct ButtonGestures: Sendable {
    /// One recognised input. `steps` is 1 for tap / long / withRight and ±n for wheel, thumb-wheel and move
    /// (positive = up / right).
    public struct Fire: Equatable, Sendable {
        public let button: MouseButton
        public let kind: PressKind
        public let steps: Int
        public init(button: MouseButton, kind: PressKind, steps: Int) {
            self.button = button
            self.kind = kind
            self.steps = steps
        }
    }

    /// Cumulative travel, in points, on either axis that turns a press into a gesture (cancels tap and long press): for
    /// the right button (its drag zooms) and a button with a `+MOVE` binding, whose movement is its binding.
    public static let cancelPoints = 4.0
    /// The same for a button without a `+MOVE` binding (M4c spec §12.2): a press that travelled this far was a drag,
    /// not a press. Twice `cancelPoints`: such a button's movement means nothing to Loupe, so plain jitter while
    /// pressing and holding gets more room, while Mac Mouse Fix's button + drag (Spaces, the swipe), which Loupe also
    /// hears when it watches the side buttons, travels far more and cancels the tap, the long press and the armed tick.
    public static let driftPoints = 8.0
    /// A wheel gap of this many seconds ends the absorption that follows a released scroll.
    public static let absorbGap = 0.25
    /// Precise (smooth-scroll, trackpad) wheel points per step.
    public static let preciseWheelPoints = 12.0
    /// A thumb-wheel step is `stepsPerRevolution / thumbStepsPerRevolution` units (about 15 degrees).
    public static let thumbStepsPerRevolution = 24.0

    private struct Press {
        let seq: Int
        /// When a long press fires: always compared as `t >= deadline`, never as a difference of times.
        let deadline: Double
        /// Wheel step, travel past `cancelPoints` / `driftPoints` or a long press happened: the release does not tap.
        var cancelled = false
        var longFired = false
        /// The deadline passed on a long-on-release press that could still count: the "release now" haptic played.
        var armed = false
        /// A chord (`withRight`) press: it already fired and takes no part in anything else.
        var dead = false
        var wheel = 0.0
        var thumb = 0.0
        var moveX = 0.0
        var moveY = 0.0
    }

    private let kinds: [MouseButton: Set<PressKind>]
    private let longPress: Double
    private let moveStep: Double
    private var presses: [MouseButton: Press] = [:]
    private var sequence = 0
    /// Wheel events keep being swallowed after a release that ended a scroll (see `wheel`).
    private var absorbing = false
    private var lastAbsorbed = 0.0
    /// The right button is down, as far as its presses and releases say (a release lost while the app was in the
    /// background leaves it set: the caller checks the real buttons).
    public private(set) var rightHeld = false
    private var rightMoveX = 0.0
    private var rightMoveY = 0.0
    private var rightMoved = false

    /// After a right+X chord, until right is released: the right-button drag must not zoom.
    public private(set) var rightZoomSuppressed = false
    /// The right button moved at least `cancelPoints` on either axis since its press; sticky until it is released.
    public var rightDragged: Bool { rightHeld && rightMoved }

    /// `longPress` in seconds, `moveStep` in points.
    public init(kinds: [MouseButton: Set<PressKind>], longPress: Double, moveStep: Double) {
        self.kinds = kinds
        self.longPress = longPress
        self.moveStep = moveStep
    }

    private func has(_ b: MouseButton, _ kind: PressKind) -> Bool { kinds[b]?.contains(kind) ?? false }

    /// A tap that fires on the press itself: nothing else is bound to the button (besides the right chord).
    private func firesOnPress(_ b: MouseButton) -> Bool {
        has(b, .tap) && kinds[b, default: []].subtracting([.tap, .withRight]).isEmpty
    }

    private func fire(_ b: MouseButton, _ kind: PressKind, _ steps: Int = 1) -> Fire {
        Fire(button: b, kind: kind, steps: steps)
    }

    /// The held, live button with a binding for `kind` that was pressed last.
    private func target(_ kind: PressKind) -> MouseButton? {
        presses.filter { !$0.value.dead && has($0.key, kind) }.max { $0.value.seq < $1.value.seq }?.key
    }

    /// A long press is still possible: bound, and nothing cancelled it or fired it yet.
    private func longPossible(_ b: MouseButton, _ p: Press) -> Bool {
        has(b, .long) && !p.cancelled && !p.longFired && !p.dead
    }

    /// A button with a wheel / thumb-wheel / move binding fires its long press on release, not at the deadline: the
    /// hold usually means "now I will scroll", and a timer would toggle before the first step (spec §10.1).
    private func longOnRelease(_ b: MouseButton) -> Bool { has(b, .wheel) || has(b, .thumbWheel) || has(b, .move) }

    /// A long press the timer must fire at its deadline.
    private func isPending(_ b: MouseButton, _ p: Press) -> Bool { longPossible(b, p) && !longOnRelease(b) }

    /// A long-on-release press whose deadline has yet to be reported as `armed`: from then on a release counts as a
    /// long press, which is what the `haptic-long-armed` tick says (spec §11).
    private func awaitsArming(_ b: MouseButton, _ p: Press) -> Bool { longPossible(b, p) && longOnRelease(b) && !p.armed }

    public mutating func press(_ b: MouseButton, at t: Double) -> [Fire] {
        if b == .right {
            if !rightHeld { rightHeld = true; rightMoveX = 0; rightMoveY = 0; rightMoved = false }
            return []
        }
        let own = kinds[b, default: []]
        guard presses[b] == nil, !own.isEmpty else { return [] }
        sequence += 1
        var p = Press(seq: sequence, deadline: t + longPress)
        if own.contains(.withRight), rightHeld, !rightDragged {
            p.dead = true
            presses[b] = p
            rightZoomSuppressed = true
            return [fire(b, .withRight)]
        }
        if firesOnPress(b) {
            p.cancelled = true
            presses[b] = p
            return [fire(b, .tap)]
        }
        presses[b] = p
        return []
    }

    public mutating func release(_ b: MouseButton, at t: Double) -> [Fire] {
        if b == .right {
            rightHeld = false
            rightZoomSuppressed = false
            return []
        }
        guard let p = presses.removeValue(forKey: b) else { return [] }
        // A timer-driven long press whose timer ran late, or one that waits for the release.
        if longPossible(b, p), t >= p.deadline { return [fire(b, .long)] }
        if !p.cancelled, !p.dead, has(b, .tap) { return [fire(b, .tap)] }
        return []
    }

    /// Fires every long press that is due, once, and reports once each long-on-release press that has just become
    /// armed (`armed`, oldest press first): it fires nothing, the release does, and a wheel / move step before then
    /// means it never arms. Not an input of the map: the caller only plays the haptic.
    public mutating func tick(at t: Double) -> (fires: [Fire], armed: [MouseButton]) {
        var out: [(Int, Fire)] = []
        var armed: [(Int, MouseButton)] = []
        for (b, p) in presses where t >= p.deadline {
            if isPending(b, p) {
                presses[b]!.longFired = true
                presses[b]!.cancelled = true
                out.append((p.seq, fire(b, .long)))
            } else if awaitsArming(b, p) {
                presses[b]!.armed = true
                armed.append((p.seq, b))
            }
        }
        return (out.sorted { $0.0 < $1.0 }.map(\.1), armed.sorted { $0.0 < $1.0 }.map(\.1))
    }

    /// When the earliest long press needs the timer, or nil: one the timer fires, or a long-on-release one not yet
    /// armed (the timer only plays its haptic, the release still decides).
    public var nextDeadline: Double? {
        presses.filter { isPending($0.key, $0.value) || awaitsArming($0.key, $0.value) }.map(\.value.deadline).min()
    }

    /// A wheel event. `consumed` says the caller must not scroll / zoom with it. Click events (`precise == false`)
    /// step once per event; precise ones accumulate; momentum events never step. Once a held button has consumed a
    /// wheel event, the tail of that scroll (momentum or not) stays consumed after the button is released, until
    /// there is a gap of `absorbGap` seconds between events; then events pass through again.
    ///
    /// A wheel step with a vertical delta (not momentum) also cancels every held button without a `.wheel` binding (M4c
    /// spec §12.2), as travel past `driftPoints` does: back + wheel only scrolls the photos, it does not also step the
    /// stats on release. The event is not consumed for that.
    public mutating func wheel(dy: Double, precise: Bool, momentum: Bool,
                               at t: Double) -> (fires: [Fire], consumed: Bool) {
        if !momentum, dy != 0 {
            for b in Array(presses.keys) where !has(b, .wheel) { presses[b]!.cancelled = true }
        }
        guard let b = target(.wheel) else {
            guard absorbing else { return ([], false) }
            if t - lastAbsorbed >= Self.absorbGap { absorbing = false; return ([], false) }
            lastAbsorbed = t
            return ([], true)
        }
        // The momentum of a scroll that began before the press is eaten but leaves the press alive: a tap or a long
        // press made while a scroll still coasts must fire.
        if !momentum { presses[b]!.cancelled = true }
        absorbing = true
        lastAbsorbed = t
        guard dy != 0, !momentum else { return ([], true) }
        if !precise { return ([fire(b, .wheel, dy > 0 ? 1 : -1)], true) }
        presses[b]!.wheel += dy
        let steps = Int((presses[b]!.wheel / Self.preciseWheelPoints).rounded(.towardZero))
        presses[b]!.wheel -= Double(steps) * Self.preciseWheelPoints
        return (steps == 0 ? [] : [fire(b, .wheel, steps)], true)
    }

    /// A held button takes the thumb wheel (it has a `+MX_THUMB` binding); otherwise the wheel is free for
    /// `thumb-wheel-zoom`.
    public var thumbWheelTaken: Bool { target(.thumbWheel) != nil }

    /// The thumb wheel turned by `delta` units of `stepsPerRevolution` per turn (right = positive).
    public mutating func thumbWheel(delta: Int, stepsPerRevolution: Int) -> [Fire] {
        guard let b = target(.thumbWheel), stepsPerRevolution > 0 else { return [] }
        presses[b]!.cancelled = true
        let unit = Double(stepsPerRevolution) / Self.thumbStepsPerRevolution
        presses[b]!.thumb += Double(delta)
        let steps = Int((presses[b]!.thumb / unit).rounded(.towardZero))
        presses[b]!.thumb -= Double(steps) * unit
        return steps == 0 ? [] : [fire(b, .thumbWheel, steps)]
    }

    /// How far a held `b` may travel before its press is cancelled (see `driftPoints`).
    private func travelLimit(_ b: MouseButton) -> Double { has(b, .move) ? Self.cancelPoints : Self.driftPoints }

    /// Mouse movement in points, `dy > 0` = up. Travel on either axis since its own press cancels a held button's tap
    /// and long press: four points for a button with a `.move` binding, eight for the rest (`driftPoints`). Only a
    /// button with a `.move` binding steps, on the vertical travel since its own press.
    public mutating func move(dx: Double, dy: Double) -> [Fire] {
        if rightHeld {
            rightMoveX += dx
            rightMoveY += dy
            if max(abs(rightMoveX), abs(rightMoveY)) >= Self.cancelPoints { rightMoved = true }
        }
        for b in Array(presses.keys) {
            presses[b]!.moveX += dx
            presses[b]!.moveY += dy
            if max(abs(presses[b]!.moveX), abs(presses[b]!.moveY)) >= travelLimit(b) { presses[b]!.cancelled = true }
        }
        guard let b = target(.move), presses[b]!.cancelled, moveStep > 0 else { return [] }
        let steps = Int((presses[b]!.moveY / moveStep).rounded(.towardZero))
        guard steps != 0 else { return [] }
        presses[b]!.moveY -= Double(steps) * moveStep
        return [fire(b, .move, steps)]
    }

    /// Forgets the press of `b` without firing anything: its release was lost (`AppKitButtonFilter.lostReleases`).
    public mutating func drop(_ b: MouseButton) {
        presses.removeValue(forKey: b)
    }

    /// Forgets everything in flight: the app lost focus or the window went away mid-press.
    public mutating func cancelAll() {
        presses = [:]
        absorbing = false
        rightHeld = false
        rightMoveX = 0
        rightMoveY = 0
        rightMoved = false
        rightZoomSuppressed = false
    }
}
