import AppKit
import LoupeCore
import LoupeRender
import QuartzCore

/// The photo surface: an `NSView` backed by a `CAMetalLayer` that a `RenderLoop` draws into off the
/// main thread. The view keeps the layer's drawable size and the session's view size equal (both in
/// physical pixels), and forwards every session change to the render loop.
///
/// Input (spec §8, M1 subset) lands here and is turned into `ViewTransform` changes in physical
/// pixels: trackpad scroll, drag and pinch move the picture, the mouse wheel and the keys step through
/// the folder; a three-finger horizontal swipe does too; the right button held and dragged vertically
/// zooms; a horizontal scroll with a button held steps to the next or previous folder (`FolderScrollGesture`).
/// Releasing a left-button drag glides on (`DragInertia`, `drag-inertia`), and so does the right-button zoom if
/// `rmb-zoom-inertia` is on (`ZoomInertia`). With `rubber-band`, a pan held past an image edge stretches and a release
/// or a glide into the edge springs back (`PanRubber`, M4a spec §2.1). Pinch and right-button zoom halt at
/// the configured zoom stops (`ZoomStopGesture`, spec §8.4); with `zoom-rubber-band` they stretch past the zoom limits
/// and spring back on release (M4b spec §3). Zoom keys and smart zoom animate (`ZoomAnimation`, `zoom-animation`, M4b
/// spec §2). Each change goes through `session.transform`, whose `onChange` reaches the render loop.
@MainActor final class ViewerView: NSView {
    let session: ViewerSession
    private var renderLoop: RenderLoop!
    /// The pan position pills, drawn over the window's content rather than in this view's frames: the window controller
    /// puts the view in its container (`PanIndicatorsView`); this view hands it what it hands the render loop.
    let panIndicatorsView = PanIndicatorsView()
    /// What was last handed to the render loop, so session changes that do not affect the picture
    /// (a load starting, the playlist arriving) do not wake the display link for an identical frame.
    private var shownImage: TiledImage?
    /// The photo `shownImage` is of (`session.entry`'s URL), nil without an image: a new image of the same photo (the
    /// decoded pyramid replacing a seeded thumbnail) is not a new photo (`imageDidChange`).
    private var shownPhoto: URL?
    /// `shownImage.revision` when handed over: a level arriving in (or evicted from) the same image redraws.
    private var shownRevision: Int?
    private var shownTransform: ViewTransform?
    /// The orientation `shownImage` was handed over with (`ViewerSession.drawOrientation`): `exif-orientation` toggled
    /// on a photo whose size it keeps (a half turn, a mirror) redraws.
    private var shownOrientation: ImageOrientation?
    /// The colour cube handed over with `shownImage`, and the fade into it (`ShownColor`); nil while no image is shown.
    private var shownColor: ShownColor<ColorLUT>?
    /// The same of the pair's other page (`session.companionImage`), and where the pages sit (`session.shownLayout`).
    private var shownCompanion: TiledImage?
    private var shownCompanionRevision: Int?
    private var shownCompanionOrientation: ImageOrientation?
    private var shownCompanionColor: ShownColor<ColorLUT>?
    private var shownLayout: SpreadLayout?
    /// The page of a pair under the pointer (0 the first in reading order, 1 the second), nil outside the pages or for
    /// one page: the info panel is about it (`onPointerPageChanged`).
    private(set) var pointerPage: Int?
    var onPointerPageChanged: (() -> Void)?
    /// Where the pointer last was over the view (view pixels), nil since it left: a pair laid out anew or moved under a
    /// still pointer finds its page from here.
    private var lastPointer: CGPoint?
    /// `d`, `⇧D`, `⌥D` pressed (`toggleSpread`, `saveSpread`, `shiftSpread`); the window controller owns the folder's
    /// spread values.
    var onSpreadKey: ((KeyAction) -> Bool)?
    /// `i` pressed; the window controller owns the stats bar.
    var onToggleStats: (() -> Void)?
    /// `t` pressed; the window controller owns the thumbnail strip.
    var onToggleStrip: (() -> Void)?
    var onToggleStripPlacement: (() -> Void)?
    /// `?` pressed, or a key pressed while the sheet is open; the window controller owns the cheat sheet.
    var onToggleCheatSheet: (() -> Void)?
    /// `s`, `⇧S`, `a`, `⇧A` pressed (`cycleFilter`, `saveFilters`, `toggleAntiring`, `saveAntiring`); the window
    /// controller owns the folder's scaling values. It answers whether the key did anything (false without a photo), as
    /// do the colour, zoom and pan indicator keys below: a toggle that did nothing gets no haptic.
    var onScalingKey: ((KeyAction) -> Bool)?
    /// `c`, `⇧C`, `v`, `⇧V` pressed (`toggleAutoColor`, `saveAutoColor`, `toggleVibrance`, `saveVibrance`); the window
    /// controller owns the folder's colour values.
    var onColourKey: ((KeyAction) -> Bool)?
    /// `l`, `⇧L` pressed (`toggleKeepZoom`, `saveKeepZoom`); the window controller owns the folder's zoom values.
    var onZoomKey: ((KeyAction) -> Bool)?
    /// `p`, `⇧P` pressed (`cyclePanIndicators`, `savePanIndicators`); the window controller tells `Settings` and toasts.
    var onPanIndicatorKey: ((KeyAction) -> Bool)?
    /// `toggle-info-panel` (an input.conf key or a mouse button); the window controller owns the info panel (⌘I).
    var onToggleInfoPanel: (() -> Void)?
    /// `new-tab`, `new-window`, `close-tab`, `next-tab`, `previous-tab` (an input.conf key or a mouse button); the window
    /// controller does what its menu items do.
    var onTabAction: ((KeyAction) -> Void)?
    /// Home is over the picture: no hand cursor from here (this view's tracking area hears moves under it too).
    var isCovered: () -> Bool = { false }
    /// The mouse moved over the picture or left it (the ‹ button's reveal zone, `BackButtonPolicy`).
    var onPointerMoved: (() -> Void)?
    /// An `add <key> <step>` binding fired (input.conf): the folder value `key` changes by `step` × `steps` (a key press
    /// and each of its repeats is one step; a wheel or a move may give several). The window controller owns the
    /// folder's values.
    var onAdjust: ((String, Double, Int) -> Void)?
    var isCheatSheetOpen: () -> Bool = { false }
    /// The key that closed the cheat sheet, while it is held: its auto-repeat must not go on to act (an arrow would
    /// step photos right after the sheet went).
    private var keyThatClosedSheet: UInt16?
    /// Cursor position (view pixels) at the previous drag event; nil outside a drag.
    private var dragPoint: CGPoint?
    /// The transform when the left button went down, for a folder step to put back what the drag did.
    private var dragStart: ViewTransform?
    /// Whether the thumbnail strip holds a press of its own (scrub, resize); the window controller owns the strip.
    var isStripPressed: () -> Bool = { false }
    /// Right-button zoom in progress (nil outside one), with the press point and whether the cursor has
    /// travelled far enough to count as a drag rather than a click.
    private var rmbZoom: RMBZoom?
    private var rmbPress: CGPoint?
    private var rmbDragging = false
    /// Zoom stops for the right-button zoom in progress, made at the press.
    private var rmbStops: ZoomStopGesture?
    /// Release velocity of the right-button zoom (doublings/s), and where the drag ended (cumulative travel, points).
    private var rmbVelocity = ZoomVelocityTracker()
    private var rmbDy = 0.0
    /// The mouse's haptics for the right-button zoom (its drag, then its coast); new at each right press.
    private var rmbBumps = ZoomBumps()
    /// Pinch in progress (phase began → ended): the stop rules, the scale the fingers alone ask for
    /// (accumulated from the gesture's start, so motion absorbed at a stop does not drift), and the
    /// transform it last set, to notice anything else changing the zoom meanwhile.
    private var pinch: Pinch?
    /// The thumb wheel's zoom gesture (`thumbWheelZoom`) and the transform it last showed.
    private var thumbZoom: (zoom: ThumbZoom, last: ViewTransform)?
    private struct Pinch { var stops: ZoomStopGesture; var proposed: Double; var last: ViewTransform }
    /// Three-finger swipe recogniser, fed from raw touches (see "Three-finger swipe" below).
    private var threeFingerSwipe = ThreeFingerSwipe()
    /// Fingers on the trackpad right now (from the touch events), and the scroll filter that uses it: it
    /// stops a three-finger swipe from panning, and remembers where the picture was when the current
    /// scroll gesture began so the swipe can undo what the two earlier fingers already did.
    private var touchCount = 0
    private var scrollGuard = ScrollGestureGuard<ScrollStart>()
    private struct ScrollStart { var center: CGPoint; var mode: ZoomMode }
    /// Left-drag release velocity (fed in `mouseDown`/`mouseDragged`) and the glide that follows it. The
    /// display link exists only while a coast runs, so an idle viewer costs nothing.
    private var dragVelocity = DragVelocityTracker()
    private var coast: InertiaCoast?
    /// The zoom glide after a right-button release (`rmb-zoom-inertia`); shares the pan coast's display link,
    /// and the two never run together (every press and input stops both).
    private var zoomCoast: RMBZoomCoast?
    /// A zoom key, smart zoom or the zoom rubber band's spring-back playing out (M4b spec §2); shares the coast's display
    /// link and runs alone (`animateZoom` stops the other motions, every gesture stops it). `session.zoomTarget` is its
    /// `to` while it runs; a target the session changed (`settleZoom`) means it is over. `zoomFrames` counts its frames
    /// for the debug log.
    private var zoomAnimation: ZoomAnimation?
    private var zoomFrames = 0
    private var inertiaLink: CADisplayLink?
    private var inertiaLastTimestamp: CFTimeInterval?
    /// The rubber-band edge (`rubber-band`): the stretch of a pan held past an image edge and the spring back. It runs
    /// on the coast's display link; only the trackpad pan, the left-button drag and their glides go through it.
    private var rubber = PanRubber(enabled: true)
    /// Notched-wheel limiter: one photo step per display frame, and none until the last step's photo is on screen
    /// as `wheel-step` asks (fed in `sessionDidChange`). Its display link is created on the first notch and paused
    /// whenever a frame passes without one, so an idle wheel costs nothing.
    private var wheelGate = StepGate()
    private var wheelLink: CADisplayLink?
    /// The keyboard's previous / next, fresh presses and auto-repeats alike: no per-frame limit (a held key always
    /// stepped at the repeat rate), but none until the last step's photo is on screen as `key-step` asks. Separate
    /// from the wheel's gate, so neither holds the other.
    private var keyGate = StepGate(oncePerFrame: false)
    /// `haptic-end`: one bump per push against an end of the folder, for previous / next by a wheel notch, a key or a
    /// mouse button (`folderEnd`); trackpad swipes and menu clicks do not vibrate the mouse.
    private var endBump = EndBump()
    /// The event time of the last wheel notch, stepped or dropped: a notch after `EndBump.wheelPause` is a new push.
    private var lastWheelNotch: TimeInterval?
    /// Horizontal scroll while a mouse button is held: one folder step per press (see "Folder step by a held
    /// button" below). Once it fired, the held button neither pans nor zooms until every button is up.
    private var folderScroll = FolderScrollGesture()
    /// Hides the cursor over the picture once the mouse rests (see "Cursor" below).
    private let cursorAutohide = CursorAutohide()
    /// The cursor last set over the picture, so session changes (every frame of a drag) set it only when
    /// the shape changes.
    private var shownCursor: NSCursor?

    private var metalLayer: CAMetalLayer {
        guard let layer = layer as? CAMetalLayer else { fatalError("ViewerView: backing layer is not a CAMetalLayer") }
        return layer
    }

    /// `resampling`: the window's filters (loupe.conf with its folder's values on top).
    init(session: ViewerSession, resampling: ResampleSettings) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true   // calls makeBackingLayer
        // Content comes only from the render loop; AppKit should never redraw (or clear) the layer itself.
        layerContentsRedrawPolicy = .never
        // During a live resize the last frame stays on screen until the render thread draws the new size.
        // Centred and unscaled matches how the transform anchors the image (view centre), instead of
        // stretching it. AppKit derives the layer's contentsGravity from this placement.
        layerContentsPlacement = .center
        renderLoop = RenderLoop(layer: metalLayer)
        setBackground(Settings.shared.config.background)
        setResampling(resampling)
        setTransparency(TransparencySettings(config: Settings.shared.config))
        setPanIndicators(Settings.shared)
        rubber.enabled = Settings.shared.config.rubberBand
        // Raw trackpad touches for the three-finger swipe. Delivering them does not take anything away
        // from scroll, magnify or mouse events, which AppKit keeps synthesising from the same fingers.
        allowedTouchTypes = [.indirect]
        cursorAutohide.canHide = { [unowned self] in isMouseOverPicture && NSEvent.pressedMouseButtons == 0 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MetalContext.shared.device
        layer.pixelFormat = .bgra8Unorm_srgb   // TileRenderer returns linear light; the _srgb target encodes it
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)   // until an image retags it (render thread)
        // The resampling kernel is a compute pass that writes the drawable (spec §3.3), which needs `.shaderWrite`.
        layer.framebufferOnly = false
        if let count = RenderTuning.current.drawableCount { layer.maximumDrawableCount = count }   // spec §6.1
        layer.isOpaque = true
        layer.backgroundColor = Settings.shared.config.background.cgColor
        layer.contentsGravity = .center
        return layer
    }

    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}   // drawn by RenderLoop

    /// Pushes the session's image, its orientation and the transform to the render thread when the image, its resident
    /// levels (`revision`), the orientation or the transform changed; called on every session change.
    func sessionDidChange() {
        stepGatesPhotoShown()
        let image = session.image, revision = image?.revision, orientation = session.drawOrientation
        // The cube of the photo whose pyramid this is (`entry`, which still is the previous photo's until the next one
        // qualifies), so image and cube are always one photo's. A cube arriving or changing later, or a running fade,
        // is a change like a new level: it is handed over with the image in the same update.
        let color: ShownColor<ColorLUT>? = image.flatMap { _ in session.entry?.url }.map { url in
            .next(shown: shownColor, url: url, cube: session.colorCube(for: url), now: CACurrentMediaTime(),
                  durationMs: Settings.shared.config.autoColorFadeMilliseconds)
        }
        // The pair's other page, with its own orientation and cube (spread spec, «Цвет»).
        let layout = session.shownLayout
        let companion = layout == nil ? nil : session.companionImage
        let companionRevision = companion?.revision, companionOrientation = session.companionDrawOrientation
        let companionColor: ShownColor<ColorLUT>? = companion.flatMap { _ in session.shownCompanion?.url }.map { url in
            .next(shown: shownCompanionColor, url: url, cube: session.colorCube(for: url), now: CACurrentMediaTime(),
                  durationMs: Settings.shared.config.autoColorFadeMilliseconds)
        }
        let changed = image !== shownImage || revision != shownRevision || session.transform != shownTransform
            || orientation != shownOrientation || color != shownColor
            || companion !== shownCompanion || companionRevision != shownCompanionRevision
            || companionOrientation != shownCompanionOrientation || companionColor != shownCompanionColor
            || layout != shownLayout
        if changed {
            if image !== shownImage {
                let photo = image.flatMap { _ in session.entry?.url }
                imageDidChange(samePhoto: photo != nil && photo == shownPhoto)
                shownPhoto = photo
            }
            shownImage = image
            shownRevision = revision
            shownTransform = session.transform
            shownOrientation = orientation
            shownColor = color
            shownCompanion = companion
            shownCompanionRevision = companionRevision
            shownCompanionOrientation = companionOrientation
            shownCompanionColor = companionColor
            shownLayout = layout
            let transform = session.transform
            let page = RenderPage(image: image, orientation: orientation, color: color,
                                  rect: CGRect(origin: .zero, size: transform.imageSize))
            if let layout, layout.rects.count == 2 {
                // Two pages, left to right on screen, each in its rect of the virtual picture the transform shows.
                let other = RenderPage(image: companion, orientation: companionOrientation, color: companionColor,
                                       rect: .zero)
                let reading = session.companionFirst ? (other, page) : (page, other)
                var left = layout.order[0] == 0 ? reading.0 : reading.1
                var right = layout.order[0] == 0 ? reading.1 : reading.0
                left.rect = layout.rects[0]
                right.rect = layout.rects[1]
                let pages = RenderPages(first: left, second: right)
                renderLoop.update(pages: pages, transform: transform)
                panIndicatorsView.show(pages, transform: transform)
            } else {
                // One page, the whole of the transform's image: drawn as a single photo always was.
                let pages = RenderPages(first: page)
                renderLoop.update(pages: pages, transform: transform)
                panIndicatorsView.show(pages, transform: transform)
            }
        }
        // After `update`: the first image clears the expected space only once the loop has the image, so no frame in
        // between draws the bare background retagged back to P3.
        renderLoop.expectColorSpace(session.incomingColorSpace)
        if changed {
            refreshCursor()
            // The picture moved under a still pointer: the page under it, told with this change (the window controller
            // brings the info panel up to date right after this call).
            pointerPage = lastPointer.flatMap(page(at:))
        }
    }

    /// A new image object on screen. Another photo (or none) stops every motion, a zoom animation at its target (spec
    /// §2.3; `show` already settled it). The same photo in a new image (the decoded pyramid replacing the seeded
    /// thumbnail a step or a strip jump showed) stops a glide, the right-button coast and a pan spring, but a running
    /// zoom animation goes on to the mode its key asked for, its frame (and a spring-back's stretch) kept: its tick
    /// drops it itself if the image or view size changed under it.
    private func imageDidChange(samePhoto: Bool) {
        guard samePhoto else { stopInertiaAtZoomTarget(); return }
        guard zoomAnimation != nil else { stopInertia(); return }
        coast = nil      // `animateZoom` already stopped these; the animation runs alone on the link
        zoomCoast = nil
        rubber.reset()
        DebugLog.log("image replaced for the same photo during a zoom animation: the animation goes on")
    }

    // MARK: Input

    /// Physical pixels per point of the window the view is in.
    private var backing: CGFloat { window?.backingScaleFactor ?? 1 }

    /// Event location in the transform's space: physical pixels, origin top-left, y down.
    private func viewPoint(_ event: NSEvent) -> CGPoint {
        let p = convertToBacking(convert(event.locationInWindow, from: nil))
        return CGPoint(x: p.x, y: session.transform.viewSize.height - p.y)
    }

    /// Trackpad (and Magic Mouse) scrolling pans, momentum included, so the system's inertia carries the
    /// picture. `scrollingDeltaY` already follows the "natural scrolling" setting: positive means the
    /// content moves down on screen, which is `panned(by:)` with +dy, so the picture follows the fingers.
    /// With `rubber-band` the fingers stretch the picture past an edge and lifting them springs it back; the
    /// momentum bounces off an edge it reaches and is ignored on that axis for the rest of the gesture; fingers
    /// landing during a spring catch it (`PanRubber`). Momentum events leave the spring running.
    /// While three or more fingers are down, or after a three-finger swipe fired, precise scroll is ignored
    /// (`ScrollGestureGuard`): the swipe's first two fingers would otherwise pan before it is recognised.
    /// A notched wheel steps through the folder instead, one photo per notch: wheel down = next. At most
    /// one step per display frame, and with `wheel-step` none until the photo stepped to is on screen at that
    /// quality or a second passed (`StepGate`); notches in between are dropped, so a fast spin slows down to
    /// the speed the photos show at instead of skipping them.
    /// First of all, a mouse button held with a `+WHEEL` binding (and the tail of its scroll) takes the wheel
    /// (`MouseButtons`): nothing then pans, zooms or steps.
    override func scrollWheel(with event: NSEvent) {
        if MouseButtons.shared.wheel(event) {
            if dragPoint == nil { releaseRubber() }   // a stretch of the fingers' gesture goes back, as for a folder step
            return
        }
        let phase = ScrollPhase(rawValue: event.phase.rawValue)
        let momentum = ScrollPhase(rawValue: event.momentumPhase.rawValue)
        if !event.hasPreciseScrollingDeltas {
            stopInertiaAtZoomTarget()     // a notch steps photos
        } else if momentum.isEmpty {
            stopInertia(catching: true)   // fingers on the pad catch a spring where it shows
        } else {
            // A zoom key pressed during the fingers' momentum took over: momentum events are ignored while the zoom
            // animation runs rather than fight it, and pan again once it is over.
            if zoomAnimation != nil { return }
            coast = nil                   // the momentum ends a glide, but not a spring of the fingers' gesture
            zoomCoast = nil
        }
        if folderScrollConsumed(event) {
            releaseRubber()   // the held-button gesture never pans: a stretch it caught goes back
            return
        }
        if event.hasPreciseScrollingDeltas {
            if phase.contains(.began) { rubber.beginGesture() }
            let fingersOff = momentum.isEmpty ? !phase.isDisjoint(with: [.ended, .cancelled])
                                              : !momentum.isDisjoint(with: [.ended, .cancelled])
            let t = session.transform
            guard scrollGuard.scroll(phase: phase, momentum: momentum,
                                     touches: touchCount, start: ScrollStart(center: t.center, mode: t.mode)) else {
                DebugLog.log("scroll ignored (touches \(touchCount))")
                if fingersOff { releaseRubber() }
                return
            }
            DebugLog.log("scroll pan \(event.scrollingDeltaX), \(event.scrollingDeltaY)\(momentum.isEmpty ? "" : " momentum")")
            let k = backing
            let delta = CGVector(dx: event.scrollingDeltaX * k, dy: event.scrollingDeltaY * k)
            if !momentum.isEmpty {
                // Every momentum event, an empty one too, so the next one's speed is over the gap from this one.
                let moved = rubber.momentum(delta, at: event.timestamp, on: session.transform)
                if moved != session.transform { session.transform = moved }
            } else if delta != .zero {
                if phase.isEmpty {
                    // A device without gesture phases never says its fingers lifted: it pans as before, never stretches.
                    session.transform = session.transform.panned(by: delta)
                } else {
                    session.transform = rubber.pan(by: delta, on: session.transform)
                }
            }
            // Fingers lifted (a spring of their stretch keeps going when the system's momentum follows), or the
            // momentum over; a bounce the momentum started runs on the link.
            if fingersOff { releaseRubber() } else if rubber.isAnimating { ensureInertiaLink() }
            return
        }
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        let down = Settings.shared.config.wheelDirection.isNext(deltaY: dy,
                                                                invertedFromDevice: event.isDirectionInvertedFromDevice)
        let fresh = EndBump.isFreshNotch(at: event.timestamp, previous: lastWheelNotch)
        lastWheelNotch = event.timestamp
        let waited = wheelGate.pending
        guard wheelGate.request(now: event.timestamp) else {
            if let waited, !wheelGate.isActive {
                DebugLog.log("wheel dy \(dy) dropped (waiting for \(waited.wait) of "
                             + "\(session.playlist?.current.lastPathComponent ?? "-"))")
            } else {
                DebugLog.log("wheel dy \(dy) dropped (already stepped this frame)")
            }
            return
        }
        if let waited { DebugLog.log("wheel gate open: \(waited.wait) not shown after \(StepGate.waitLimit) s") }
        DebugLog.log("wheel dy \(dy) inverted \(event.isDirectionInvertedFromDevice) -> \(down ? "next" : "previous")")
        wakeWheelLink()
        let wait = Settings.shared.config.wheelStep
        let step = down ? 1 : -1
        let moved = session.go(by: step, wait: wait)
        if moved { wheelGate.stepped(waitFor: wait, now: event.timestamp) }
        folderEnd(moved: moved, direction: step, fresh: fresh)
        // A step that went nowhere (an end of the folder) leaves the photo on screen: that may end the wait at once.
        stepGatesPhotoShown()
    }

    /// Tells both step gates what the screen shows of the current photo, while a step waits for it.
    private func stepGatesPhotoShown() {
        guard wheelGate.isWaiting || keyGate.isWaiting else { return }
        let quality = session.shownQuality
        Self.photoShown(&wheelGate, "wheel", quality)
        Self.photoShown(&keyGate, "key", quality)
    }

    private static func photoShown(_ gate: inout StepGate, _ name: String, _ quality: ShownQuality?) {
        guard let pending = gate.pending else { return }
        gate.photoShown(quality)
        guard gate.pending == nil, let quality else { return }
        let ms = Int(((ProcessInfo.processInfo.systemUptime - pending.since) * 1000).rounded())
        DebugLog.log("\(name) gate open: \(quality) after \(ms) ms")
    }

    // MARK: Folder step by a held button

    // Trackpad: a physical click held with one finger while two others swipe sideways; mouse: the right button
    // held while the tilt or side wheel scrolls (⇧+wheel arrives as horizontal too). Direction by
    // `folder-scroll-direction` (default: fingers right, whatever "natural scrolling" says, and tilt left / ⇧+wheel
    // up = next; `natural` the other way, as the three-finger swipe and the vertical wheel) (tilt right or ⇧+wheel down = next). While a button is held, precise scroll only feeds the
    // gesture and never pans, so the folder step does not drag the picture first; it also skips the touch-count
    // guard, because the clicking finger may make the swipe look like three fingers. Which buttons count, the
    // momentum rule, the repeats while the button stays held and the press latch are `FolderScrollGesture`'s; this side reads the buttons, turns
    // the deltas into its sign convention, and suppresses or undoes what the held button did.

    /// The buttons held right now.
    private var heldButtons: LoupeCore.MouseButtons { LoupeCore.MouseButtons(rawValue: NSEvent.pressedMouseButtons) }

    /// True when the event belongs to the held-button folder gesture (it then must not pan or step photos).
    /// A press that the strip owns (a scrub, a resize of its top edge) is not the gesture's held button: a step
    /// would replace the playlist under the scrub.
    private func folderScrollConsumed(_ event: NSEvent) -> Bool {
        let config = Settings.shared.config
        guard config.folderScrollGesture, !isStripPressed() else { return false }
        let precise = event.hasPreciseScrollingDeltas
        // Fingers and notches by `folder-scroll-direction` (`FolderScrollDirection.factor`).
        let k = config.folderScrollDirection.factor(precise: precise, invertedFromDevice: event.isDirectionInvertedFromDevice)
        let momentum = ScrollPhase(rawValue: event.momentumPhase.rawValue)
        let outcome = folderScroll.event(dx: k * event.scrollingDeltaX, dy: k * event.scrollingDeltaY, precise: precise,
                                         momentum: !momentum.isEmpty, began: event.phase.contains(.began),
                                         held: heldButtons, threshold: config.folderScrollThreshold,
                                         repeatAfter: Double(config.folderScrollRepeatMilliseconds) / 1000,
                                         at: event.timestamp)
        guard outcome != .pass else { return false }
        if precise {
            // Keep the guard's view of the scroll gesture current (its verdict does not matter while held), so a
            // step can latch the rest of the gesture below.
            let t = session.transform
            _ = scrollGuard.scroll(phase: ScrollPhase(rawValue: event.phase.rawValue), momentum: momentum,
                                   touches: touchCount, start: ScrollStart(center: t.center, mode: t.mode))
        }
        DebugLog.log("held-button scroll \(event.scrollingDeltaX), \(event.scrollingDeltaY) buttons \(NSEvent.pressedMouseButtons)"
                     + " touches \(touchCount) momentum \(!momentum.isEmpty) -> \(outcome)")
        guard case .step(let step) = outcome else { return true }
        // The fingers may go on (and coast) after the button is let go: none of that may pan. A repeat in the same
        // press latches its own swipe the same way.
        _ = scrollGuard.swipeFired()
        // The held button's own action ends here: no zoom, no zoom glide, no pan, no drag glide; and what it already
        // did is undone: the next photo inherits the relative centre and mode, so a half zoom or a shift would show.
        if let zoom = rmbZoom, rmbDragging { restoreTransform(zoom.start) }
        endRMBZoom()
        if dragPoint != nil {
            if let dragStart { restoreTransform(dragStart) }
            dragPoint = nil
            dragVelocity.reset()
            refreshCursor()
        }
        switch step {
        case .next, .previous: goFolder(step == .next ? 1 : -1, from: "held-button scroll")
        case .up, .down:
            // Vertical by the fingers, whatever `folder-scroll-direction` did to the deltas (it turns dy with dx).
            let fingersDown = (step == .down) == (config.folderScrollDirection == .natural)
            _ = performTrackpad(fingersDown ? .clickDown : .clickUp, at: event.timestamp)
        }
        return true
    }

    /// A trackpad gesture's binding (`TP_3UP`, `TP_FORCE`… in input.conf), done as a button's tap; false when the
    /// gesture is unbound.
    @discardableResult
    private func performTrackpad(_ gesture: MouseButton, at timestamp: TimeInterval) -> Bool {
        guard let input = Settings.shared.inputMap.mouse(gesture, .tap) else { return false }
        DebugLog.log("trackpad \(gesture.rawValue) -> \(InputConf.text(of: input))")
        performMouse(input, steps: 1, fresh: true, at: timestamp)
        return true
    }

    /// The force click's stage in the current press (0 up, 1 click, 2 force click): `TP_FORCE` fires on reaching 2.
    private var pressureStage = 0

    override func pressureChange(with event: NSEvent) {
        let stage = event.stage
        defer { pressureStage = stage }
        guard stage == 2, pressureStage < 2 else { return }
        performTrackpad(.forceClick, at: event.timestamp)
    }

    /// A precise scroll over the thumbnail strip, which scrubs with it unless this says the gesture is spent: it stops a
    /// glide as a scroll on the picture does, and goes through the same folder gesture and scroll guard, so the guard
    /// sees every gesture begin (dropping its latch) and the strip does not scrub with the rest of one that a folder
    /// step or a three-finger swipe already used (the click let go while the fingers swipe or coast on), nor with
    /// three fingers down. Nothing pans here.
    func stripScrollIsSpent(_ event: NSEvent) -> Bool {
        if MouseButtons.shared.wheel(event) { return true }   // a held button's wheel binding takes it
        stopInertiaAtZoomTarget()   // the strip scrubs photos
        if folderScrollConsumed(event) { return true }
        let t = session.transform
        let free = scrollGuard.scroll(phase: ScrollPhase(rawValue: event.phase.rawValue),
                                      momentum: ScrollPhase(rawValue: event.momentumPhase.rawValue),
                                      touches: touchCount, start: ScrollStart(center: t.center, mode: t.mode))
        if !free { DebugLog.log("strip scroll ignored (gesture spent, touches \(touchCount))") }
        return !free
    }

    /// Puts back a transform from the start of a press, unless the image or the view size changed since (then it
    /// is stale and would jump the picture).
    private func restoreTransform(_ start: ViewTransform) {
        let now = session.transform
        guard now.imageSize == start.imageSize, now.viewSize == start.viewSize else { return }
        session.transform = start
    }

    /// Spec §8.2: transitions do not queue, at most one per frame. The link ticks `wheelGate.frame()`;
    /// a tick that finds no step since the previous one pauses the link until the next notch.
    private func wakeWheelLink() {
        if wheelLink == nil {
            guard window != nil else { wheelGate.frame(); return }   // no link, no frame tick: never latch
            let link = displayLink(target: DisplayLinkTarget { [weak self] in self?.wheelTick($0) },
                                   selector: #selector(DisplayLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            wheelLink = link
        }
        wheelLink?.isPaused = false
    }

    private func wheelTick(_ link: CADisplayLink) {
        guard link === wheelLink else { link.invalidate(); return }
        DebugLog.log("wheel frame")
        let stepped = wheelGate.isActive
        wheelGate.frame()
        if !stepped { link.isPaused = true }
    }

    /// While `on`, frames draw only the background (`RenderLoop.hold`, `launch-reveal`).
    func holdReveal(_ on: Bool) {
        renderLoop.hold(on)
        panIndicatorsView.held = on
    }

    /// `background`: the picture's surround, drawn by the render loop and also the layer's own colour (what shows
    /// for a moment before the first frame or around a live resize).
    func setBackground(_ color: BackgroundColor) {
        renderLoop.setBackground(color)
        metalLayer.backgroundColor = color.cgColor
    }

    /// `upscale`, `downscale`, `lanczos-antiring`, `pixel-art`: the filters the render loop draws with.
    func setResampling(_ settings: ResampleSettings) { renderLoop.setResampling(settings) }

    /// `transparency`, `checker-size`, `checker-colors`: what shows through a photo's transparent pixels.
    func setTransparency(_ settings: TransparencySettings) { renderLoop.setTransparency(settings) }

    /// `pan-indicators` (with `P`'s session value), `pan-indicators-hide`, `pan-indicators-fade`,
    /// `pan-indicators-on-switch`: the position pills.
    func setPanIndicators(_ settings: Settings) {
        let config = settings.config
        panIndicatorsView.setMode(settings.panIndicators, hide: Double(config.panIndicatorsHideMilliseconds) / 1000,
                                  fade: Double(config.panIndicatorsFadeMilliseconds) / 1000,
                                  onSwitch: config.panIndicatorsOnSwitch)
    }

    /// Whether the render loop records frame times for the extended stats (off: no cost per frame).
    func setFrameStatsEnabled(_ on: Bool) { renderLoop.setFrameStatsEnabled(on) }

    /// `LOUPE_DEBUG`: logs `sharp <session> +<ms>` at the first frame from now drawn at the level the zoom wants
    /// (`RenderLoop.watchSharp`, windows spec §3.8).
    func watchSharp(session: Int) { renderLoop.watchSharp(session: session, since: CACurrentMediaTime()) }
    func frameStats() -> FrameStats { renderLoop.frameStats() }

    /// Stops every display link the view owns, the render thread last, and lets the images shown go (their levels are
    /// graphics memory, which the cache frees with the window's session); the window controller calls it when the
    /// window closes.
    func teardown() {
        stopInertiaAtZoomTarget()
        stopWheelLink()
        cursorAutohide.stop()
        setFrameStatsEnabled(false)
        renderLoop.stop()
        shownImage = nil
        shownCompanion = nil
    }

    /// The wheel's link belongs to the window it was made for.
    private func stopWheelLink() {
        wheelLink?.invalidate()
        wheelLink = nil
        wheelGate.cancel()
        keyGate.cancel()
    }

    /// Pinch zooms around the cursor: the image point under it stays put. One gesture (phase began →
    /// ended) halts at each zoom stop it reaches; the next gesture goes on past it. If something else
    /// changed the transform mid-pinch (a key, a new photo, a resize) the stops are recomputed from there.
    /// With `zoom-rubber-band` a pinch past a zoom limit stretches about the fingers (`ZoomStopGesture.stretch`), and
    /// lifting them springs back to the limit (M4b spec §3).
    override func magnify(with event: NSEvent) {
        stopInertia()
        let t = session.transform
        let config = Settings.shared.config
        if event.phase.contains(.began) || pinch?.last != t {
            pinch = Pinch(stops: ZoomStopGesture(transform: t, stops: config.zoomStops, rubber: config.zoomRubberBand),
                          proposed: t.scale, last: t)
        }
        guard var p = pinch else { return }
        p.proposed *= max(0.01, 1 + event.magnification)
        let r = p.stops.constrain(p.proposed)
        let anchor = viewPoint(event)
        DebugLog.log("magnify \(event.magnification) -> \(r.scale)\(r.hitStop.map { " stop \($0)" } ?? "")"
                     + (p.stops.stretch == 1 ? "" : " stretch \(p.stops.stretch)"))
        session.transform = t.zoomed(toScale: r.scale, anchor: anchor)
            .withStretch(Self.zoomStretch(p.stops.stretch, anchor: anchor))
        zoomStopFeedback(justHit: p.stops.justHit)
        p.last = session.transform
        guard event.phase.contains(.ended) || event.phase.contains(.cancelled) else {
            pinch = p
            return
        }
        pinch = nil
        if p.stops.stretch != 1 { springBackZoom() }
    }

    /// Smart zoom, a two-finger double tap (when the system's "Smart zoom" is on; M4a spec §2.3): `z` at the fingers,
    /// Fit ↔ 100 %, without zoom stops or haptics, like the `0` / `1` keys, and animated like them.
    override func smartMagnify(with event: NSEvent) {
        DebugLog.log("smart zoom")
        animateZoom(to: zoomBase.toggledFitActual(anchor: viewPoint(event)))
    }

    /// A gesture's zoom stretch factor as the transform's stretch about `anchor`: none at 1 (inside the limits).
    private static func zoomStretch(_ factor: Double, anchor: CGPoint) -> ZoomStretch? {
        factor == 1 ? nil : ZoomStretch(factor: factor, anchor: anchor)
    }

    /// A pinch or right-button zoom released past a zoom limit: the stretch springs back to the limit about its anchor,
    /// animated like a zoom key (M4b spec §3).
    private func springBackZoom() {
        let t = session.transform
        guard t.stretch != nil else { return }
        DebugLog.log("zoom spring back from \(t.drawnScale) to \(t.scale)")
        animateZoom(to: t.withStretch(nil))
    }

    /// A tick on the trackpad when a gesture lands on a stop (once per landing), unless turned off.
    private func zoomStopFeedback(justHit: Bool) {
        guard justHit, Settings.shared.config.zoomStopHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: Three-finger swipe

    // The system "swipe between pages" setting is off here (and three fingers may belong to other system
    // gestures), so `swipe(with:)` is not relied on: the gesture is recognised from raw touches by
    // `ThreeFingerSwipe`, which works at any zoom. These handlers only observe: they do not call super
    // and do not consume anything, so two-finger scroll, pinch and drags are untouched.
    // `wantsRestingTouches` stays false: fingers that rest on the pad (a palm, a thumb) are then not
    // delivered at all, which is what is wanted; swiping fingers are moving, never "resting".

    override func touchesBegan(with event: NSEvent) { trackTouches(event) }
    override func touchesMoved(with event: NSEvent) { trackTouches(event) }
    override func touchesEnded(with event: NSEvent) { trackTouches(event) }
    /// Cancelled touches never report their fingers lifting, so the recogniser would keep a stale latch or baseline.
    override func touchesCancelled(with event: NSEvent) { resetTouches() }

    /// Touches stop arriving when the window loses key status or the view leaves its window, again without
    /// an "ended" for the fingers on the pad; drop whatever the recogniser remembered.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.willEnterFullScreenNotification, object: nil)
        center.removeObserver(self, name: NSWindow.willExitFullScreenNotification, object: nil)
        resetTouches()
        stopInertiaAtZoomTarget()   // the display link belongs to the window it was made for
        stopWheelLink()
        cursorAutohide.stop()
        guard let window else { return }
        center.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                           name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        if window.isKeyWindow { cursorAutohide.activity() }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(windowWillChangeFullScreen(_:)), name: name, object: window)
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        resetTouches()
        folderScroll.buttonsReleased()
        stopInertiaAtZoomTarget()   // a pinch or right-button release may never come: a held zoom stretch goes too
        cursorAutohide.stop()
    }

    /// A freshly opened or re-focused window hides a resting cursor too, without waiting for a move.
    @objc private func windowDidBecomeKey(_ notification: Notification) { cursorAutohide.activity() }

    @objc private func windowWillChangeFullScreen(_ notification: Notification) { stopInertiaAtZoomTarget() }

    /// Touches stopped being delivered without every finger being seen lifting.
    private func resetTouches() {
        threeFingerSwipe.reset()
        touchCount = 0
        scrollGuard.fingersLifted()
    }

    private func trackTouches(_ event: NSEvent) {
        // `.touching` is the full set of fingers on the pad right now; the ones that just ended or
        // were cancelled are no longer in it.
        let points = event.touches(matching: .touching, in: self).map(\.normalizedPosition)
        touchCount = points.count
        if points.isEmpty { scrollGuard.fingersLifted() }
        // A click held while two fingers swipe is the folder gesture; with the clicking finger counted it would
        // also look like a three-finger photo swipe. Start the swipe afresh once the button is up.
        if Settings.shared.config.folderScrollGesture, !heldButtons.isDisjoint(with: FolderScrollGesture.buttons) {
            threeFingerSwipe.reset()
            return
        }
        guard let step = threeFingerSwipe.update(touches: points, at: event.timestamp) else { return }
        DebugLog.log("three fingers -> \(step)")
        if step == .tap {
            performTrackpad(.threeTap, at: event.timestamp)
            return
        }
        stopInertiaAtZoomTarget()
        // The first two fingers already panned (scroll starts with two); put the picture back where that
        // gesture found it, so neither this photo nor the next (which inherits the centre) keeps the shift.
        if let start = scrollGuard.swipeFired() {
            var t = session.transform
            t.center = start.center
            t.mode = start.mode
            session.transform = t
        }
        switch step {
        case .next, .previous: session.go(by: step == .next ? 1 : -1)
        case .up: performTrackpad(.threeUp, at: event.timestamp)
        case .down: performTrackpad(.threeDown, at: event.timestamp)
        case .tap: break
        }
    }

    /// If the user turns on the system three-finger page swipe, AppKit sends this as well as the raw
    /// touches; the touches already navigated, so ignoring it keeps one gesture to one step.
    override func swipe(with event: NSEvent) {}

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Takes focus for the keys and remembers where a drag starts; a click does nothing else
    /// (double click included). Any press stops a coast in progress (the picture is "caught"), and holds a
    /// rubber-band spring where it shows.
    /// Where the left button went down, for a double click that did not move.
    private var pressPoint: CGPoint?

    override func mouseDown(with event: NSEvent) {
        stopInertia(catching: true)
        window?.makeFirstResponder(self)
        cursorAutohide.activity()
        endStaleRMBZoom()
        // While the right button zooms, the left one is ignored until the right is released; after a held-button
        // folder step, until every button is up.
        let mayAct = folderScroll.press(.left, held: heldButtons)
        guard rmbZoom == nil, mayAct else {
            releaseRubber()
            return
        }
        let p = viewPoint(event)
        dragPoint = p
        pressPoint = p
        dragStart = session.transform
        dragVelocity.reset()
        dragVelocity.add(p, at: event.timestamp)
        refreshCursor()
    }

    /// Left-button drag grabs the picture: it moves by exactly how far the cursor moved, so the image point
    /// that was grabbed stays under the cursor (cursor position rather than `deltaX/Y`, which would drift
    /// from the cursor wherever the system scales or drops deltas); past an image edge it stretches under the
    /// rubber band's resistance instead. The release velocity is tracked from the same positions.
    override func mouseDragged(with event: NSEvent) {
        cursorAutohide.activity()
        MouseButtons.shared.moved(event)
        updatePointerPage(at: viewPoint(event))   // a drag moves the pointer too: the info panel follows its page
        guard rmbZoom == nil, !folderScroll.hasFired else { return }
        let p = viewPoint(event)
        guard let last = dragPoint else { dragPoint = p; return }
        dragPoint = p
        dragVelocity.add(p, at: event.timestamp)
        DebugLog.log("drag \(p.x - last.x), \(p.y - last.y)")
        guard p != last else { return }
        // viewPoint is already physical pixels, y down: a cursor moving down moves the content down (+dy).
        session.transform = rubber.pan(by: CGVector(dx: p.x - last.x, dy: p.y - last.y), on: session.transform)
    }

    override func mouseUp(with event: NSEvent) {
        // A double click that did not move (under 4 pt): the folder browser on this photo (`browse`).
        if event.clickCount == 2, let start = pressPoint, hypot(viewPoint(event).x - start.x, viewPoint(event).y - start.y) < 4 {
            pressPoint = nil
            onTabAction?(.browse)
        }
        let wasDragging = dragPoint != nil
        dragPoint = nil
        dragStart = nil
        cursorAutohide.activity()
        refreshCursor()
        endStaleRMBZoom()
        folderScroll.release(.left, held: heldButtons)
        guard wasDragging, rmbZoom == nil else {
            releaseRubber()
            return
        }
        // `drag-inertia=no`: no glide; a stretch still springs back, from rest.
        let v = Settings.shared.config.dragInertia ? dragVelocity.releaseVelocity(at: event.timestamp) : .zero
        dragVelocity.reset()
        DebugLog.log("drag release velocity \(v.dx), \(v.dy)")
        // An axis held past an edge springs back with the release velocity on it; the other one glides.
        let stretched = session.transform.offset
        releaseRubber(velocity: v)
        let glide = CGVector(dx: stretched.dx == 0 ? v.dx : 0, dy: stretched.dy == 0 ? v.dy : 0)
        if glide != .zero { startInertia(velocity: glide) }
    }

    // MARK: Cursor

    // An open hand over a picture that a drag can move (`canPan`), a closed one while the left button holds
    // it, the arrow otherwise; and `CursorAutohide` hides it once the mouse rests. The tracking area brings
    // `cursorUpdate` on entering the view and `mouseMoved` for the autohide countdown, in the key window only.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited,
                                                              .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        shownCursor = nil   // the system (a window edge, the title bar) may have set another one meanwhile
        refreshCursor()
    }

    /// Also re-checks the shape: leaving the thumbnail strip (which sets the arrow over the picture's lower edge)
    /// brings no `cursorUpdate` here, since this view's tracking area spans the strip too.
    override func mouseMoved(with event: NSEvent) {
        cursorAutohide.activity()
        refreshCursor()
        onPointerMoved?()
        updatePointerPage(at: viewPoint(event))
        // A held button's travel comes from `MouseButtons`' own monitor of every mouse-moved event (M4c spec §12.2).
    }
    override func mouseEntered(with event: NSEvent) { cursorAutohide.activity() }
    override func mouseExited(with event: NSEvent) {
        shownCursor = nil
        onPointerMoved?()
        updatePointerPage(at: nil)
    }

    /// The page of the pair under `point` (view pixels; nil: the pointer left), told when it changed.
    private func updatePointerPage(at point: CGPoint?) {
        lastPointer = point
        let page = point.flatMap(page(at:))
        guard page != pointerPage else { return }
        pointerPage = page
        onPointerPageChanged?()
    }

    /// The page of the pair on screen under `point` (view pixels), nil off the pages or for one page.
    private func page(at point: CGPoint) -> Int? {
        session.shownLayout?.page(at: session.transform.imagePoint(forView: point))
    }

    /// An overlay that takes the mouse (the cheat sheet, the info panel) opened or closed: the cursor is chosen afresh, since the
    /// remembered shape may no longer be the one on screen.
    func overlayDidChange() {
        shownCursor = nil
        refreshCursor()
    }

    /// The shape for the current state.
    private var pictureCursor: NSCursor {
        guard session.image != nil, session.transform.canPan else { return .arrow }
        return dragPoint != nil ? .closedHand : .openHand
    }

    /// Whether the cursor is over this view and not over something on top of it (the thumbnail strip, the info panel;
    /// the stats bar is never hit). Over the panel there is no hand and no autohide, and since the panel is a sibling on
    /// top, its clicks, drags and scrolls never reach this view.
    private var isMouseOverPicture: Bool {
        guard let window, window.isKeyWindow, let content = window.contentView else { return false }
        // hitTest takes a point in the receiver's superview, which for the content view is window space.
        let p = window.mouseLocationOutsideOfEventStream
        return content.hitTest(content.superview?.convert(p, from: nil) ?? p) === self
    }

    /// Sets `pictureCursor` when it changed and the cursor is over the picture. A drag that has left the
    /// view keeps its closed hand; released out there, it leaves the arrow behind (nothing else would
    /// replace the hand until the cursor reaches another tracking area).
    private func refreshCursor() {
        // Home covers the picture (its tracking area still hears every move): the cursor is Home's, an arrow.
        if isCovered() {
            if shownCursor != nil { NSCursor.arrow.set() }
            shownCursor = nil
            return
        }
        guard dragPoint != nil || isMouseOverPicture else {
            if shownCursor === NSCursor.closedHand { NSCursor.arrow.set() }
            shownCursor = nil
            return
        }
        let cursor = pictureCursor
        guard cursor !== shownCursor else { return }
        shownCursor = cursor
        cursor.set()
    }

    // MARK: Drag inertia

    // Spec §8.2. A main-thread display link drives the coast: each tick moves the picture by the closed-form
    // displacement for the real frame time (`InertiaCoast`, `inertia-deceleration`), so 60 and 120 Hz glide
    // identically. The same link runs the rubber band's springs (M4a spec §2.1). It is created on release and
    // invalidated when the coast and the springs are done or anything else takes over (`stopInertia`).

    private func startInertia(velocity: CGVector) {
        coast = nil          // a spring released with it keeps running on the link
        zoomCoast = nil
        guard window != nil else { return }
        let c = InertiaCoast(velocity: velocity, decayPerMillisecond: Settings.shared.config.inertiaDeceleration)
        guard !c.isFinished else { return }
        coast = c
        ensureInertiaLink()
    }

    /// The right-button zoom keeps going after release, around the press anchor and under the drag's stops.
    private func startZoomInertia(_ z: RMBZoomCoast) {
        stopInertia()
        guard window != nil, !z.isFinished else { return }
        zoomCoast = z
        ensureInertiaLink()
    }

    // MARK: Zoom animation

    // M4b spec §2. A discrete zoom (a key, smart zoom, the spring-back of the zoom rubber band) plays out over
    // `zoom-animation` ms on the inertia link: each tick sets `ZoomAnimation.transform(at:)` for the frame's target
    // time, the last one the target itself. A new zoom key starts from the frame on screen; a gesture stops it on that
    // frame (`stopInertia`); a navigation, a resize or an orientation change jumps to the target first (`settleZoom`).

    /// The transform a zoom key or smart zoom computes its target from: the target of a running animation, so `+ + +`
    /// adds steps to the previous target rather than to a frame on the way (spec §2.3).
    private var zoomBase: ViewTransform { session.zoomTarget ?? session.transform }

    /// Animates the zoom to `target` (instantly with `zoom-animation=0`, then no target is set). It starts from the
    /// frame on screen (`session.transform`: a running animation's last tick, its offset and stretch included, so it
    /// goes on from where it is), and stops the other motions (a pan glide, the right-button coast, a pan spring)
    /// without settling.
    func animateZoom(to target: ViewTransform) {
        let now = CACurrentMediaTime()
        let from = session.transform
        zoomAnimation = nil
        stopInertiaLink()
        coast = nil
        zoomCoast = nil
        rubber.reset()   // the pan stretch on screen, if any, is in `from`: the animation takes it to the target
        let ms = Settings.shared.config.zoomAnimationMilliseconds
        let animation = ZoomAnimation(from: from, to: target, start: now, duration: Double(ms) / 1000)
        guard window != nil, !animation.isFinished(at: now) else {
            session.transform = target
            session.zoomTarget = nil
            return
        }
        DebugLog.log("zoom animation \(from.drawnScale) -> \(target.scale) (\(target.mode)) in \(ms) ms")
        zoomAnimation = animation
        zoomFrames = 0
        session.zoomTarget = target
        ensureInertiaLink()
    }

    /// One frame of the zoom animation at the frame's target time. It is over when the session moved its target
    /// (`settleZoom`, or a gesture's `stopInertia`), or when the image or view size changed under it.
    private func zoomAnimationTick(at time: CFTimeInterval) {
        guard let a = zoomAnimation else { return }
        let now = session.transform
        guard session.zoomTarget == a.to, now.imageSize == a.to.imageSize, now.viewSize == a.to.viewSize else {
            zoomAnimation = nil
            if session.zoomTarget == a.to { session.zoomTarget = nil }
            DebugLog.log("zoom animation dropped after \(zoomFrames) frames")
            return
        }
        zoomFrames += 1
        guard a.isFinished(at: time) else {
            session.transform = a.transform(at: time)
            return
        }
        zoomAnimation = nil
        session.transform = a.to
        session.zoomTarget = nil
        DebugLog.log("zoom animation done in \(zoomFrames) frames, \(Int(((time - a.start) * 1000).rounded())) ms")
    }

    /// A gesture takes over: a running zoom animation stops on the frame on screen (its last tick), without the clamp
    /// residual (`offset`; the stored centre stays, so geometry reads it clamped, as `ZoomAnimation.settled`), and its
    /// stretch goes at once (a zoom gesture starts from none, as from offset 0). One the session already jumped to its
    /// target (or that a new image or view size made stale) is just dropped.
    private func stopZoomAnimation() {
        guard let a = zoomAnimation else { return }
        zoomAnimation = nil
        guard session.zoomTarget == a.to else { return }
        let now = session.transform
        if now.imageSize == a.to.imageSize, now.viewSize == a.to.viewSize {
            session.transform = now.withStretch(nil)   // zeroes the offset too
        }
        session.zoomTarget = nil
        DebugLog.log("zoom animation stopped by a gesture after \(zoomFrames) frames")
    }

    /// Starts the link unless it already runs (a spring and a glide share it).
    private func ensureInertiaLink() {
        guard inertiaLink == nil, window != nil else { return }
        inertiaLastTimestamp = nil
        let link = displayLink(target: DisplayLinkTarget { [weak self] in self?.inertiaTick($0) },
                               selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        inertiaLink = link
    }

    private func stopInertiaLink() {
        inertiaLink?.invalidate()
        inertiaLink = nil
        inertiaLastTimestamp = nil
    }

    /// Ends a coast at once; a no-op when none runs. The single place that tears it down. A catching press
    /// (`catching`: a left press, fingers on the trackpad) holds a rubber-band stretch where it shows, for the drag or
    /// the release that follows; anything else drops the stretch at once (M4a spec §2.1: a zoom, a key, a step, a new
    /// photo start from offset 0). A zoom animation stops on its current frame (`stopZoomAnimation`): callers that
    /// are not gestures (a navigation, a resize) call `session.settleZoom()` first, so it ends at its target instead.
    private func stopInertia(catching: Bool = false) {
        stopInertiaLink()
        coast = nil
        zoomCoast = nil
        stopZoomAnimation()
        if catching { grabRubber() } else { dropStretch() }
    }

    /// `stopInertia` for what is not a gesture (a step, a folder step, the window losing focus or going full screen):
    /// a running zoom animation jumps to its target first (M4b spec §2.3), and a zoom stretch a gesture held when its
    /// release never came goes too.
    private func stopInertiaAtZoomTarget() {
        session.settleZoom()
        stopInertia()
        let t = session.transform
        if t.stretch != nil { session.transform = t.withStretch(nil) }
    }

    private func inertiaTick(_ link: CADisplayLink) {
        guard link === inertiaLink, coast != nil || zoomCoast != nil || zoomAnimation != nil || rubber.isAnimating else {
            link.invalidate()
            if link === inertiaLink { stopInertiaLink() }
            return
        }
        let last = inertiaLastTimestamp ?? link.timestamp
        inertiaLastTimestamp = link.targetTimestamp
        let dt = min(link.targetTimestamp - last, 0.05)
        guard dt > 0 else { return }
        if zoomAnimation != nil {
            zoomAnimationTick(at: link.targetTimestamp)
            if zoomAnimation == nil { stopInertiaLink() }   // it runs alone (`animateZoom`)
            return
        }
        if zoomCoast != nil { zoomInertiaTick(dt: dt); return }
        let before = session.transform
        var t = before
        if var c = coast {
            let want = c.step(dt: dt)
            // An axis that cannot move all of `want` has met an image edge (or the image fits the view on it): its
            // glide is gone, and with `rubber-band` it bounces off the edge with the glide's speed (`PanRubber`
            // ignores an axis on which the image fits).
            let left = t.panLeftover(want)
            let hitX = abs(left.dx) > 0.01, hitY = abs(left.dy) > 0.01
            if hitX || hitY {
                t = rubber.bounce(x: hitX ? c.velocity.dx : nil, y: hitY ? c.velocity.dy : nil, on: t)
                c.stopAxis(x: hitX, y: hitY)
            }
            t = t.panned(by: want).withOffset(t.offset)   // the glide moves the clamped centre, the stretch stays
            coast = c.isFinished ? nil : c
        }
        if rubber.isAnimating, let sprung = rubber.step(dt: dt, on: t) { t = sprung }
        if t != before { session.transform = t }
        if coast == nil, !rubber.isAnimating { stopInertiaLink() }
    }

    // MARK: Debug: LOUPE_AUTOPAN

    /// A key's action, as `keyDown` performs it (`LOUPE_AUTOPAN_MODE=keys`).
    func debugPerform(_ action: KeyAction) {
        perform(action, at: ProcessInfo.processInfo.systemUptime)
    }

    /// A pinch held `factor` past the upper zoom limit about the view centre and released: the spring-back.
    func debugSpringBack(factor: Double) {
        let t = session.transform, centre = CGPoint(x: t.viewSize.width / 2, y: t.viewSize.height / 2)
        stopInertia()
        session.transform = t.zoomed(toScale: t.scaleLimits.upperBound, anchor: centre)
            .withStretch(ZoomStretch(factor: factor, anchor: centre))
        springBackZoom()
    }

    /// A drag by `delta` view px, as `mouseDragged` moves the picture (the rubber band included).
    func debugDrag(by delta: CGVector) {
        session.transform = rubber.pan(by: delta, on: session.transform)
    }

    /// A drag released at `velocity` view px/s, as `mouseUp`: a held stretch springs back, the rest glides.
    func debugRelease(velocity v: CGVector) {
        let stretched = session.transform.offset
        releaseRubber(velocity: v)
        let glide = CGVector(dx: stretched.dx == 0 ? v.dx : 0, dy: stretched.dy == 0 ? v.dy : 0)
        if glide != .zero { startInertia(velocity: glide) }
    }

    // MARK: Rubber band

    /// Fingers lifted or the button released: a held stretch springs back with `velocity` (px/s) on its axis.
    private func releaseRubber(velocity: CGVector = .zero) {
        let t = session.transform
        let released = rubber.release(velocity: velocity, on: t)
        if released != t { session.transform = released }
        if rubber.isAnimating { ensureInertiaLink() }
    }

    /// A press or fingers during a spring: it stops where it shows (the link is already stopped).
    private func grabRubber() {
        guard rubber.isAnimating else { return }
        let t = session.transform
        let held = rubber.grab(on: t)
        if held != t { session.transform = held }
    }

    /// The stretch goes at once, without a spring.
    private func dropStretch() {
        rubber.reset()
        let t = session.transform
        if t.offset != .zero { session.transform = t.withOffset(.zero) }
    }

    /// `rubber-band` after a config reread: turned off, a stretch on screen goes at once.
    func setRubberBand(_ on: Bool) {
        guard rubber.enabled != on else { return }
        rubber.enabled = on
        if !on { dropStretch() }
    }

    private func zoomInertiaTick(dt: TimeInterval) {
        guard var z = zoomCoast else { return }
        // Like the drag, the glide is computed from the transform at the press: if the image or the view size
        // changed since, that transform is stale and writing it back would jump the picture.
        let now = session.transform
        guard now.imageSize == z.zoom.start.imageSize, now.viewSize == z.zoom.start.viewSize else {
            stopInertia()
            return
        }
        let frame = z.advance(dt: dt)
        DebugLog.log("rmb zoom coast -> \(frame.transform.scale)\(frame.landedOnStop ? " stop" : "")")
        session.transform = frame.transform
        zoomStopFeedback(justHit: frame.landedOnStop)
        rmbZoomFeedback(scale: frame.transform.scale, stretch: 1, limits: z.zoom.start.scaleLimits,
                        justHit: frame.landedOnStop)
        if z.isFinished { stopInertia() } else { zoomCoast = z }
    }

    // MARK: Right-button zoom

    // Spec §8.2: hold the right button and drag vertically; up zooms in, exponentially (`RMBZoom`), with
    // the image point under the press staying put. A click without a drag does nothing in M1 (the context
    // menu comes later), and none of these handlers call super, so AppKit pops no default menu.

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        DebugLog.log("mouse button 1 down")
        MouseButtons.shared.press(.right, at: event.timestamp)   // the first button of a chord (`MBTN_RIGHT+…`)
        // A left drag in progress holds a stretch; an ignored right press must not drop it. A press that starts the
        // zoom drops it below (the zoom starts from offset 0).
        stopInertia(catching: dragPoint != nil && heldButtons.contains(.left))
        window?.makeFirstResponder(self)
        cursorAutohide.activity()
        // A left-button drag already owns the picture; the right press is ignored until it ends
        // (unless its release was lost, and the left button is in fact up).
        if dragPoint != nil, !heldButtons.contains(.left) { dragPoint = nil }
        let mayAct = folderScroll.press(.right, held: heldButtons)
        guard dragPoint == nil, mayAct else { return }
        let p = viewPoint(event)
        let config = Settings.shared.config
        rmbZoom = RMBZoom(anchor: p, transform: session.transform,
                          pointsPerDoubling: RMBZoom.pointsPerDoubling(speed: config.rmbZoomSpeed),
                          inverted: config.rmbZoomInvert)
        rmbVelocity.reset()
        rmbDy = 0
        rmbStops = ZoomStopGesture(transform: session.transform, stops: config.zoomStops, rubber: config.zoomRubberBand)
        rmbPress = p
        rmbDragging = false
        rmbBumps = ZoomBumps()
    }

    /// Zoom follows the cursor's *cumulative* vertical travel since the press (absolute positions, not
    /// chained per-event deltas), so it is exact and drifts nowhere. Screen y is down, so a cursor moving
    /// up gives a negative `dyPoints`, which zooms in (out with `rmb-zoom-invert`: the travel goes through
    /// `RMBZoom.doublings(dyPoints:)` for the zoom, its velocity and its glide alike). The press-to-release drag is
    /// one zoom-stop gesture.
    override func rightMouseDragged(with event: NSEvent) {
        cursorAutohide.activity()
        MouseButtons.shared.moved(event)
        // After a right+button chord the right button does not zoom until it is released (spec §3.3).
        if MouseButtons.shared.rightZoomSuppressed {
            if rmbZoom != nil { endRMBZoom() }
            return
        }
        guard let zoom = rmbZoom, let press = rmbPress, var stops = rmbStops else { return }
        // The zoom is computed from the transform at the press. If the image or the view size changed since
        // (arrow key or wheel mid-drag, window resize, full screen), that transform is stale and writing it
        // back would jump the picture: end the zoom instead.
        let now = session.transform
        guard now.imageSize == zoom.start.imageSize, now.viewSize == zoom.start.viewSize else {
            endRMBZoom()
            return
        }
        let p = viewPoint(event)
        let k = backing
        if !rmbDragging {
            // Below the slop it is still a click: do nothing, so a shaky click never changes the zoom.
            guard hypot(p.x - press.x, p.y - press.y) / k >= RMBZoom.clickSlopPoints else { return }
            rmbDragging = true
        }
        let dy = (p.y - press.y) / k
        let doublings = zoom.doublings(dyPoints: dy)
        let r = stops.constrain(zoom.scale(doublings: doublings))
        rmbStops = stops
        rmbDy = dy
        rmbVelocity.add(doublings, at: event.timestamp)
        DebugLog.log("rmb zoom dy \(dy) pt -> \(r.scale)\(r.hitStop.map { " stop \($0)" } ?? "")"
                     + (stops.stretch == 1 ? "" : " stretch \(stops.stretch)"))
        // Past a zoom limit (`zoom-rubber-band`) the stretch is about the press anchor, where `RMBZoom` pins the image.
        session.transform = zoom.transform(toScale: r.scale)
            .withStretch(Self.zoomStretch(stops.stretch, anchor: zoom.anchor))
        zoomStopFeedback(justHit: stops.justHit)
        rmbZoomFeedback(scale: r.scale, stretch: stops.stretch, limits: zoom.start.scaleLimits, justHit: stops.justHit)
    }

    /// The mouse's answer to the right-button zoom (M4c spec §5, `ZoomBumps`), on top of the trackpad's tick:
    /// `haptic-limit` on getting to a zoom limit, `haptic-zoom-stop` on landing on a stop. A pinch never comes here.
    private func rmbZoomFeedback(scale: Double, stretch: Double, limits: ClosedRange<Double>, justHit: Bool) {
        switch rmbBumps.frame(scale: scale, stretch: stretch, limits: limits, landedOnStop: justHit) {
        case .limit: MouseHaptics.shared.limit()
        case .stop: MouseHaptics.shared.zoomStop()
        case nil: break
        }
    }

    /// With `rmb-zoom-inertia`, releasing a zoom drag that was still moving hands the press anchor, the stops and
    /// the release velocity to a coast (`RMBZoomCoast`); a click, a stale or slow release does not coast. A release
    /// past a zoom limit springs back instead, whatever the velocity (M4b spec §3).
    override func rightMouseUp(with event: NSEvent) {
        DebugLog.log("mouse button 1 up")
        cursorAutohide.activity()
        // The release of a right+button chord does nothing: no glide, no spring of a zoom the chord took over.
        let chorded = MouseButtons.shared.rightZoomSuppressed
        MouseButtons.shared.release(.right, at: event.timestamp)
        if chorded {
            endRMBZoom()
            folderScroll.release(.right, held: heldButtons)
            return
        }
        let coasting = Settings.shared.config.rmbZoomInertia && rmbDragging
        let zoom = rmbZoom, stops = rmbStops
        let v = rmbVelocity.releaseVelocity(at: event.timestamp)
        let dy = rmbDy
        endRMBZoom()
        folderScroll.release(.right, held: heldButtons)
        if let stops, stops.stretch != 1 {
            springBackZoom()
            return
        }
        guard coasting, let zoom, let stops else { return }
        DebugLog.log("rmb zoom release velocity \(v) doublings/s")
        if v != 0 {
            startZoomInertia(RMBZoomCoast(zoom: zoom, stops: stops, doublings: zoom.doublings(dyPoints: dy), velocity: v))
        }
    }

    // MARK: Other mouse buttons (M4c spec §3.1)

    // The middle, back and forward buttons (`buttonNumber` 2, 3, 4) go to `MouseButtons`, which tells a tap from a long
    // press, a wheel or a move while held; what fires comes back through `performMouse`. Each event is logged for the
    // hardware session (a mouse utility such as BetterMouse may take the buttons before they reach the app).

    override func otherMouseDown(with event: NSEvent) {
        DebugLog.log("mouse button \(event.buttonNumber) down")
        cursorAutohide.activity()
        if !MouseButtons.shared.otherMouseDown(event) { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        DebugLog.log("mouse button \(event.buttonNumber) up")
        cursorAutohide.activity()
        if !MouseButtons.shared.otherMouseUp(event) { super.otherMouseUp(with: event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        cursorAutohide.activity()
        MouseButtons.shared.moved(event)
    }

    private func endRMBZoom() {
        rmbZoom = nil
        rmbStops = nil
        rmbPress = nil
        rmbDragging = false
        rmbVelocity.reset()
    }

    /// If the right button's release was never delivered (window deactivated mid-drag), the zoom would
    /// block the left button for good; a left press while the right is not actually down clears it.
    private func endStaleRMBZoom() {
        if rmbZoom != nil, !heldButtons.contains(.right) { endRMBZoom() }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    /// The menus show the viewer's plain keys as their items' key equivalents (`KeyMap.menuKey`: `T`, `S`, `0`, …), and
    /// AppKit offers a key press as a key equivalent before it sends `keyDown`: to the key window's views
    /// (`performKeyEquivalent`, walked through the whole view tree), then to the main menu, and only if neither takes
    /// it to the first responder's `keyDown`. So the view takes its keys here, while its window is the key window and
    /// it is the first responder (as `keyDown` needs): a key without ⌘ ⌃ that the table binds (or any key while the
    /// cheat sheet is open) goes through `handleKey`, the same dispatcher as `keyDown`, and is claimed, so the main menu
    /// never sees it and nothing fires twice. Its rules hold as before: a held one-shot key repeats into nothing, an
    /// open sheet takes the key and closes. ⌘ / ⌃ keys and unbound ones go on to the menus. The menu items do their
    /// action by click (`performKeyAction`); the menu bar never matches a plain key in any window (`MainMenu`, and for
    /// the Zoom, Scaling and Colour menus `Settings.menuHasKeyEquivalent`).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.isKeyWindow == true, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        return handleKey(event) || super.performKeyEquivalent(with: event)
    }

    /// A Zoom, Scaling, Colour or View menu item made by `NSMenuItem.viewerKey(_:_:)`: the action its key does, by click. An
    /// open cheat sheet closes first (a key would only close it; a click is deliberate, so it then acts too), and
    /// Keyboard Shortcuts, which toggles the sheet, just closes it.
    @objc func performKeyAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let action = KeyAction(rawValue: name) else { return }
        if isCheatSheetOpen() {
            onToggleCheatSheet?()
            if action == .cheatSheet { return }
        }
        perform(action, at: ProcessInfo.processInfo.systemUptime)   // NSEvent's clock
    }

    /// The viewer's one key dispatcher (`keyDown`, `performKeyEquivalent`): true when the key was the viewer's (done,
    /// or swallowed as a repeat), false for a key to pass on. Repeated for the same event it decides the same.
    private func handleKey(_ event: NSEvent) -> Bool {
        // ⌘ ⌃ combinations belong to menu shortcuts; ⌥ and shift are the table's (⌥← / ⌥→ are folder steps, other ⌥
        // keys are unbound and fall through to the menus).
        let flags = event.modifierFlags
        guard flags.isDisjoint(with: [.command, .control]) else { return false }
        if let held = keyThatClosedSheet {
            if event.isARepeat, event.keyCode == held { return true }
            keyThatClosedSheet = nil
        }
        // Any key closes an open cheat sheet and does nothing else: Esc does not leave full screen, nothing navigates
        // behind the sheet. A held `?` that opened it repeats into nothing.
        if isCheatSheetOpen() {
            guard !event.isARepeat else { return true }
            keyThatClosedSheet = event.keyCode
            onToggleCheatSheet?()
            return true
        }
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        // Layout-independent: Russian "а" on the F key is still "f".
        let key = KeyboardLayout.characters(for: event)?.lowercased()
        let keys = Settings.shared.inputMap.keys                        // the built-in keys with input.conf's on top
        switch keys.lookup(keyCode: event.keyCode, character: key, modifiers: modifiers, isRepeat: event.isARepeat) {
        case .action(let input): perform(input, at: event.timestamp, fresh: !event.isARepeat)
        case .ignoredRepeat: break                                      // a held f, i, z, folder key…: not beeped at
        case .unbound: return false
        }
        return true
    }

    /// What a binding (a key, a mouse button) does: a viewer action, or an `add` handed to the window controller (once
    /// per call, so a held key's repeats step it again). `ignore` never gets here: the lookup reports it unbound.
    /// A `toggle-*` / `cycle-*` action that did something answers with `haptic-toggle` here, on the key and button path
    /// only: a menu click (`performKeyAction`) does not vibrate the mouse. `fresh`: a new press, not a key's
    /// auto-repeat (for `haptic-end`, `EndBump`).
    func perform(_ input: InputAction, at timestamp: TimeInterval, fresh: Bool) {
        switch input {
        case .action(let action):
            if perform(action, at: timestamp, fresh: fresh), InputConf.isToggle(action) { MouseHaptics.shared.toggle() }
        case .add(let key, let step): onAdjust?(key, step, 1)
        case .zoomStep: zoomStep(1)
        case .ignore: break
        }
    }

    /// What a mouse button's binding does (`MouseButtons`). As with a key, an open cheat sheet only closes, and only on
    /// a press: a held button's wheel or move step (the panel held while the mouse moves) leaves it open. An `add`
    /// steps `steps` times at once (signed: a wheel or a move may give several, down subtracts); any other action is
    /// done once per fire, whatever the step count, except `next-folder` / `previous-folder` and `next-tab` /
    /// `previous-tab` on a held button's wheel or move, which go either way by the step's sign
    /// (`InputAction.folderStep`, `buttonFolderStep`; `tabStep`, `buttonTabStep`). `fresh`: the
    /// fire is a press (a tap, a long press, a chord), not a wheel or move step of a held button (for `haptic-end`,
    /// `EndBump`).
    func performMouse(_ input: InputAction, steps: Int, fresh: Bool, at timestamp: TimeInterval) {
        if isCheatSheetOpen() {
            if fresh { onToggleCheatSheet?() }
            return
        }
        if !fresh, let step = input.folderStep(steps: steps) {
            buttonFolderStep(step, at: timestamp)
            return
        }
        if !fresh, let step = input.tabStep(steps: steps) {
            buttonTabStep(step, at: timestamp)
            return
        }
        switch input {
        case .add(let key, let step): onAdjust?(key, step, steps)
        case .zoomStep: zoomStep(steps)
        default: perform(input, at: timestamp, fresh: fresh)
        }
    }

    /// When the last held button's wheel / move step changed the folder (`buttonFolderStep`), on the events' clock.
    private var lastButtonFolderStep = -Double.infinity

    /// A folder step from a held button's wheel or move (built in: back + wheel, M4c spec §12.5): at most one per
    /// `folder-scroll-repeat` (as the right button + side wheel), whatever the notches; the ones in between are
    /// dropped, not saved up, so a fast spin goes one folder per gap. A gap of 0 lets every step through.
    private func buttonFolderStep(_ step: Int, at timestamp: TimeInterval) {
        let gap = Double(Settings.shared.config.folderScrollRepeatMilliseconds) / 1000
        guard timestamp - lastButtonFolderStep >= gap else { return }
        lastButtonFolderStep = timestamp
        goFolder(step, from: "button wheel")
    }

    /// When the last held button's wheel / move step changed the tab (`buttonTabStep`), on the events' clock. One for
    /// all viewers: the step lands in another tab, whose view takes the next steps.
    private static var lastButtonTabStep = -Double.infinity

    /// A tab step from a held button's wheel or move (`next-tab` / `previous-tab`), throttled as `buttonFolderStep`: at
    /// most one per `folder-scroll-repeat`, the steps in between dropped.
    private func buttonTabStep(_ step: Int, at timestamp: TimeInterval) {
        let gap = Double(Settings.shared.config.folderScrollRepeatMilliseconds) / 1000
        guard timestamp - Self.lastButtonTabStep >= gap else { return }
        Self.lastButtonTabStep = timestamp
        DebugLog.log("button wheel tab step \(step)")
        onTabAction?(step > 0 ? .nextTab : .previousTab)
    }

    /// `zoom-step` (M4c spec §12.3; built in on the forward button + wheel): `steps` zoom steps at the pointer, in for
    /// positive, out for negative (`ViewTransform.zoomStepped`: the keys' √2 step that lands on a `zoom-stops` stop rather
    /// than jump over it). Like a zoom key it goes on from the target of a running animation (`zoomBase`) and animates
    /// with `zoom-animation`, so quick wheel steps retarget one animation instead of queueing. The mouse answers as for
    /// the right-button zoom (§5): `haptic-limit` at a zoom limit, else `haptic-zoom-stop` on landing on a stop; several
    /// steps in one event play one of them, the limit first.
    private func zoomStep(_ steps: Int) {
        guard steps != 0 else { return }
        let start = zoomBase
        let anchor = cursorOrCentre()
        let stops = Settings.shared.config.zoomStops
        var t = start
        var bumps: Set<ZoomStepBump> = []
        for _ in 0..<abs(steps) {
            let r = t.zoomStepped(up: steps > 0, anchor: anchor, stops: stops)
            t = r.transform
            if let bump = r.bump { bumps.insert(bump) }
        }
        DebugLog.log("zoom step \(steps): \(start.scale) -> \(t.scale) (\(t.mode))\(bumps.isEmpty ? "" : " \(bumps)")")
        if t != start { animateZoom(to: t) }
        if bumps.contains(.limit) {
            MouseHaptics.shared.limit()
        } else if bumps.contains(.stop) {
            MouseHaptics.shared.zoomStop()
        }
    }

    /// `thumb-wheel-zoom`: the MX Master's thumb wheel with no button held zooms at the pointer, `delta` wheel units of
    /// `stepsPerRevolution` per turn (the package's sign: left = positive on the MX Master 4), right = in unless
    /// `thumb-zoom-invert`, by `thumb-zoom-speed` doublings per turn, at once (no animation, as a pinch). A turn of the wheel (`began`) is a new gesture, as is one after something else changed the transform;
    /// `thumb-zoom-stops` says whether a stop halts the turn or only ticks. The mouse answers as for `zoom-step`.
    func thumbWheelZoom(delta: Int, stepsPerRevolution: Int, began: Bool) {
        guard !isCheatSheetOpen() else { return }
        let config = Settings.shared.config
        let doublings = ThumbZoom.doublings(delta: config.thumbZoomInvert ? delta : -delta,
                                            stepsPerRevolution: stepsPerRevolution, speed: config.thumbZoomSpeed)
        guard doublings != 0 else { return }
        stopInertia()
        let t = session.transform
        if began || thumbZoom?.last != t {
            thumbZoom = (ThumbZoom(transform: t, stops: config.zoomStops, mode: config.thumbZoomStops), t)
        }
        guard var z = thumbZoom?.zoom else { return }
        let r = z.turn(doublings: doublings)
        let shown = t.zoomed(toScale: r.scale, anchor: cursorOrCentre())
        DebugLog.log("thumb zoom \(delta)/\(stepsPerRevolution): \(t.scale) -> \(r.scale)"
                     + (r.stop.map { " stop \($0)" } ?? "") + (r.bump.map { " \($0)" } ?? ""))
        if shown != t { session.transform = shown }
        thumbZoom = (z, session.transform)
        switch r.bump {
        case .limit: MouseHaptics.shared.limit()
        case .stop: MouseHaptics.shared.zoomStop()
        case nil: break
        }
    }

    /// What a key (or its menu item) does; `timestamp` is the press's, on NSEvent's clock. Zoom keys animate
    /// (`animateZoom`) to a target computed from the previous one (`zoomBase`); they never stretch. False when it did
    /// nothing (Esc out of full screen, a folder key without a photo). `fresh` is for `haptic-end` (`keyStep`): nil for
    /// a menu click and the debug driver, which do not vibrate the mouse.
    @discardableResult
    private func perform(_ action: KeyAction, at timestamp: TimeInterval, fresh: Bool? = nil) -> Bool {
        let t = zoomBase
        switch action {
        case .panLeft: panByKey(dx: -Self.keyPanFraction, dy: 0)
        case .panRight: panByKey(dx: Self.keyPanFraction, dy: 0)
        case .panDown: panByKey(dx: 0, dy: Self.keyPanFraction)
        case .panUp: panByKey(dx: 0, dy: -Self.keyPanFraction)
        case .previous: keyStep("previous", by: -1, now: timestamp, fresh: fresh)
        case .next: keyStep("next", by: 1, now: timestamp, fresh: fresh)
        case .previousFolder: goFolder(-1)
        case .nextFolder: goFolder(1)
        case .first: go("first") { session.goFirst() }
        case .last: go("last") { session.goLast() }
        case .exitFullScreen:                                           // Esc leaves full screen, nothing else
            guard let window, window.styleMask.contains(.fullScreen) else { return false }
            window.toggleFullScreen(nil)
        case .fit: animateZoom(to: t.withMode(.fit))
        case .actual100: animateZoom(to: t.withMode(.actual(1)))
        case .actual200: animateZoom(to: t.withMode(.actual(2)))
        case .actual400: animateZoom(to: t.withMode(.actual(4)))
        case .fitWidth: animateZoom(to: t.withMode(.fitWidth))
        case .fitHeight: animateZoom(to: t.withMode(.fitHeight))
        case .fill: animateZoom(to: t.withMode(.fill))
        case .toggleFitActual: animateZoom(to: t.toggledFitActual(anchor: cursorOrCentre()))
        case .zoomIn: animateZoom(to: t.zoomedStep(1))
        case .zoomOut: animateZoom(to: t.zoomedStep(-1))
        case .toggleFullScreen: window?.toggleFullScreen(nil)
        case .cycleStats: onToggleStats?()
        case .toggleStrip: onToggleStrip?()
        case .toggleStripPlacement: onToggleStripPlacement?()
        case .cheatSheet: onToggleCheatSheet?()
        case .toggleInfoPanel: onToggleInfoPanel?()
        case .cycleFilter, .saveFilters, .toggleAntiring, .saveAntiring: return onScalingKey?(action) ?? false
        case .toggleAutoColor, .saveAutoColor, .toggleVibrance, .saveVibrance: return onColourKey?(action) ?? false
        case .toggleKeepZoom, .saveKeepZoom, .toggleZoomCarry, .saveZoomCarry: return onZoomKey?(action) ?? false
        case .cyclePanIndicators, .savePanIndicators: return onPanIndicatorKey?(action) ?? false
        case .toggleSpread, .saveSpread, .shiftSpread: return onSpreadKey?(action) ?? false
        case .newTab, .newWindow, .closeTab, .nextTab, .previousTab, .openInNewTab, .openInNewWindow, .home, .back,
             .reopenTab, .closeWindow, .browse:
            onTabAction?(action)
        }
        return true
    }

    /// Fraction of the view a ⇧+arrow pans by.
    private static let keyPanFraction = 0.1

    /// Like a zoom key, it goes on from the target of a running zoom animation.
    private func panByKey(dx: Double, dy: Double) {
        stopInertiaAtZoomTarget()
        session.transform = session.transform.pannedByViewFraction(dx: dx, dy: dy)
    }

    /// The mouse pointer in the transform's space (physical pixels, origin top-left); the view centre when
    /// the pointer is outside the view.
    private func cursorOrCentre() -> CGPoint {
        let size = session.transform.viewSize
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let window else { return centre }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(local) else { return centre }
        let p = convertToBacking(local)
        return CGPoint(x: p.x, y: size.height - p.y)
    }

    /// Navigation by key repeats while the key is held; loads are serialised and stale ones dropped.
    private func go(_ what: String, _ action: () -> Void) {
        DebugLog.log("key \(what)")
        stopInertiaAtZoomTarget()
        action()
    }

    /// A previous / next key: a press or an auto-repeat steps once the last key step's photo is shown as `key-step`
    /// asks (`StepGate`), otherwise it is dropped, not queued, so a held key shows every photo instead of skipping
    /// the ones it did not wait for. The wait's limit runs on the event's clock, like the wheel's. A step that stopped
    /// at an end of the folder may answer with `haptic-end` (`fresh` non-nil: a key or a mouse button, not a menu
    /// click).
    private func keyStep(_ what: String, by step: Int, now: TimeInterval, fresh: Bool?) {
        let waited = keyGate.pending
        guard keyGate.request(now: now) else {
            stopInertiaAtZoomTarget()   // a dropped press still ends a coast
            DebugLog.log("key \(what) dropped (waiting for \(waited?.wait.rawValue ?? "-") of "
                         + "\(session.playlist?.current.lastPathComponent ?? "-"))")
            return
        }
        if let waited { DebugLog.log("key gate open: \(waited.wait) not shown after \(StepGate.waitLimit) s") }
        let wait = Settings.shared.config.keyStep
        var moved = false
        go(what) { moved = session.go(by: step, wait: wait) }
        if moved { keyGate.stepped(waitFor: wait, now: now) }
        if let fresh { folderEnd(moved: moved, direction: step, fresh: fresh) }
        // A step that went nowhere (an end of the folder) leaves the photo on screen: that may end the wait at once.
        stepGatesPhotoShown()
    }

    /// A previous / next step by a wheel notch, a key or a mouse button was tried (not one the step gate dropped):
    /// `haptic-end` once per push against an end (`EndBump`). Without a folder there is no end to bump against.
    private func folderEnd(moved: Bool, direction: Int, fresh: Bool) {
        guard session.playlist != nil else { return }
        if endBump.stepped(moved: moved, direction: direction, fresh: fresh) {
            DebugLog.log("folder end: \(direction > 0 ? "next" : "previous") stopped")
            MouseHaptics.shared.end()
        }
    }

    private func goFolder(_ step: Int, from source: String = "key") {
        DebugLog.log("\(source) \(step > 0 ? "next" : "previous") folder")
        stopInertiaAtZoomTarget()
        session.goFolder(by: step)
    }

    override func layout() {
        super.layout()
        syncDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    /// The backing scale the render loop last got (`syncDrawableSize`); 0 before the first.
    private var backingScaleSent: CGFloat = 0

    /// Sets the drawable size and the transform's view size together, in physical pixels, so the render
    /// thread never draws a transform made for another size (it skips the one frame where they disagree).
    private func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        if backingScaleSent != scale {   // checker cells are points, so their pixel size follows the screen
            backingScaleSent = scale
            renderLoop.setBackingScale(Double(scale))
        }
        if size.width >= 1, size.height >= 1, metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        if session.transform.viewSize != size {
            session.settleZoom()   // a resize starts from the target of a zoom animation (M4b spec §2.3)
            rubber.reset()   // the new size zeroes the offset; a spring would only find it gone
            session.transform = session.transform.withViewSize(size, keepingScale: session.resizeKeepsScale)   // notifies -> sessionDidChange
        }
    }
}

@MainActor extension NSMenuItem {
    /// A menu item for a viewer key's action: it shows the key (`showKey`) and does the action by click, through the key
    /// window's viewer (`ViewerView.performKeyAction`, no target); without a viewer window the item is disabled.
    static func viewerKey(_ title: String, _ action: KeyAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ViewerView.performKeyAction(_:)), keyEquivalent: "")
        item.showKey(of: action)                    // also the action `performKeyAction` reads (`representedObject`)
        return item
    }

    /// Shows the effective keys again (`showKey`) on every item of `menu` and its submenus that shows a viewer key
    /// (`viewerKey` items, Thumbnail Strip, Stats Bar): input.conf was read again. Other items' `representedObject`
    /// (pan indicator modes, colour methods, scaling picks) never reads as a `KeyAction`.
    static func refreshShownKeys(in menu: NSMenu) {
        for item in menu.items {
            if let name = item.representedObject as? String, let action = KeyAction(rawValue: name) {
                item.showKey(of: action)
            }
            if let submenu = item.submenu { refreshShownKeys(in: submenu) }
        }
    }

    /// Shows `action`'s viewer key in the effective layout (`Settings.inputMap`, `KeyMap.menuKey`) as this item's key
    /// equivalent, or none when input.conf left the action without a key (the item still works by click). Only shows
    /// it: the viewer takes the key before the menu could (`ViewerView.performKeyEquivalent`) and the menu bar never
    /// matches a plain key (`MainMenu`), so the key does its action once, by the viewer's rules. The action goes into
    /// `representedObject`, where `refreshShownKeys` finds it when input.conf changes.
    func showKey(of action: KeyAction) {
        representedObject = action.rawValue
        guard let key = Settings.shared.inputMap.keys.menuKey(action) else {
            keyEquivalent = ""
            keyEquivalentModifierMask = []
            return
        }
        keyEquivalent = key.keyEquivalent
        var mask: NSEvent.ModifierFlags = []
        if key.modifiers.contains(.shift) { mask.insert(.shift) }
        if key.modifiers.contains(.option) { mask.insert(.option) }
        keyEquivalentModifierMask = mask
    }
}

/// Target for a view's display links. `CADisplayLink` retains its target, so pointing it at the view
/// itself would keep the view (and its session) alive for as long as the link runs; this holds the view
/// weakly through the handler instead.
private final class DisplayLinkTarget: NSObject {
    private let handler: (CADisplayLink) -> Void?
    init(_ handler: @escaping (CADisplayLink) -> Void?) { self.handler = handler }
    /// A nil result means the view is gone: the link has nothing left to drive.
    @objc func tick(_ link: CADisplayLink) { if handler(link) == nil { link.invalidate() } }
}
