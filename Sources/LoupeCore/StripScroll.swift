/// Scrolling over the thumbnail strip (M2.5 spec §4.3, Photos' filmstrip 2026-10-21): a horizontal trackpad swipe
/// or a mouse drag moves the strip under its fixed centre, and the file that reaches the centre becomes the current
/// one, like a scrub; a vertical swipe does nothing (the photo under the strip does not pan), and a notched wheel steps
/// photos as everywhere. Pure: the strip feeds it the event's deltas and phases, and the controller draws the strip at
/// `offset` and acts on the outcome (`ViewerSession.scrub(to:)` for a new file; for a commit, settles the strip on
/// `settled(layout:)` and ends the scrub).
///
/// `offset` is the base x (`StripScrollLayout`) under the strip's centre while the strip moves, nil while it follows
/// the current file. It starts at the current file's centre — again whenever the current file is not the one reached
/// last (a key or the wheel moved it) — and moves point for point with the fingers or the cursor. Past the first or
/// last file a trackpad pulls it on at `rubberBand` of the travel (and back the same way); a mouse stops there, so
/// turning back moves at once.
///
/// Direction (`strip-scroll-direction`): `natural` (the default) takes fingers moving left to the next files, as the
/// three-finger swipe does: the strip is content that follows the fingers. `reversed` moves the other way. `fingerDX`
/// is the fingers' own movement, whatever "natural scrolling" says (`FingerDirection`). A mouse drag always carries the
/// strip with the cursor.
///
/// A gesture's axis is decided once from its first `lockDistance` points of travel, and its momentum keeps it, so a
/// slightly diagonal swipe neither stutters nor pans; events without phases (no gesture to belong to) are classified
/// one by one. Momentum (the system's; there is none of our own) carries the strip on, like a flick, and its end
/// commits. The fingers' own `.ended` does not commit: the momentum that may follow begins up to ~100 ms later (the
/// wait Chromium allows between the two), so a rest of `restDelay` without events commits a lift without momentum.
///
/// The strip moves (`isMoving`) from its first travel to the commit: the end of the momentum or a cancelled gesture
/// (`Outcome.commit`), the rest (`rested(now:)` once `restDeadline` has passed; every event puts it off, so the
/// controller keeps one timer and re-arms it when it wakes early), or `end()` (the window resigned key, full screen).
/// The scrub is on (`isScrubbing`) from the first new file to that commit. A press on the cells takes over
/// (`takeOver()`): the rest of the gesture's momentum does nothing. `settle()` once the strip sits on a file again
/// hands it back to the current file. Times are seconds on the caller's clock.
public struct StripScroll: Sendable {
    /// Where the strip sends a scroll event.
    public enum Route: Sendable, Equatable {
        /// The viewer's, as before the strip had a scroll of its own: a notched wheel steps photos, a scroll with a
        /// folder-gesture button held steps folders (`FolderScrollGesture`).
        case viewer
        /// The strip's: a horizontal gesture scrubs, a vertical one is ignored.
        case strip
        /// Nobody's. During the strip's own press (scrub, resize), which owns the selection until its release: unlike
        /// before Task 20, such a scroll no longer pans the photo either, since the press is the strip's gesture. And the
        /// rest of a gesture the viewer's guard has spent (`spent`).
        case ignore
    }

    /// What the controller does after an event.
    public struct Outcome: Sendable, Equatable {
        /// A file the selection reached that it was not on before: scrub to it.
        public var file: Int?
        /// The scrub was on and the gesture's momentum ended, or the gesture was cancelled: commit now rather than
        /// after the rest.
        public var commit: Bool

        public init(file: Int?, commit: Bool) {
            self.file = file
            self.commit = commit
        }
    }

    /// Travel (points, on either axis) after which a gesture's axis is decided.
    public static let lockDistance = 4.0
    /// Seconds without a scroll event that commit the scrub: the mouse scrub's rest (`ViewerSession.dwellDelay`).
    public static let restDelay = 0.15

    public var direction = StripScrollDirection.natural
    /// From the first new file the strip brings to the centre to the commit.
    public private(set) var isScrubbing = false
    /// When the rest commits, while the strip moves.
    public private(set) var restDeadline: Double?
    /// The base x under the strip's centre while the strip moves or settles; nil: it follows the current file.
    public var offset: Double? { raw.map(shown) }
    /// A gesture, its momentum or a drag moves the strip.
    public private(set) var isMoving = false

    /// How far a trackpad pulls the strip on past its first or last file, as a share of the travel.
    public static let rubberBand = 0.3

    private enum Axis { case horizontal, vertical }

    /// The gesture's axis, nil until decided (or without a gesture).
    private var axis: Axis?
    /// Travel of the gesture so far, while its axis is still open.
    private var openX = 0.0, openY = 0.0
    /// The offset the travel adds up to, before the rubber band; nil while the strip follows the current file.
    private var raw: Double?
    /// The offset range of the layout `raw` was last moved on (the rubber band's ends).
    private var range: ClosedRange<Double> = 0...0
    /// The file at the centre: the last one reported, or the anchor.
    private var file: Int?
    /// A press took over: the rest of the gesture's momentum is ignored until a new gesture begins.
    private var ignoresMomentum = false

    public init() {}

    /// Precise scrolling with no folder-gesture button held is the strip's. A held button belongs to the folder
    /// gesture as anywhere in the window, except during the strip's own press, which the gesture leaves alone too.
    /// `spent`: the viewer's scroll guard says the rest of this gesture does nothing (a folder step or a three-finger
    /// swipe fired during it, so its fingers and coast go on after the click is let go; or three fingers are down).
    /// Asked only for a scroll that would be the strip's, since asking feeds the guard (it must see every such gesture
    /// begin, to drop its latch).
    public static func route(precise: Bool, held: MouseButtons, folderGesture: Bool, pressed: Bool,
                             spent: @autoclosure () -> Bool) -> Route {
        guard precise else { return .viewer }
        if pressed { return .ignore }
        if folderGesture, !held.isDisjoint(with: FolderScrollGesture.triggers(precise: true)) { return .viewer }
        return spent() ? .ignore : .strip
    }

    /// One precise scroll event over the strip. `fingerDX`: the fingers' horizontal movement in points (negative =
    /// left); `dy`: the vertical delta (only its size matters). `current`: the session's current file; `now`: the
    /// event's time.
    public mutating func event(fingerDX: Double, dy: Double, phase: ScrollPhase, momentum: ScrollPhase,
                               layout: StripScrollLayout, current: Int, now: Double) -> Outcome {
        let ends = momentum.contains(.ended) || momentum.contains(.cancelled) || phase.contains(.cancelled)
        if momentum.isEmpty, phase.contains(.began) || phase.contains(.mayBegin) { ignoresMomentum = false }
        if ignoresMomentum, !momentum.isEmpty { return Outcome(file: nil, commit: false) }
        var outcome = Outcome(file: nil, commit: false)
        if let travel = travel(fingerDX: fingerDX, dy: dy, phase: phase, momentum: momentum), travel != 0 {
            outcome.file = move(by: direction == .natural ? -travel : travel, rubber: true, layout: layout,
                                current: current)
        }
        guard isMoving else { return outcome }
        if ends {
            outcome.commit = true
            takeOver()
        } else {
            restDeadline = now + Self.restDelay
        }
        return outcome
    }

    /// A mouse drag over the strip moved by `dx` points: the strip follows the cursor, up to its ends.
    public mutating func drag(by dx: Double, layout: StripScrollLayout, current: Int) -> Outcome {
        Outcome(file: move(by: -dx, rubber: false, layout: layout, current: current), commit: false)
    }

    /// Where the strip comes to rest: the file nearest the centre and the offset that centres it; nil while it
    /// follows the current file.
    public func settled(layout: StripScrollLayout) -> (file: Int, offset: Double)? {
        guard let offset, let file = layout.file(atBase: offset) else { return nil }
        return (file, layout.centre(of: file))
    }

    /// The strip sits on a file again: it follows the current file from now on.
    public mutating func settle() {
        raw = nil
        file = nil
        isMoving = false
        isScrubbing = false
        restDeadline = nil
    }

    /// The layout changed (the folder grew, aspects arrived, a resize) while the strip moves or settles: it stays on
    /// `file`, at that file's centre in the new layout.
    public mutating func layoutChanged(keeping file: Int, layout: StripScrollLayout) {
        guard raw != nil, layout.fileCount > 0 else { return }
        let file = min(max(file, 0), layout.fileCount - 1)
        range = layout.offsetRange
        raw = layout.centre(of: file)
        self.file = file
    }

    /// The rest timer woke: true (and the motion is over) once `restDeadline` has passed.
    public mutating func rested(now: Double) -> Bool {
        guard isMoving, let restDeadline, now >= restDeadline else { return false }
        takeOver()
        return true
    }

    /// A press on the cells took over (or the motion committed): nothing is left to commit, and the rest of the
    /// gesture's momentum does nothing.
    public mutating func takeOver() {
        isMoving = false
        isScrubbing = false
        restDeadline = nil
        ignoresMomentum = true
    }

    /// The scrub must commit now (the window resigned key, full screen): true when one was on.
    public mutating func end() -> Bool {
        defer { takeOver() }
        return isScrubbing
    }

    /// The horizontal travel of this event, nil while it adds none (vertical, or axis still open).
    private mutating func travel(fingerDX: Double, dy: Double, phase: ScrollPhase, momentum: ScrollPhase) -> Double? {
        if phase.isEmpty, momentum.isEmpty {
            // No gesture: this event alone.
            axis = nil
            return abs(fingerDX) > abs(dy) ? fingerDX : nil
        }
        if momentum.isEmpty, phase.contains(.began) || phase.contains(.mayBegin) {
            axis = nil
            openX = 0
            openY = 0
        }
        switch axis {
        case .horizontal: return fingerDX
        case .vertical: return nil
        case nil:
            // Momentum of a gesture whose start was not seen here: this event alone.
            if !momentum.isEmpty { return abs(fingerDX) > abs(dy) ? fingerDX : nil }
            openX += fingerDX
            openY += dy
            guard max(abs(openX), abs(openY)) >= Self.lockDistance else { return nil }
            axis = abs(openX) > abs(openY) ? .horizontal : .vertical
            return axis == .horizontal ? openX : nil
        }
    }

    /// Moves the strip's offset by `dx` points; the new file at the centre, if it is one.
    private mutating func move(by dx: Double, rubber: Bool, layout: StripScrollLayout, current: Int) -> Int? {
        guard layout.fileCount > 1, (0..<layout.fileCount).contains(current) else { return nil }
        range = layout.offsetRange
        // Anchored on the current file, again whenever it is not the one reached last (a key or the wheel moved it).
        if raw == nil || file != current {
            raw = layout.centre(of: current)
            file = current
        }
        var moved = raw! + dx
        if !rubber { moved = min(max(moved, range.lowerBound), range.upperBound) }
        raw = moved
        isMoving = true
        guard let reached = layout.file(atBase: shown(moved)), reached != file else { return nil }
        file = reached
        isScrubbing = true
        return reached
    }

    /// `raw` with the rubber band past the ends.
    private func shown(_ raw: Double) -> Double {
        if raw < range.lowerBound { return range.lowerBound - (range.lowerBound - raw) * Self.rubberBand }
        if raw > range.upperBound { return range.upperBound + (raw - range.upperBound) * Self.rubberBand }
        return raw
    }
}
