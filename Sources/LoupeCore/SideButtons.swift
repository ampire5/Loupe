/// `mx-side-buttons` (M4c spec §12.1): how Loupe gets the MX Master's back and forward buttons. A mouse utility such as
/// Mac Mouse Fix takes them from the system before any app sees them, but the mouse still reports each press over
/// HID++ (analytics key events), and LogiMouse can listen to that without taking the button.
///
/// - `watch` (default): LogiMouse listens (`LogiMouse.watch`); the system and the utility still get the buttons. While
///   the mouse confirms the watch (`LogiMouse.watching`), AppKit's events of these buttons are dropped
///   (`AppKitButtonFilter`): they would double the press. Another mouse's back / forward are dropped with them then.
/// - `take`: LogiMouse diverts them (`LogiMouse.divert`): Loupe's alone while it is in front, AppKit sees none.
/// - `system`: AppKit's events only, as before §12.
public enum SideButtonsMode: String, Sendable, CaseIterable {
    case watch, take, system

    /// The control IDs to hand to `LogiMouse.watch`.
    public var watchedCIDs: Set<UInt16> { self == .watch ? Self.sideCIDs : [] }

    /// The control IDs to add to the diverted set (`LogiMouse.divert`).
    public var divertedCIDs: Set<UInt16> { self == .take ? Self.sideCIDs : [] }

    private static let sideCIDs = Set(MouseButton.allCases.compactMap(\.sideCID))
}

extension MouseButton {
    /// The LogiHIDPP control ID of a side button macOS reports itself (`MBTN_BACK` 0x53, `MBTN_FORWARD` 0x56), which
    /// LogiMouse can watch or take (`mx-side-buttons`); nil for the others. Kept apart from `cid`, the controls a
    /// binding diverts: the side buttons are diverted only by `mx-side-buttons=take`.
    public var sideCID: UInt16? {
        switch self {
        case .back: 0x53
        case .forward: 0x56
        default: nil
        }
    }

    /// The button a LogiMouse control ID stands for: an `MX_*` button by `cid`, a side button by `sideCID`.
    public init?(cid: UInt16) {
        guard let b = Self.allCases.first(where: { $0.cid == cid || $0.sideCID == cid }) else { return nil }
        self = b
    }
}

/// Which presses reach the button recogniser when the same side button can come two ways (M4c spec §12.1): as AppKit's
/// other-mouse events and as LogiMouse's events (watched or diverted).
///
/// - AppKit: a side button LogiMouse hears (its control ID in `heard`, i.e. `LogiMouse.watching`) comes from the
///   mouse's own events, so its AppKit press is dropped. A release goes where its press went: one whose press reached the
///   recogniser before the watch was confirmed still does (or the press would stay held), one whose press was dropped
///   stays dropped.
/// - LogiMouse: the watch can be confirmed by the very press it reports (or its reply comes after AppKit's events), so
///   AppKit's press may already have passed: a mouse press of a side button whose AppKit press passed less than
///   `duplicateWindow` ago, or is still held, is the same press and is dropped. A watched press also counts only while
///   the pointer is over one of Loupe's windows: the system delivers the button to the window under the pointer too,
///   and back over Finder must not also step Loupe's stats. A dropped mouse press drops its release. The `MX_*`
///   buttons (and a side button taken with `mx-side-buttons=take`) are diverted: they always pass.
public struct AppKitButtonFilter: Sendable {
    /// How long after AppKit's press of a side button the mouse's report of a press is taken for the same press.
    public static let duplicateWindow = 0.1

    /// The buttons AppKit pressed and whether each press was passed on.
    private var held: [MouseButton: Bool] = [:]
    /// When AppKit's last passed press of each side button came (NSEvent's clock).
    private var passedAt: [MouseButton: Double] = [:]
    /// The mouse presses dropped, whose releases are dropped too.
    private var mouseDropped: Set<MouseButton> = []

    public init() {}

    /// Whether an AppKit event of `b` is dropped right now: LogiMouse brings that button itself.
    public static func drops(_ b: MouseButton, heard: Set<UInt16>) -> Bool {
        b.sideCID.map(heard.contains) ?? false
    }

    /// An AppKit button down at `t` (NSEvent's clock): true when it goes to the recogniser.
    public mutating func down(_ b: MouseButton, heard: Set<UInt16>, at t: Double) -> Bool {
        let pass = !Self.drops(b, heard: heard)
        held[b] = pass
        if pass { passedAt[b] = t }
        return pass
    }

    /// An AppKit button up: true when it goes to the recogniser.
    public mutating func up(_ b: MouseButton, heard: Set<UInt16>) -> Bool {
        held.removeValue(forKey: b) ?? !Self.drops(b, heard: heard)
    }

    /// A press from LogiMouse's events at `t` (the same clock as `down`). `watched`: LogiMouse hears the button without
    /// taking it (the system gets it too); `overOwnWindow`: the pointer is over one of Loupe's windows. True when it
    /// goes to the recogniser.
    public mutating func mousePress(_ b: MouseButton, at t: Double, watched: Bool, overOwnWindow: Bool) -> Bool {
        var pass = true
        if b.sideCID != nil {
            let duplicate = held[b] == true || passedAt[b].map { t - $0 < Self.duplicateWindow } ?? false
            pass = !duplicate && (!watched || overOwnWindow)
        }
        if pass { mouseDropped.remove(b) } else { mouseDropped.insert(b) }
        return pass
    }

    /// A release from LogiMouse's events: true when it goes to the recogniser (its press did).
    public mutating func mouseRelease(_ b: MouseButton) -> Bool { mouseDropped.remove(b) == nil }

    /// Whether any passed AppKit press is still held here: when none is, `lostReleases` has nothing to report and the
    /// caller need not read `NSEvent.pressedMouseButtons`.
    public var hasHeld: Bool { held.values.contains(true) }

    /// The passed AppKit presses whose button is up in fact (`pressedButtons`: `NSEvent.pressedMouseButtons`, bit n for
    /// AppKit's button n): their release went where Loupe does not hear it (a tab that was switched away, another app's
    /// window). Each is reported once and forgotten here; the caller drops it from the recogniser, so a held button that
    /// is no longer held cannot take the plain wheel. LogiMouse's presses are not AppKit's and never show here.
    public mutating func lostReleases(pressedButtons: Int) -> [MouseButton] {
        let lost = [(MouseButton.middle, 2), (.back, 3), (.forward, 4)].filter { b, number in
            held[b] == true && pressedButtons & (1 << number) == 0
        }.map(\.0)
        for b in lost { held.removeValue(forKey: b) }
        return lost
    }

    /// Forgets the presses in flight (with the recogniser's `cancelAll`).
    public mutating func reset() {
        held = [:]
        passedAt = [:]
        mouseDropped = []
    }
}
