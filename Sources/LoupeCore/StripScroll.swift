/// Trackpad scrolling over the thumbnail strip (M2.5 spec §4.3): a horizontal swipe moves the selection like a
/// scrub, a vertical one does nothing (the photo under the strip does not pan), and a notched wheel steps photos as
/// everywhere. Pure: the strip feeds it the event's deltas and phases and the controller acts on the outcome
/// (`ViewerSession.scrub(to:)` for a new file, `endScrub()` for a commit).
///
/// The selection moves as a point along the strip's base layout, a cell's width of finger travel per cell: one file
/// per cell while there is a cell per file, the cell's range of files (linearly, as `StripLayout.fileIndex(atX:)`)
/// in a sampled strip. It starts at the centre of the current file's slot and is held within the cells like a
/// scroll bar's thumb, so turning back at an end moves it at once.
///
/// Direction (`strip-scroll-direction`): `natural` (the default) takes fingers moving left to the next files, as the
/// three-finger swipe does: the strip is content under the selection that follows
/// the fingers. `reversed` moves the selection with them. `fingerDX` is the fingers' own movement, whatever "natural
/// scrolling" says (`FingerDirection`).
///
/// A gesture's axis is decided once from its first `lockDistance` points of travel, and its momentum keeps it, so a
/// slightly diagonal swipe neither stutters nor pans; events without phases (no gesture to belong to) are classified
/// one by one. Momentum carries the scrub on, like a flick, and its end commits. The fingers' own `.ended` does not
/// commit: the momentum that may follow begins up to ~100 ms later (the wait Chromium allows between the two), so a
/// rest of `restDelay` without events commits a lift without momentum.
///
/// The scrub is on (`isScrubbing`) from the first new file to its commit: the end of the momentum or a cancelled
/// gesture (`Outcome.commit`), the rest (`rested(now:)` once `restDeadline` has passed; every event puts it off, so the
/// controller keeps one timer and re-arms it when it wakes early), or `end()` (the window resigned key, full screen).
/// A press on the cells takes it over (`takeOver()`): the session's scrub goes on under the press, whose release
/// commits it. Times are seconds on the caller's clock.
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
    /// From the first new file the selection reaches to the commit.
    public private(set) var isScrubbing = false
    /// When the rest commits the scrub, while it is on.
    public private(set) var restDeadline: Double?

    private enum Axis { case horizontal, vertical }

    /// The gesture's axis, nil until decided (or without a gesture).
    private var axis: Axis?
    /// Travel of the gesture so far, while its axis is still open.
    private var openX = 0.0, openY = 0.0
    /// The selection's x in the base layout, nil until anchored on the current file.
    private var x: Double?
    /// The file at `x`: the last one reported, or the anchor.
    private var file: Int?

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
                               layout: StripLayout, current: Int, now: Double) -> Outcome {
        let ends = momentum.contains(.ended) || momentum.contains(.cancelled) || phase.contains(.cancelled)
        var outcome = Outcome(file: selection(fingerDX: fingerDX, dy: dy, phase: phase, momentum: momentum,
                                              layout: layout, current: current), commit: false)
        if outcome.file != nil { isScrubbing = true }
        guard isScrubbing else { return outcome }
        if ends {
            outcome.commit = true
            takeOver()
        } else {
            restDeadline = now + Self.restDelay
        }
        return outcome
    }

    /// The rest timer woke: true (and the scrub is over) once `restDeadline` has passed.
    public mutating func rested(now: Double) -> Bool {
        guard isScrubbing, let restDeadline, now >= restDeadline else { return false }
        takeOver()
        return true
    }

    /// A press on the cells took the session's scrub over: this one has nothing left to commit.
    public mutating func takeOver() {
        isScrubbing = false
        restDeadline = nil
    }

    /// The scrub must commit now (the window resigned key, full screen): true when one was on.
    public mutating func end() -> Bool {
        defer { takeOver() }
        return isScrubbing
    }

    /// The new file the event takes the selection to, if any.
    private mutating func selection(fingerDX: Double, dy: Double, phase: ScrollPhase, momentum: ScrollPhase,
                                    layout: StripLayout, current: Int) -> Int? {
        let travel: Double?
        if phase.isEmpty, momentum.isEmpty {
            // No gesture: this event alone.
            axis = nil
            travel = abs(fingerDX) > abs(dy) ? fingerDX : nil
        } else {
            if momentum.isEmpty, phase.contains(.began) || phase.contains(.mayBegin) {
                axis = nil
                openX = 0
                openY = 0
                x = nil   // a new gesture starts from the current photo
            }
            travel = horizontalTravel(fingerDX, dy, momentum: !momentum.isEmpty)
        }
        guard let travel, travel != 0 else { return nil }
        return move(by: direction == .natural ? -travel : travel, layout: layout, current: current)
    }

    /// The layout changed (new aspects, a resize, another playlist): the selection's x means something else now, so
    /// the next event starts again from the current file.
    public mutating func layoutChanged() { x = nil }

    /// The horizontal travel this event adds to the gesture, nil while it adds none (vertical, or axis still open).
    private mutating func horizontalTravel(_ dx: Double, _ dy: Double, momentum: Bool) -> Double? {
        switch axis {
        case .horizontal: return dx
        case .vertical: return nil
        case nil:
            // Momentum of a gesture whose start was not seen here: this event alone.
            if momentum { return abs(dx) > abs(dy) ? dx : nil }
            openX += dx
            openY += dy
            guard max(abs(openX), abs(openY)) >= Self.lockDistance else { return nil }
            axis = abs(openX) > abs(openY) ? .horizontal : .vertical
            return axis == .horizontal ? openX : nil
        }
    }

    /// Moves the selection by `dx` points along the strip; the new file, if it is one.
    private mutating func move(by dx: Double, layout: StripLayout, current: Int) -> Int? {
        guard !layout.cells.isEmpty, (0..<layout.fileCount).contains(current) else { return nil }
        // Anchored on the current file, again whenever it is not the one reached last (a key or a click moved it).
        if x == nil || file != current {
            x = layout.x(ofFile: current)
            file = current
        }
        let low = layout.originX, high = (layout.originX + layout.span).nextDown
        let moved = min(max(x! + dx, low), high)
        x = moved
        guard let reached = layout.fileIndex(atX: moved), reached != file else { return nil }
        file = reached
        return reached
    }
}
