import CoreGraphics
import Foundation
import LoupeCore
import LoupeRender
import Metal
import os
import QuartzCore

/// One page of what `RenderLoop` shows: its image, turned by `orientation`, with its photo's colour cube (`ShownColor`, nil:
/// none), drawn into `rect`, a rectangle of the shared transform's image (`SpreadLayout.rects`). A single page's rect is
/// the transform's whole image; two pages of a spread share one virtual picture (`SpreadLayout.virtualSize`).
struct RenderPage: @unchecked Sendable {   // TiledImage is Sendable, ShownColor holds immutable cubes
    var image: TiledImage?
    var orientation: ImageOrientation
    var color: ShownColor<ColorLUT>?
    var rect: CGRect

    init(image: TiledImage?, orientation: ImageOrientation, color: ShownColor<ColorLUT>?, rect: CGRect) {
        self.image = image
        self.orientation = orientation
        self.color = color
        self.rect = rect
    }
}

/// Draws frames on a dedicated thread, driven by a `CAMetalDisplayLink`, and only while something
/// changes: the main thread hands over what to show with `update`, the next display-link callback
/// draws it, and once nothing has changed for `IdlePolicy.grace` the link pauses (spec §3: idle ≈ 0 % CPU).
/// It does not pause on the first quiet callback: during a drag in full screen that callback fires just
/// before each event, and the resume round-trip would cost the frame.
///
/// Late latch: the callback does not read the snapshot at once but waits until half a refresh period
/// away from where input events have been arriving (`InputPhase`). In full screen, drag and scroll
/// events land within a millisecond of the callback, some before it and some after, so reading at the
/// callback gave some frames no event and others two (judder at a steady frame rate). Each callback
/// comes a frame or more before its deadline and the GPU needs about a millisecond, so the wait is
/// affordable; without a stream of input (keys, loads) there is no wait. It adds no input-to-photon
/// latency: the frame's presentation time is fixed when the callback fires, and reading later only lets
/// the events of the wait reach this frame instead of the next one.
///
/// Threads: `update` may be called from any thread (the app calls it from main). Everything else —
/// the `TileRenderer` (single-threaded by contract), the display link, the layer's colour-space tag —
/// is touched only on the render thread, so the main thread never waits for the GPU or a drawable.
/// `stop` ends that thread when the window closes.
final class RenderLoop: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    /// What the main thread wants on screen, swapped atomically. `generation` counts updates, so the
    /// render thread can tell "changed since my last frame" without comparing images or transforms.
    private struct Snapshot: @unchecked Sendable {   // TiledImage is Sendable; CFRunLoop is safe to pass
        /// Up to two pages, left to right, each with its image, orientation and colour cube (`RenderPage`); empty: no
        /// photo. A page's cube is set in the same change as its image, so a frame never draws a photo with another
        /// photo's cube.
        var pages: [RenderPage] = []
        /// Laid out at the size of the picture the pages make: one page's oriented size, or a spread's virtual one.
        var transform = ViewTransform(imageSize: .zero, viewSize: .zero)
        /// `background`, in linear light (the `_srgb` drawable encodes it).
        var background = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        /// The resampling keys (`upscale`, `downscale`, `lanczos-antiring`, `pixel-art`).
        var resample = ResampleSettings()
        /// The transparency keys (`transparency`, `checker-size`, `checker-colors`) and the window's backing scale.
        var transparency = TransparencySettings()
        var backingScale = 1.0
        /// The pan indicators (M4b spec §5): `pan-indicators` (with `P`'s session value), `pan-indicators-hide` and
        /// `-fade` in seconds, `pan-indicators-on-switch`, and how far (points) the thumbnail strip covers the view's
        /// bottom.
        var panMode = PanIndicatorMode.auto
        var panHide = 0.4
        var panFade = 0.25
        var panOnSwitch = false
        var panBottomInset = 0.0
        /// When the visible part of the picture last moved (`update`), on the `CACurrentMediaTime` clock; nil: never.
        var lastMotion: CFTimeInterval?
        /// The colour space of the photo on its way while no image is drawn (`expectColorSpace`); nil: none known.
        var expected: CGColorSpace?
        /// The photo is held back (`hold`): frames draw only the background, the layer already tagged for `image`.
        var held = false
        var generation = 0
        /// When the newest `update` arrived, for the input→present measurement (`LOUPE_DEBUG`).
        var inputTime: CFTimeInterval = 0
        /// Owned by the render thread: whether the link is (about to be) paused, and whether a wake-up
        /// block is already queued, so a burst of updates (a live resize) queues one wake-up, not hundreds.
        var paused = false
        var wakeQueued = false
        var runLoop: CFRunLoop?
        /// When recent `update`s arrived, for the late latch.
        var inputPhase = InputPhase()
        /// Set by `stop`: no change is taken any more and the render thread is on its way out.
        var stopped = false
        /// `LOUPE_DEBUG` only (windows spec §3.8): the session whose activation waits for its first sharp frame
        /// (`watchSharp`) and when it was activated; the generation of the last frame drawn at the level its zoom
        /// wants, nil when that frame was not.
        var sharpWatch: (session: Int, since: CFTimeInterval)?
        var sharpGeneration: Int?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: Snapshot())

    /// Frame statistics for the extended stats bar. Recorded only while `enabled` (the UI sets it while the
    /// bar is extended), so at rest and with the bar hidden or compact no presented handler is even added.
    private struct Measured {
        var enabled = false
        var stats = FrameStats()
        /// Presentation time of the previous presented frame; 0 until one is seen since enabling.
        var lastPresented: CFTimeInterval = 0
    }
    private let measured = OSAllocatedUnfairLock(initialState: Measured())
    private let layer: CAMetalLayer
    private let context: MetalContext

    // Render thread only.
    private var renderer: TileRenderer?
    private var link: CAMetalDisplayLink?
    private var drawnGeneration = -1   // the first callback always draws (clears whatever the layer had)
    /// The last drawn frame was in the middle of a colour fade (`mix` < 1): the next callback draws again, whatever
    /// the generation, so the frame at the fade's end (`mix` 1) is drawn too and the link idles only after it.
    private var drawnColorRunning = false
    /// The opacity of the pan indicators in the last drawn frame, 0 when it had none. Above 0 in `auto` the callbacks go
    /// on while it changes (the fade) or will change (the hold before it): see `metalDisplayLink`.
    private var drawnPanAlpha = 0.0
    private var idlePolicy = IdlePolicy()
    private var tagGate = TagGate<CGColorSpace>()
    private var framePeriod = FramePeriod()
    /// Set by the stop block (`stop`): the thread leaves its run loop.
    private var finished = false
    /// The latch never waits past this long before the callback's `targetTimestamp`, leaving time to
    /// encode and commit.
    private static let latchMargin: TimeInterval = 0.004
    /// Shorter latch delays are not worth a sleep.
    private static let minLatch: TimeInterval = 0.0005
    private static let noImageColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// Starts the render thread. The `TileRenderer` is created on it (for `layer.pixelFormat`, which must
    /// be an `_srgb` format), so the renderer never leaves that thread.
    init(layer: CAMetalLayer, context: MetalContext = .shared) {
        self.layer = layer
        self.context = context
        super.init()
        let thread = Thread { [self] in run() }
        thread.name = "Loupe render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Shows `pages` (up to two, left to right; empty: none) with `transform`, laid out at the size of the picture they
    /// make (one page: its oriented size and a rect of all of it, which draws as a single photo always has; two: the
    /// spread's virtual size), each page turned by its orientation and through its photo's colour cube (with the fade
    /// into it; nil: none), from the next display refresh on. Images and colours are one change, so no frame pairs a
    /// photo with another photo's cube. `transform.viewSize` must be the layer's `drawableSize` (set both together); a
    /// frame whose drawable still has the old size is skipped rather than drawn misregistered. Cheap and non-blocking: a
    /// lock-protected store plus, when the link is paused, one block queued on the render thread's run loop to resume it.
    func update(pages: [RenderPage], transform: ViewTransform) {
        let now = CACurrentMediaTime()
        let wake: CFRunLoop? = state.withLock { s in
            guard !s.stopped else { return nil }
            s.inputPhase.recordInput(at: now)
            // Motion for the pan indicators: the visible part, the drawn zoom or the picture's size changed; another
            // picture (a switch with a kept zoom) only with `pan-indicators-on-switch` (M4b spec §5.2).
            let old = s.transform
            if PanIndicators.isMotion(sameImage: Self.samePictures(pages, s.pages),
                                      imageSizeChanged: transform.imageSize != old.imageSize,
                                      scaleChanged: transform.drawnScale != old.drawnScale,
                                      visibleChanged: transform.visibleRect != old.visibleRect,
                                      onSwitch: s.panOnSwitch) {
                s.lastMotion = now
            }
            s.pages = pages
            s.transform = transform
            s.generation += 1
            s.inputTime = now
            guard s.paused, !s.wakeQueued, let runLoop = s.runLoop else { return nil }
            s.wakeQueued = true
            return runLoop
        }
        DebugLog.log("update gen \(state.withLock { $0.generation }) wake=\(wake != nil)")
        guard let wake else { return }
        CFRunLoopPerformBlock(wake, CFRunLoopMode.defaultMode.rawValue) { [self] in resume() }
        CFRunLoopWakeUp(wake)
    }

    /// Whether two page lists show the same images (by identity), page for page.
    private static func samePictures(_ a: [RenderPage], _ b: [RenderPage]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.image === $1.image }
    }

    /// The first page's image, else the second's: the photo the layer is tagged for (one colour space per layer).
    private static func leadImage(_ pages: [RenderPage]) -> TiledImage? {
        for page in pages { if let image = page.image { return image } }
        return nil
    }

    /// Draws only the background while `on`, the image kept for when it is let go (`launch-reveal`: a launch into
    /// full screen shows the photo once the window has settled, not during the system's animation). Any thread.
    func hold(_ on: Bool) {
        changeIfNeeded { s in
            guard s.held != on else { return false }
            s.held = on
            return true
        }
    }

    /// The colour around the picture from the next display refresh on (`background`). Any thread.
    func setBackground(_ color: BackgroundColor) {
        let c = color.linear
        change { $0.background = MTLClearColor(red: c.red, green: c.green, blue: c.blue, alpha: 1) }
    }

    /// The colour space of the photo being loaded while there is no image to draw (nil: none known). With no image the
    /// layer is tagged with it instead of Display P3, so when the pixels arrive the layer already carries their tag
    /// and they are drawn at once, not a refresh later (`retagIfNeeded`). Only the background is drawn meanwhile, in
    /// the space it would have next to the photo anyway. Any thread.
    func expectColorSpace(_ space: CGColorSpace?) {
        let wake: CFRunLoop? = state.withLock { s in
            guard !s.stopped, s.expected != space else { return nil }
            s.expected = space
            guard Self.leadImage(s.pages) == nil else { return nil }   // ignored while an image is drawn: no new frame
            s.generation += 1
            guard s.paused, !s.wakeQueued, let runLoop = s.runLoop else { return nil }
            s.wakeQueued = true
            return runLoop
        }
        guard let wake else { return }
        CFRunLoopPerformBlock(wake, CFRunLoopMode.defaultMode.rawValue) { [self] in resume() }
        CFRunLoopWakeUp(wake)
    }

    /// The resampling filters from the next display refresh on (a config reload changes them mid-session). Any thread.
    func setResampling(_ settings: ResampleSettings) {
        change { $0.resample = settings }
    }

    /// What shows through transparent pixels from the next display refresh on (a config reload changes it). Any thread.
    func setTransparency(_ settings: TransparencySettings) {
        change { $0.transparency = settings }
    }

    /// The window's backing scale (drawable px per point), for the checkerboard's cell size. Any thread.
    func setBackingScale(_ scale: Double) {
        change { $0.backingScale = scale }
    }

    /// The pan indicators' mode (`pan-indicators` or `P`'s session value) and timings, from the next display refresh on.
    /// Any thread; the same values again change nothing.
    func setPanIndicators(mode: PanIndicatorMode, hide: TimeInterval, fade: TimeInterval, onSwitch: Bool) {
        changeIfNeeded { s in
            guard s.panMode != mode || s.panHide != hide || s.panFade != fade || s.panOnSwitch != onSwitch else {
                return false
            }
            s.panMode = mode
            s.panHide = hide
            s.panFade = fade
            s.panOnSwitch = onSwitch
            return true
        }
    }

    /// How far (points) the thumbnail strip covers the bottom of the view: the bottom pill stands above it. Any thread;
    /// the same value again changes nothing.
    func setIndicatorBottomInset(_ points: Double) {
        changeIfNeeded { s in
            guard s.panBottomInset != points else { return false }
            s.panBottomInset = points
            return true
        }
    }

    /// Applies `body` to the snapshot as a new generation and wakes the paused link to draw it.
    private func change(_ body: (inout Snapshot) -> Void) {
        changeIfNeeded { body(&$0); return true }
    }

    /// `change`, but when `body` returns false (nothing changed) no new generation and no wake-up.
    private func changeIfNeeded(_ body: (inout Snapshot) -> Bool) {
        let wake: CFRunLoop? = state.withLock { s in
            guard !s.stopped, body(&s) else { return nil }
            s.generation += 1
            guard s.paused, !s.wakeQueued, let runLoop = s.runLoop else { return nil }
            s.wakeQueued = true
            return runLoop
        }
        guard let wake else { return }
        CFRunLoopPerformBlock(wake, CFRunLoopMode.defaultMode.rawValue) { [self] in resume() }
        CFRunLoopWakeUp(wake)
    }

    /// `LOUPE_DEBUG` (windows spec §3.8): logs `sharp <session> +<ms>` when the first frame drawn at the level the zoom
    /// wants is on glass, ms from `since`; `+0 ms (on screen)` when the frame on screen already is and nothing changed
    /// since. Adds no frame. Any thread.
    func watchSharp(session: Int, since: CFTimeInterval) {
        let onScreen = state.withLock { s -> Bool in
            guard !s.stopped else { return false }
            // Its levels may have been evicted in place since that frame (the cache's `evict(finerThan:)`).
            if s.sharpGeneration == s.generation, Self.leadImage(s.pages) != nil, !s.held,
               Self.isSharp(s.pages, s.transform) {
                s.sharpWatch = nil
                return true
            }
            s.sharpWatch = (session, since)
            return false
        }
        if onScreen { DebugLog.log("sharp \(session) +0 ms (on screen)") }
    }

    /// Whether `image` has the level `transform`'s zoom wants resident (`TileGrid.level(forScale:)`): drawn now, not
    /// stretched from a coarser one.
    private static func isSharp(_ image: TiledImage, _ transform: ViewTransform) -> Bool {
        image.finestResidentLevel.map {
            $0 <= TileGrid.level(forScale: transform.drawnScale, levelCount: image.grid.levelCount)
        } ?? false
    }

    /// `isSharp` of every page with an image, each at its own scale.
    private static func isSharp(_ pages: [RenderPage], _ transform: ViewTransform) -> Bool {
        pages.allSatisfy { page in
            guard let image = page.image else { return true }
            return isSharp(image, placement(page, image, transform)?.transform ?? transform)
        }
    }

    /// Where a page of a spread is drawn (`PagePlacement`); nil for a page whose rect is the transform's whole image,
    /// drawn with the transform itself, as a single photo always was.
    private static func placement(_ page: RenderPage, _ image: TiledImage, _ transform: ViewTransform) -> PagePlacement? {
        guard page.rect != CGRect(origin: .zero, size: transform.imageSize) else { return nil }
        let size = page.orientation.orientedSize(image.grid.imageSize)
        return PagePlacement(rect: page.rect, pageSize: CGSize(width: size.width, height: size.height), shared: transform)
    }

    /// Starts or stops recording per-frame GPU time and presentation intervals (`frameStats()`); the window
    /// starts empty each time it is turned on. Any thread.
    func setFrameStatsEnabled(_ on: Bool) {
        measured.withLock {
            guard $0.enabled != on else { return }
            $0 = Measured(enabled: on)
        }
    }

    /// A copy of the last 240 presented frames' statistics. Any thread.
    func frameStats() -> FrameStats { measured.withLock { $0.stats } }

    /// Ends the render thread (the window closes): from here on changes are ignored, and a block queued on the thread's
    /// run loop takes the display link off it, lets the renderer and the last snapshot go and leaves the loop, so the
    /// thread exits. Does not wait for that: a frame in flight finishes first on the render thread, which never waits
    /// for main. Any thread; a second call does nothing.
    func stop() {
        let runLoop: CFRunLoop? = state.withLock { s in
            guard !s.stopped else { return nil }
            s.stopped = true
            s.pages = []
            return s.runLoop   // nil: the thread has not reached its loop yet and sees `stopped` there
        }
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in shutDown() }
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: Render thread

    private func run() {
        renderer = TileRenderer(context: context, pixelFormat: layer.pixelFormat)
        renderer?.log = { DebugLog.log($0) }
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        if let latency = RenderTuning.current.frameLatency { link.preferredFrameLatency = Float(latency) }
        DebugLog.log("frame latency \(link.preferredFrameLatency), drawables \(layer.maximumDrawableCount)")
        link.delegate = self
        link.add(to: .current, forMode: .default)
        self.link = link
        // In the same critical section as `stop`'s check: either it finds the run loop and queues the stop block, or
        // the thread finds `stopped` here and ends at once.
        let stopped = state.withLock { s -> Bool in
            if !s.stopped { s.runLoop = CFRunLoopGetCurrent() }
            return s.stopped
        }
        if stopped { shutDown() }
        // A port keeps the run loop alive even if the link's source were removed: `run(mode:before:)` returns at
        // once on a run loop without sources, and this loop would then spin.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        while !finished { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
        DebugLog.log("render thread done")
    }

    /// The render thread's part of `stop`: the link off the run loop, the renderer and snapshot let go, the loop left
    /// (`CFRunLoopStop` ends the current `run(mode:before:)`, and `finished` the `while` around it).
    private func shutDown() {
        link?.invalidate()
        link = nil
        renderer = nil
        state.withLock { s in
            s.pages = []
            s.runLoop = nil
        }
        finished = true
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    private func resume() {
        state.withLock {
            $0.wakeQueued = false
            $0.paused = false
        }
        link?.isPaused = false
        DebugLog.log("resume")
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard !state.withLock({ $0.stopped }) else { return }   // the stop block is queued behind this callback
        // Late latch: wait (on this dedicated thread) until half a period away from the input phase, but
        // never closer than `latchMargin` to the deadline. The log line carries the callback's own time.
        let callbackTime = CACurrentMediaTime()
        let target = update.targetTimestamp
        let period = framePeriod.record(targetTimestamp: target)
        // The snapshot as of the callback is kept too (read only, no state change): this callback's
        // drawable has the drawableSize of this moment, which a resize during the latch may change.
        let (wanted, early) = state.withLock { s -> (TimeInterval, Snapshot) in
            (s.inputPhase.latchDelay(callbackAt: callbackTime, period: period), s)
        }
        let latch = min(wanted, target - Self.latchMargin - callbackTime)
        let latching = latch >= Self.minLatch
        DebugLog.log(String(format: "callback target %.4f present %.4f period %.2f ms latch %.1f ms",
                            target, update.targetPresentationTimestamp, period * 1000, latching ? latch * 1000 : 0))
        if latching { Self.wait(until: callbackTime + latch) }

        // Only after the latch is the snapshot read. The change check, the policy's decision and the
        // `paused` flag are one critical section: an `update` either lands before it (and is seen as a
        // change) or after it (and, if the policy said pause, sees `paused` and queues `resume`, which
        // runs on this thread after us). No change is ever missed, and `paused` is only ever set when the
        // link is really about to pause. During the latch `paused` is false, so an `update` then queues
        // no wake-up and is simply seen here.
        //
        // Pan indicators on screen in `auto`: a callback whose opacity differs from the drawn one draws (the fade); one
        // with the same opacity, still to fade, keeps the link awake without drawing (the hold before the fade, longer
        // than the idle grace).
        let (snapshot, action) = state.withLock { s -> (Snapshot?, IdlePolicy.Action) in
            guard !s.stopped else { return (nil, .skip) }   // stopped during the latch: the stop block comes next
            var panChanged = false, panHolding = false
            if drawnPanAlpha > 0, s.panMode == .auto {
                let alpha = PanIndicators.alpha(mode: .auto, now: CACurrentMediaTime(), lastMotion: s.lastMotion,
                                                hide: s.panHide, fade: s.panFade)
                panChanged = alpha != drawnPanAlpha
                panHolding = !panChanged
            }
            var action = idlePolicy.frame(changed: s.generation != drawnGeneration || drawnColorRunning || panChanged,
                                          at: target)
            if action == .pause, panHolding { action = .skip }
            if action == .pause { s.paused = true }
            return (action == .draw ? s : nil, action)
        }
        DebugLog.log(latching ? String(format: "latched %.2f ms late: ", (CACurrentMediaTime() - callbackTime - latch) * 1000) + "\(action)"
                              : "latched: \(action)")
        switch action {
        case .draw:
            guard let snapshot else { break }
            let drawable = update.drawable
            let choice = LatchedFrame.choose(
                drawable: CGSize(width: drawable.texture.width, height: drawable.texture.height),
                latched: snapshot.transform.viewSize,
                early: latching ? early.transform.viewSize : nil,
                earlyIsNew: early.generation != drawnGeneration)
            if choice == .early {
                // Drawn now, the latched one next callback (`drawnGeneration` stays behind it).
                DebugLog.log("resized during latch: drawing pre-latch gen \(early.generation), not gen \(snapshot.generation)")
            }
            draw(choice == .early ? early : snapshot, drawable: drawable)
        case .skip:
            break   // stay awake: a change within the grace period is drawn by the next callback
        case .pause:
            link.isPaused = true
            DebugLog.log("idle: display link paused")
        }
    }

    /// Blocks this (dedicated) thread until `deadline` on the `CACurrentMediaTime` clock, to within
    /// about 0.1 ms. The kernel lets a timed wait of a non-real-time thread wake late by a share of its
    /// length (measured: 12 % in the app, 25 % from a terminal, so an 8 ms wait woke 1–2 ms late), so
    /// this waits for 80 % of what remains, again and again: each step lands at or before the deadline
    /// and the remainder shrinks geometrically (one or two extra wake-ups).
    private static func wait(until deadline: CFTimeInterval) {
        while true {
            let remaining = deadline - CACurrentMediaTime()
            guard remaining > 0.0001 else { return }
            mach_wait_until(mach_absolute_time() + UInt64(remaining * 0.8 * ticksPerSecond))
        }
    }

    private static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    private func draw(_ snapshot: Snapshot, drawable: CAMetalDrawable) {
        let viewSize = snapshot.transform.viewSize
        guard viewSize.width >= 1, viewSize.height >= 1 else {
            drawnGeneration = snapshot.generation   // no view yet (before the first layout): nothing to draw
            drawnColorRunning = false
            drawnPanAlpha = 0
            return
        }
        // Before anything else: a retag defers this callback (see `retagIfNeeded`).
        guard retagIfNeeded(for: Self.leadImage(snapshot.pages)?.colorSpace ?? snapshot.expected ?? Self.noImageColorSpace)
        else { return }
        let target = drawable.texture
        guard target.width == Int(viewSize.width), target.height == Int(viewSize.height) else {
            // A resize is in flight: this drawable predates the new drawableSize. Stay dirty; the next
            // callback gets a drawable of the right size.
            DebugLog.log("skip: drawable \(target.width)x\(target.height) != view \(viewSize)")
            return
        }
        guard let renderer, let commands = context.queue.makeCommandBuffer() else { return }
        commands.label = "frame \(snapshot.generation)"
        renderer.background = snapshot.background
        renderer.resample = snapshot.resample
        renderer.transparency = snapshot.transparency
        renderer.backingScale = snapshot.backingScale
        let drawTime = CACurrentMediaTime()
        // Held: tagged for the image above all the same, so no retag on reveal; only the background is drawn.
        let shown = snapshot.held ? nil : Self.leadImage(snapshot.pages)
        drawPages(snapshot, at: drawTime, into: commands, target: target)
        // The pan indicators over the finished frame, in the drawable itself (M4b spec §5.3); nothing encoded at 0.
        let panAlpha = PanIndicators.alpha(mode: snapshot.panMode, now: drawTime, lastMotion: snapshot.lastMotion,
                                           hide: snapshot.panHide, fade: snapshot.panFade)
        let pills = panAlpha > 0 && shown != nil
            ? PanIndicators.pills(for: snapshot.transform, backingScale: snapshot.backingScale,
                                  bottomInsetPoints: snapshot.panBottomInset)
            : []
        renderer.encodePanIndicators(pills, alpha: Float(panAlpha), backingScale: snapshot.backingScale,
                                     into: commands, target: target)
        if DebugLog.isEnabled {
            // The first frame at the level the zoom wants after an activation (`watchSharp`).
            let generation = snapshot.generation
            let sharp = shown != nil && Self.isSharp(snapshot.pages, snapshot.transform)
            // The watch as it is now, under the same lock: one set since this snapshot was taken is not missed.
            let watch = state.withLock { s in
                s.sharpGeneration = sharp ? generation : nil
                return sharp ? s.sharpWatch : nil
            }
            if let watch {
                drawable.addPresentedHandler { [state] presented in
                    let at = presented.presentedTime
                    guard at > 0 else { return }   // not shown: a later frame reports
                    let first = state.withLock { s -> Bool in
                        guard s.sharpWatch?.since == watch.since else { return false }
                        s.sharpWatch = nil
                        return true
                    }
                    if first { DebugLog.log(String(format: "sharp \(watch.session) +%.0f ms", (at - watch.since) * 1000)) }
                }
            }
        }
        if DebugLog.isEnabled {
            let generation = snapshot.generation
            commands.addCompletedHandler { cb in
                DebugLog.log(String(format: "gpu done gen \(generation) %.2f ms", (cb.gpuEndTime - cb.gpuStartTime) * 1000))
            }
        }
        if DebugLog.isEnabled {
            // Input→present (spec §6.1): from the newest `update` in this snapshot to the drawable on glass.
            let generation = snapshot.generation, input = snapshot.inputTime
            drawable.addPresentedHandler { presented in
                let at = presented.presentedTime
                DebugLog.log(at > 0 ? String(format: "latency gen \(generation): input→present %.2f ms present %.4f", (at - input) * 1000, at)
                                    : "latency gen \(generation): not presented")
            }
        }
        if measured.withLock({ $0.enabled }) {
            let period = framePeriod.period, input = snapshot.inputTime
            // The GPU time goes through a box filled by the completed handler, which Metal hands the buffer: the presented
            // handler must not hold `commands` (buffer → drawable → handler → buffer, a cycle broken on another thread
            // while Metal completes the buffer). A frame on glass before its completion is seen has 0, as before.
            let gpuTime = OSAllocatedUnfairLock(initialState: 0.0)
            commands.addCompletedHandler { cb in
                let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                gpuTime.withLock { $0 = ms }
            }
            drawable.addPresentedHandler { [measured] presented in
                let at = presented.presentedTime
                guard at > 0 else { return }   // not shown
                let gpuMs = gpuTime.withLock { $0 }
                measured.withLock { m in
                    guard m.enabled else { return }
                    let previous = m.lastPresented
                    let gap = previous > 0 ? at - previous : 0
                    m.lastPresented = at   // also for a frame without GPU times, so the next interval is one frame
                    guard gpuMs > 0 else { return }
                    // Its update arrived before the previous frame was on glass: it waited across the whole gap, so a
                    // long gap is a stall rather than the link idling (FrameStats.activeGap).
                    m.stats.record(gpuMs: gpuMs, interval: max(gap, 0), period: period, pending: previous > 0 && input < previous)
                }
            }
        }
        // Always committed after encode: the renderer's instance ring is released by completion handlers.
        commands.present(drawable)
        commands.commit()
        drawnGeneration = snapshot.generation
        drawnColorRunning = snapshot.pages.contains { $0.color?.isRunning(at: drawTime) ?? false }
        drawnPanAlpha = pills.isEmpty ? 0 : panAlpha
        let t = snapshot.transform
        DebugLog.log("frame \(snapshot.generation): \(target.width)x\(target.height) scale \(t.scale) mode \(t.mode) "
                     + String(format: "center %.4f,%.4f", t.center.x, t.center.y)
                     + " image \(Int(t.imageSize.width))x\(Int(t.imageSize.height))" + (snapshot.held ? " held" : ""))
    }

    /// The pages into `target`, each through its own colour cube: the first clears it to the background and draws as a
    /// single photo always has; a page after it draws only into its viewport (`PagePlacement`), the target loaded, so a
    /// page off screen or without an image leaves its part to the background. No pages, or held: just the background.
    private func drawPages(_ snapshot: Snapshot, at now: Double, into commands: MTLCommandBuffer, target: MTLTexture) {
        guard let renderer else { return }
        guard !snapshot.held, !snapshot.pages.isEmpty else {
            renderer.color = nil
            renderer.encode(image: nil, transform: snapshot.transform, into: commands, target: target)
            return
        }
        for (index, page) in snapshot.pages.enumerated() {
            let first = index == 0
            var transform = snapshot.transform, viewport: CGRect?
            if let image = page.image, let place = Self.placement(page, image, snapshot.transform) {
                transform = place.transform
                viewport = place.viewport
                if !first, place.viewport.isEmpty { continue }   // off screen
            } else if !first, page.image == nil {
                continue   // nothing to draw: its part keeps the first page's background
            }
            renderer.color = colorFrame(page.color, at: now)
            renderer.encode(image: page.image, transform: transform, orientation: page.orientation, into: commands,
                            target: target, viewport: first ? nil : viewport, clears: first)
        }
    }

    /// The cube of one frame at `now`: nil when the photo is shown uncorrected (no cube and no fade out running), the
    /// pipelines of before M3c. A fade to no cube goes to `ColorLUT.identity`; one from no cube starts at the identity
    /// (`from` nil, `ColorFrame`). Past its end a fade is a plain `mix` 1 frame, so `from` is dropped.
    private func colorFrame(_ shown: ShownColor<ColorLUT>?, at now: Double) -> ColorFrame? {
        guard let shown else { return nil }
        let running = shown.isRunning(at: now)
        guard shown.cube != nil || running else { return nil }
        return ColorFrame(lut: shown.cube ?? ColorLUT.identity(context: context), from: running ? shown.from : nil,
                          mix: Float(shown.mix(at: now)))
    }

    /// Pixels are stored in the image's own colour space (spec §4.3), so the layer is tagged with it;
    /// with no image, with the coming photo's (`expectColorSpace`), else Display P3. Returns whether the layer already carried the
    /// tag, i.e. whether this callback's drawable may be drawn into (`TagGate` says why it may not
    /// otherwise: drawables keep the colour space they were vended with). When it returns false the
    /// snapshot stays undrawn (`drawnGeneration` is untouched), so the next callback counts it as a change
    /// again: the idle policy does not pause and that callback's drawable is vended after the retag.
    private func retagIfNeeded(for space: CGColorSpace) -> Bool {
        guard tagGate.decide(required: space) == .retagAndDefer else { return true }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.colorspace = space
        CATransaction.commit()
        DebugLog.log("colour space: \(space.name.map { $0 as String } ?? "unnamed ICC")")
        DebugLog.log("colour space changed → redraw next frame")
        return false
    }
}
