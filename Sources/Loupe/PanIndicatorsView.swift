import AppKit
import LoupeCore
import QuartzCore

/// The pan position pills (M4b spec §5) in a view of their own over the window's content: above the strip and the info
/// panel, below the toast and the cheat sheet, framed to the container (full screen: the screen; windowed: below the
/// stats bar when it shows). So the pills sit at the window's edge whatever the strip's placement, which the viewer's
/// own frame could not give (in the `beside` placement the viewer ends at the strip's top). Not a sublayer of the
/// Metal layer, so the picture keeps its direct-to-display path; takes no clicks.
///
/// The pills' length and place come from the viewer's transform (`PanIndicators.pills`), their track from this view's
/// bounds. Their opacity follows `pan-indicators`: `always` 1, `no` 0, `auto` 1 for `pan-indicators-hide` after the
/// last motion, then a linear fade over `pan-indicators-fade` run by Core Animation (one keyframe animation per motion,
/// nothing at rest).
@MainActor final class PanIndicatorsView: NSView {
    /// Holds the pill layers; its opacity is the pills' alpha.
    private let pillsLayer = CALayer()
    private var pillLayers: [CALayer] = []
    /// What the viewer last handed the render loop (`show`): motion is told against it, and the pills are its.
    private var pages = RenderPages.none
    private var transform = ViewTransform(imageSize: .zero, viewSize: .zero)
    /// When the visible part of the picture last moved, on the `CACurrentMediaTime` clock; nil: never.
    private var lastMotion: CFTimeInterval?
    private var mode = PanIndicatorMode.auto
    private var hide: TimeInterval = 0.4
    private var fade: TimeInterval = 0.25
    private var onSwitch = false

    /// `launch-reveal` holds the photo back: no pills while only the background is drawn.
    var held = false {
        didSet { if held != oldValue { applyOpacity() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        pillsLayer.opacity = 0
        layer?.addSublayer(pillsLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `pan-indicators` (with `P`'s session value) and its timings; the same values again change nothing.
    func setMode(_ mode: PanIndicatorMode, hide: TimeInterval, fade: TimeInterval, onSwitch: Bool) {
        guard mode != self.mode || hide != self.hide || fade != self.fade || onSwitch != self.onSwitch else { return }
        self.mode = mode
        self.hide = hide
        self.fade = fade
        self.onSwitch = onSwitch
        applyOpacity()
    }

    /// The pages and transform the viewer just handed the render loop. Motion (M4b spec §5.2: the visible part, the drawn
    /// zoom or the picture's size changed on the same picture; another picture only with `pan-indicators-on-switch`)
    /// shows the pills in `auto` and restarts their fade.
    func show(_ pages: RenderPages, transform: ViewTransform) {
        let old = self.transform
        let motion = PanIndicators.isMotion(sameImage: pages.samePictures(as: self.pages),
                                            imageSizeChanged: transform.imageSize != old.imageSize,
                                            scaleChanged: transform.drawnScale != old.drawnScale,
                                            visibleChanged: transform.visibleRect != old.visibleRect,
                                            onSwitch: onSwitch)
        let hadImage = self.pages.leadImage != nil
        self.pages = pages
        self.transform = transform
        if motion { lastMotion = CACurrentMediaTime() }
        updatePills()
        if motion || hadImage != (pages.leadImage != nil) { applyOpacity() }
    }

    override func layout() {
        super.layout()
        updatePills()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePills()   // the outline is one physical pixel
    }

    /// The pill layers at the pills' rects in this view's bounds, without implicit animations.
    private func updatePills() {
        let size = bounds.size
        let pills = PanIndicators.pills(for: transform, backingScale: 1, in: CGRect(origin: .zero, size: size))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillsLayer.frame = bounds
        while pillLayers.count < pills.count {
            let pill = CALayer()
            pill.backgroundColor = NSColor(white: 0, alpha: Self.fillAlpha).cgColor
            pill.borderColor = NSColor(white: 1, alpha: Self.lineAlpha).cgColor
            pillsLayer.addSublayer(pill)
            pillLayers.append(pill)
        }
        while pillLayers.count > pills.count { pillLayers.removeLast().removeFromSuperlayer() }
        let outline = 1 / max(window?.backingScaleFactor ?? 1, 1)
        for (layer, pill) in zip(pillLayers, pills) {
            let r = pill.rect   // origin top-left; the layer's is bottom-left
            layer.frame = CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
            layer.cornerRadius = min(r.width, r.height) / 2
            layer.borderWidth = outline
        }
        CATransaction.commit()
    }

    /// The pills' opacity now, and in `auto` the rest of their hold and fade as one Core Animation keyframe animation
    /// from the last motion (`PanIndicators.alpha`'s curve); none at rest.
    private func applyOpacity() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillsLayer.removeAnimation(forKey: Self.fadeKey)
        let visible = !held && pages.leadImage != nil
        switch visible ? mode : .no {
        case .no:
            pillsLayer.opacity = 0
        case .always:
            pillsLayer.opacity = 1
        case .auto:
            pillsLayer.opacity = 0   // where the fade ends
            let total = hide + fade
            if let lastMotion, total > 0,
               PanIndicators.alpha(mode: .auto, now: CACurrentMediaTime(), lastMotion: lastMotion, hide: hide,
                                   fade: fade) > 0 {
                let animation = CAKeyframeAnimation(keyPath: "opacity")
                animation.values = [1, 1, 0]
                animation.keyTimes = [0, NSNumber(value: hide / total), 1]
                animation.duration = total
                animation.beginTime = pillsLayer.convertTime(lastMotion, from: nil)
                pillsLayer.add(animation, forKey: Self.fadeKey)
            }
        }
        CATransaction.commit()
    }

    private static let fadeKey = "fade"
    /// The pills' body (black) and outline (white) opacity, spec §5.1.
    private static let fillAlpha: CGFloat = 0.5
    private static let lineAlpha: CGFloat = 0.6
}
