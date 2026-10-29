import AppKit
import HomeScreenKit
import LoupeCore

/// The bridge between the mouse buttons `input.conf` binds and the viewer (M4c spec §3, §8): AppKit's button events
/// and LogiMouse's (`AppDelegate`) go into one `ButtonGestures`, and what fires goes to the key window's viewer
/// (`ViewerView.performMouse`). It also owns the long-press timer, armed at the recogniser's `nextDeadline` after every
/// call, and answers whether a wheel event belongs to a held button (`wheel`) and whether the right button may zoom
/// (`rightZoomSuppressed`).
///
/// One clock throughout: NSEvent timestamps and `ProcessInfo.systemUptime` (the timer's ticks) are the same uptime.
/// Everything in flight is forgotten when the app resigns active and when a viewer window resigns key or closes
/// (`cancelAll`): a release that never arrives must not leave a long press to fire, the wheel absorbed or the right
/// button's zoom suppressed.
@MainActor final class MouseButtons {
    static let shared = MouseButtons()

    /// The viewer that fired inputs go to: the key window's, like the keys.
    /// None while Home (Recent or Stash) covers the viewer (Home spec §2.1): buttons, wheels and the thumb wheel must
    /// not act on a photo nobody sees; the cards and the page have the system's own events.
    var target: () -> ViewerView? = {
        guard let controller = NSApp.keyWindow?.windowController as? ViewerWindowController,
              !controller.isShowingHome else { return nil }
        return controller.viewerView
    }

    /// The Folders tab of the key window while it covers the viewer: a click of the back and forward buttons is its
    /// Back and Forward there (file browser spec §3.1), whatever the layout binds them to on a photo.
    var browser: () -> HomeBrowserView? = {
        (NSApp.keyWindow?.windowController as? ViewerWindowController)?.browserView
    }

    /// The side buttons' control IDs LogiMouse hears itself right now (`LogiMouse.watching`, set by `AppDelegate`):
    /// their AppKit events are dropped (`AppKitButtonFilter`, M4c spec §12.1). Empty without a Logitech mouse.
    var heardSideButtons: () -> Set<UInt16> = { [] }
    private var appKitFilter = AppKitButtonFilter()
    private var moveMonitor: Any?

    private var gestures: ButtonGestures
    /// The layout and timings `gestures` was made from; a reload that changes none of them keeps a press alive.
    private var source: Source
    private var timer: Timer?
    private var armedDeadline: Double?

    private struct Source: Equatable {
        let map: InputMap
        let longPressMilliseconds: Int
        let moveStep: Double

        @MainActor static var current: Source {
            let config = Settings.shared.config
            return Source(map: Settings.shared.inputMap, longPressMilliseconds: config.mouseLongPressMilliseconds,
                          moveStep: config.mouseMoveStep)
        }

        var gestures: ButtonGestures {
            let kinds = Dictionary(uniqueKeysWithValues: MouseButton.allCases.map { ($0, map.kinds(of: $0)) })
            return ButtonGestures(kinds: kinds, longPress: Double(longPressMilliseconds) / 1000, moveStep: moveStep)
        }
    }

    private init() {
        source = .current
        gestures = source.gestures
        let center = NotificationCenter.default
        center.addObserver(forName: .settingsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MouseButtons.shared.rebuild() }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MouseButtons.shared.cancelAll() }
        }
        // MouseService turned a held back button into a swipe (Spaces, Mission Control, App Exposé): the press is the
        // system's gesture, not ours. Its release would be a click otherwise, as the moves stop coming once Mission
        // Control takes the pointer.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.mouseservice.swipeBegan"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MouseButtons.shared.cancelAll() }
        }
        // Every mouse-moved event the app gets, wherever the pointer is (the picture, the info panel, the strip),
        // counts once towards a held button's travel (M4c spec §12.2): a Logitech button diverted or watched while a
        // utility has the button (Mac Mouse Fix's button + drag freezes the cursor, the deltas still come) brings
        // moves, not drags. Drags keep coming from the views (`moved`).
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            MainActor.assumeIsolated { MouseButtons.shared.moved(event) }
            return event
        }
    }

    /// After a reload: a new recogniser from the layout and `mouse-long-press` / `mouse-move-step`, presses in flight
    /// dropped. A reload that changed none of them (any other key, the app becoming active) leaves everything as it is.
    func rebuild() {
        let now = Source.current
        guard now != source else { return }
        source = now
        gestures = now.gestures
        DebugLog.log("mouse buttons: layout or timings changed, presses dropped")
        rearm()
    }

    /// `t` on NSEvent's clock (`systemUptime`). A right button the recogniser holds that is up in fact (its release was
    /// lost: let go over another app's window, a drag that ended outside) is released first, so it chords nothing.
    func press(_ b: MouseButton, at t: TimeInterval) {
        if b != .right, gestures.rightHeld, NSEvent.pressedMouseButtons & 2 == 0 {
            DebugLog.log("mouse buttons: right button up without a release, released")
            dispatch(gestures.release(.right, at: t), at: t)
        }
        dispatch(gestures.press(b, at: t), at: t)
    }

    func release(_ b: MouseButton, at t: TimeInterval) {
        dispatch(gestures.release(b, at: t), at: t)
    }

    /// `MBTN_MID` / `MBTN_BACK` / `MBTN_FORWARD` by AppKit's button number (2, 3, 4); other numbers are not bound.
    static func button(_ number: Int) -> MouseButton? {
        switch number {
        case 2: .middle
        case 3: .back
        case 4: .forward
        default: nil
        }
    }

    // AppKit's other-mouse events, for every view that takes them (the viewer, the info panel, the strip): the button
    // goes to the recogniser by its number, on the event's clock, unless LogiMouse brings that side button itself
    // (`mx-side-buttons=watch`, M4c spec §12.1): then the event is dropped (and still taken). False when the number is
    // not a bound button.

    @discardableResult
    func otherMouseDown(_ event: NSEvent) -> Bool {
        guard let b = Self.button(event.buttonNumber) else { return false }
        if appKitFilter.down(b, heard: heardSideButtons(), at: event.timestamp) {
            press(b, at: event.timestamp)
        } else {
            DebugLog.log("mouse button \(event.buttonNumber) down: the mouse's own event brings it, dropped")
        }
        return true
    }

    @discardableResult
    func otherMouseUp(_ event: NSEvent) -> Bool {
        guard let b = Self.button(event.buttonNumber) else { return false }
        if appKitFilter.up(b, heard: heardSideButtons()) { release(b, at: event.timestamp) }
        return true
    }

    /// `otherMouseDown` (`down`) or `otherMouseUp`, for a view that hands both to one closure
    /// (`FilmstripView.onOtherMouse`).
    func otherMouse(_ event: NSEvent, down: Bool) -> Bool {
        down ? otherMouseDown(event) : otherMouseUp(event)
    }

    // LogiMouse's buttons (`AppDelegate`), at `t` on NSEvent's clock. `watched`: LogiMouse hears the button without
    // taking it (`mx-side-buttons=watch`), so the system delivers it too. A side button's press that AppKit already
    // brought, or a watched press with the pointer outside Loupe's windows, is dropped with its release (M4c spec
    // §12.1, `AppKitButtonFilter`).

    func mousePress(_ b: MouseButton, at t: TimeInterval, watched: Bool) {
        guard appKitFilter.mousePress(b, at: t, watched: watched, overOwnWindow: Self.pointerOverOwnWindow()) else {
            DebugLog.log("mouse button \(b.rawValue) from the mouse dropped (AppKit brought it, or not over Loupe)")
            return
        }
        press(b, at: t)
    }

    func mouseRelease(_ b: MouseButton, at t: TimeInterval) {
        if appKitFilter.mouseRelease(b) { release(b, at: t) }
    }

    /// Whether the window under the pointer is one of Loupe's (whatever app is in front of it otherwise).
    private static func pointerOverOwnWindow() -> Bool {
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return NSApp.windows.contains { $0.windowNumber == number }
    }

    /// The pointer's movement of a mouse event, for a held button's tap / long press (cancelled past 4 pt, or 8 pt
    /// without a `+MOVE` binding) and `+MOVE` bindings; up is positive there, while AppKit's `deltaY` grows downward.
    func moved(_ event: NSEvent) {
        guard event.deltaX != 0 || event.deltaY != 0 else { return }
        move(dx: event.deltaX, dy: -event.deltaY)
    }

    /// Whether a held button takes this wheel event (the caller must then neither scroll, zoom nor step with it).
    /// `dy` is the vertical delta as AppKit reports it (`scrollingDeltaY`, or `deltaY` for a notch), positive = up, so
    /// the direction follows the system's scrolling setting and any mouse utility, as `wheel-direction=content` does.
    /// A horizontal-only event (the side wheel, a sideways swipe) is never a held button's: it goes on (right + side
    /// wheel still steps folders while the panel is held) and leaves the press alive. Momentum is the exception: the
    /// tail of an absorbed gesture stays absorbed whichever way it happens to point.
    func wheel(_ event: NSEvent) -> Bool {
        let precise = event.hasPreciseScrollingDeltas
        let dy = precise ? event.scrollingDeltaY : event.deltaY
        let momentum = !event.momentumPhase.isEmpty
        if !momentum, dy == 0, (precise ? event.scrollingDeltaX : event.deltaX) != 0 { return false }
        dropLostReleases()
        let r = gestures.wheel(dy: dy, precise: precise, momentum: momentum, at: event.timestamp)
        dispatch(r.fires, at: event.timestamp)
        return r.consumed
    }

    /// The thumb wheel turned by `delta` units of `stepsPerRevolution` per turn (right = positive). False when no held
    /// button takes it: the viewer's `thumb-wheel-zoom` may.
    func thumbWheel(delta: Int, stepsPerRevolution: Int) -> Bool {
        dropLostReleases()
        guard gestures.thumbWheelTaken else { return false }
        dispatch(gestures.thumbWheel(delta: delta, stepsPerRevolution: stepsPerRevolution),
                 at: ProcessInfo.processInfo.systemUptime)
        return true
    }

    /// Mouse movement in points, `dy > 0` = up (AppKit's `deltaY` is positive downward: pass `-deltaY`).
    func move(dx: Double, dy: Double) {
        dropLostReleases()
        dispatch(gestures.move(dx: dx, dy: dy), at: ProcessInfo.processInfo.systemUptime)
    }

    /// A held AppKit button (middle, back, forward) that is up in fact loses its press before a wheel, thumb wheel or
    /// move is read: its release went to a view that no longer hears it (a tab step switched the tab under it, which
    /// keeps presses, `keepingPresses`), and without this every plain scroll would be the held button's. LogiMouse's
    /// buttons bring their own releases.
    private func dropLostReleases() {
        guard appKitFilter.hasHeld else { return }
        for b in appKitFilter.lostReleases(pressedButtons: NSEvent.pressedMouseButtons) {
            DebugLog.log("mouse button \(b.rawValue) up without a release, dropped")
            gestures.drop(b)
            rearm()
        }
    }

    /// True while a tab step (`next-tab` / `previous-tab`) selects another tab: the tab it leaves resigns key, and its
    /// `cancelAll` is skipped, so a held button's press goes on in the tab it lands on (the same recogniser, the same
    /// window frame) and its wheel steps on through the tabs.
    private(set) var keepsPresses = false

    func keepingPresses(_ body: () -> Void) {
        keepsPresses = true
        defer { keepsPresses = false }
        body()
    }

    /// Forgets every press in flight and the wheel absorption: the app lost focus or the window went away mid-press.
    func cancelAll() {
        gestures.cancelAll()
        appKitFilter.reset()
        rearm()
    }

    /// A right+button chord fired: until the right button is released, its drag must not zoom.
    var rightZoomSuppressed: Bool { gestures.rightZoomSuppressed }

    private func dispatch(_ fires: [ButtonGestures.Fire], at t: TimeInterval) {
        rearm()
        for fire in fires {
            // The Folders tab: its Back and Forward on a click (`BrowserButtons`), nothing else of the photo's layout.
            if let browser = browser() {
                switch BrowserButtons.action(fire.button, fire.kind) {
                case .back: browser.goBack()
                case .forward: browser.goForward()
                case nil: break
                }
                continue
            }
            guard let input = source.map.mouse(fire.button, fire.kind) else { continue }
            DebugLog.log("mouse input \(fire.button.rawValue) \(fire.kind) steps \(fire.steps) -> \(input)")
            let fresh = [.tap, .long, .withRight].contains(fire.kind)   // a press, not a held button's wheel / move
            target()?.performMouse(input, steps: fire.steps, fresh: fresh, at: t)
        }
    }

    /// A one-shot timer at the earliest pending long press, replaced whenever that moves.
    private func rearm() {
        let deadline = gestures.nextDeadline
        guard deadline != armedDeadline else { return }
        armedDeadline = deadline
        timer?.invalidate()
        timer = nil
        guard let deadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { MouseButtons.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        timer = nil
        armedDeadline = nil   // re-armed below if a press is still pending (a timer that came a hair early)
        let now = ProcessInfo.processInfo.systemUptime
        let due = gestures.tick(at: now)
        dispatch(due.fires, at: now)
        // Only a window that would take the long press ticks (no photo window: the release does nothing either).
        for b in due.armed where target() != nil {
            DebugLog.log("mouse button \(b.rawValue) armed: a release now is a long press")
            MouseHaptics.shared.longArmed()
        }
    }
}
