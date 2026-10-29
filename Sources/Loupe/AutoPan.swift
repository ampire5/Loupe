import AppKit
import LoupeCore

/// Debug aid for scripted latency runs (spec §6.1), enabled by `LOUPE_AUTOPAN=<seconds>` with `LOUPE_DEBUG` set: once the first photo
/// is shown at full resolution and the view size has been steady for a settle delay (a full-screen transition), it switches to
/// 100 % (the `1` key; `LOUPE_AUTOPAN_SCALE` picks another zoom) and pans along `AutoPanPath` at a steady 120 Hz through the same main-thread path as a
/// drag (`ViewerView.debugDrag`, the rubber band included → `session.transform =` → `RenderLoop.update`), then quits
/// the app. `LOUPE_AUTOPAN_MODE=zoom` zooms instead, from fit to `LOUPE_AUTOPAN_SCALE` (2 = 200 % by default in that
/// mode) and back about the view centre (`AutoZoomPath`), through the same maths as a pinch; `glide` flings every
/// 2.5 s, alternately right-down and left-up at 7000 × 2000 px/s, as a released drag (`ViewerView.debugRelease`), so
/// the frames come from the main-thread inertia link, and the longer glides bounce off an edge; `keys` presses zoom keys
/// (`ViewerView.debugPerform`, `+ + +` as a burst) and springs a zoom stretch back (`debugSpringBack`) from `keySteps`,
/// for the zoom animation's frames in the log; `seeded` steps far (`LOUPE_AUTOPAN_SEEDED_STEP`, 25 by default) with
/// `key-step=thumb` every 2 s, presses a zoom key the tick the seeded thumbnail is on screen (100 %, or Fit when at
/// 100 % already), and 0.8 s later logs the mode the photo ended in against the one asked for. It measures update→present,
/// not HID→present: the event system's own delay is not included. If no photo shows within `giveUp`, it logs a
/// warning and quits, so a scripted run never hangs.
@MainActor final class AutoPan {
    private let seconds: Double
    private let scale: Double
    private let mode: AutoPanPath.Mode
    private var flings = 0
    /// `LOUPE_AUTOPAN_PANEL_TOGGLE=<seconds>`: the info panel is toggled (⌘I) that often during the run.
    private let panelToggle = ProcessInfo.processInfo.environment["LOUPE_AUTOPAN_PANEL_TOGGLE"].flatMap(Double.init)
    private var toggles = 0
    /// `LOUPE_AUTOPAN_SUBJECTS=1`: Show Subjects (⇧G) on for the run, from the start (owner, 2026-10-28: its cost per
    /// frame of a pan or a zoom).
    private let showSubjects = ProcessInfo.processInfo.environment["LOUPE_AUTOPAN_SUBJECTS"] == "1"
    /// `step` mode: when the next photo step is due, its direction, and an LCG for the delays (the same run each time).
    private var nextStep = 0.5
    private var stepDirection = 1
    private var random: UInt64 = 0x9E3779B97F4A7C15
    private var steps = 0
    private var zoomPath: AutoZoomPath?
    /// `keys` mode: what happens when (seconds after the start), and how many of them are done.
    private static let keySteps: [(at: Double, key: KeyAction?)] = [
        (0.5, .actual100), (1.5, .fit), (2.5, .zoomIn), (2.55, .zoomIn), (2.6, .zoomIn), (3.5, .toggleFitActual),
        (4.5, .fitWidth), (5.5, .fit), (6.5, nil), (7.5, .actual400), (8.5, nil), (9.5, .fit),
    ]
    private var keyStepsDone = 0
    /// `seeded` mode: the cycle, when its step was made, the key pressed on the thumbnail and when, the results.
    private let seededStep = ProcessInfo.processInfo.environment["LOUPE_AUTOPAN_SEEDED_STEP"].flatMap(Int.init) ?? 25
    private var seededCycles = 0
    private var seededStepAt: Double?
    private var seededKey: (key: KeyAction, want: ZoomMode, at: Double)?
    private var seededResults = (ok: 0, wrong: 0, skipped: 0)
    private let controller: ViewerWindowController
    private var timer: DispatchSourceTimer?
    private var readyAt: CFTimeInterval?
    private var readyViewSize: CGSize?
    private let created = CACurrentMediaTime()
    private var start: CFTimeInterval?
    private var path: AutoPanPath?
    private var applied = CGVector.zero
    private static let settle: CFTimeInterval = 2
    private static let rate = 120.0
    private static let giveUp: CFTimeInterval = 30

    init(seconds: Double, scale: Double = 1, mode: AutoPanPath.Mode = .pan, controller: ViewerWindowController) {
        self.seconds = seconds
        self.scale = scale
        self.mode = mode
        self.controller = controller
    }

    func begin() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now(), repeating: 1 / Self.rate, leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let session = controller.session
        guard let start, let path else {
            // Waiting: the photo on screen, its full resolution resident, nothing loading, the view size steady.
            let viewSize = session.transform.viewSize
            guard let image = session.image, image.finestResidentLevel == 0, session.loadingName == nil,
                  viewSize.width > 0 else {
                readyAt = nil
                if now - created >= Self.giveUp { finish("autopan: warning: no photo shown after \(Int(Self.giveUp)) s, quitting") }
                return
            }
            if readyAt == nil || readyViewSize != viewSize { readyAt = now; readyViewSize = viewSize }
            guard let readyAt, now - readyAt >= Self.settle else { return }
            if mode == .keys || mode == .seeded {
                controller.viewerView.debugPerform(.fit)
            } else if mode == .zoom {
                session.transform = session.transform.withMode(.fit)
                zoomPath = AutoZoomPath(low: session.transform.fitScale, high: scale)
            } else {
                session.transform = session.transform.withMode(.actual(scale))
            }
            self.path = AutoPanPath(viewSize: session.transform.viewSize)
            self.start = now
            if showSubjects, !controller.viewerView.subjectOverlayView.isOn { controller.toggleSubjects(nil) }
            DebugLog.log("autopan start \(seconds) s \(mode)\(mode == .zoom ? " fit…" : " at ")×\(scale), view \(session.transform.viewSize)")
            return
        }
        let t = now - start
        guard t < seconds else {
            if mode == .seeded {
                DebugLog.log("autopan seeded summary: \(seededResults.ok) ok, \(seededResults.wrong) wrong, "
                             + "\(seededResults.skipped) skipped (no thumbnail on screen)")
            }
            finish("autopan end")
            return
        }
        if let panelToggle, panelToggle > 0, t >= Double(toggles + 1) * panelToggle {
            toggles += 1
            DebugLog.log("autopan panel toggle \(toggles)")
            controller.toggleInfoPanel(nil)
        }
        if let zoomPath {
            let view = session.transform.viewSize
            session.transform = session.transform.zoomed(toScale: zoomPath.scale(at: t),
                                                         anchor: CGPoint(x: view.width / 2, y: view.height / 2))
            return
        }
        if mode == .keys {
            // nil: a pinch held 1.2× past the upper zoom limit and released.
            while keyStepsDone < Self.keySteps.count, t >= Self.keySteps[keyStepsDone].at {
                let key = Self.keySteps[keyStepsDone].key
                keyStepsDone += 1
                DebugLog.log("autopan key \(key.map { "\($0)" } ?? "spring back")")
                if let key { controller.viewerView.debugPerform(key) } else { controller.viewerView.debugSpringBack(factor: 1.2) }
            }
            return
        }
        if mode == .seeded {
            seededTick(at: t)
            return
        }
        if mode == .glide {
            guard t >= Double(flings) * 2.5 else { return }
            let sign: Double = flings % 2 == 0 ? 1 : -1
            flings += 1
            DebugLog.log("autopan fling \(flings)")
            controller.viewerView.debugRelease(velocity: CGVector(dx: 7000 * sign, dy: 2000 * sign))
            return
        }
        if mode == .step, t >= nextStep {
            // Delays from a burst (one tick) to a second, so steps land while a photo is loading, uploading or shown.
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let delays = [0.0, 0.0, 0.05, 0.15, 0.15, 0.4, 0.4, 1.0]
            let r = Int(random >> 33)
            nextStep = t + delays[r % delays.count]
            if r % 10 < 3 { stepDirection = -stepDirection }
            steps += 1
            if !controller.session.go(by: stepDirection, wait: Settings.shared.config.keyStep) {
                stepDirection = -stepDirection
            }
            DebugLog.log("autopan step \(steps) by \(stepDirection)")
        }
        let target = path.offset(at: t)
        let delta = CGVector(dx: target.dx - applied.dx, dy: target.dy - applied.dy)
        applied = target
        controller.viewerView.debugDrag(by: delta)
    }

    /// One tick of `seeded` mode (see the type's comment).
    private func seededTick(at t: Double) {
        let session = controller.session
        if let k = seededKey {
            guard t - k.at >= 0.8 else { return }
            let mode = session.transform.mode
            let ok = mode == k.want && session.zoomTarget == nil
            if ok { seededResults.ok += 1 } else { seededResults.wrong += 1 }
            DebugLog.log("autopan seeded check \(seededCycles): key \(k.key) -> mode \(mode), want \(k.want): "
                         + (ok ? "ok" : "WRONG") + (session.showsThumbnailOnly ? " (still the thumbnail)" : ""))
            seededKey = nil
            seededStepAt = nil
            return
        }
        if let at = seededStepAt {
            if session.showsThumbnailOnly {
                let atActual = session.transform.mode == .actual(1)
                let key: KeyAction = atActual ? .fit : .actual100
                DebugLog.log("autopan seeded key \(key) on the thumbnail, \(Int(((t - at) * 1000).rounded())) ms after the step")
                controller.viewerView.debugPerform(key)
                seededKey = (key, atActual ? .fit : .actual(1), t)
            } else if t - at >= 1 {
                seededResults.skipped += 1
                DebugLog.log("autopan seeded cycle \(seededCycles): no thumbnail on screen, skipped")
                seededStepAt = nil
            }
            return
        }
        guard t >= Double(seededCycles) * 2 + 0.5 else { return }
        seededCycles += 1
        if !session.go(by: seededStep, wait: .thumb) {
            _ = session.go(by: -seededStep * 4, wait: .thumb) || session.go(by: -seededStep, wait: .thumb)
        }
        DebugLog.log("autopan seeded step \(seededCycles) to \(session.playlist?.current.lastPathComponent ?? "-")")
        seededStepAt = t
    }

    private func finish(_ message: String) {
        DebugLog.log(message)
        timer?.cancel()
        timer = nil
        NSApp.terminate(nil)
    }
}
