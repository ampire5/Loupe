import AppKit
import HomeChrome

/// A scroll edge effect (HIG: Scroll views): what stands between a picture that goes on under a bar and the bar's text, so
/// the eye finds no edge where the picture meets the bar. Along one edge of the window, over the picture, and behind
/// whatever the owner puts on top. It takes no event.
///
/// `soft`: the picture blurs more and more towards the edge, with a little tint, and is gone into it without a line: a
/// long fade, as Photos' toolbar has over a picture. `hard`: the same blur and a stronger tint that stop at a short, crisp
/// edge with a hairline, for text that must stay readable on any picture.
///
/// The blur grows by steps nobody sees: `blurBands` views of the system's material, nested from the edge, each seeing
/// what the larger ones below it made, so the picture has been blurred more times the nearer the edge it is, and each
/// with an opacity picked so that the blur's coverage falls smoothly (a backdrop blur cannot sit inside a masked layer,
/// so a mask on one view would not do). The tint is one layer with a gradient mask.
@MainActor final class EdgeEffectView: NSView {
    enum Style { case soft, hard }

    /// The edge's part the content stands on, and what fades below it (`hard`: only a short fall).
    let solidHeight: CGFloat
    private let softFadeHeight: CGFloat
    private static let hardFadeHeight: CGFloat = 5
    private static let blurBands = 12
    /// The most of the picture the blur takes at the edge: some of it stays sharp under the tint. With so many bands
    /// each step of the material's own tint is a few per cent, which the eye does not find.
    private static let blurCover = 0.8

    var style = Style.soft { didSet { if style != oldValue { relayout() } } }
    /// The bar is on the bottom edge, the fade above it.
    var atBottom = false { didSet { if atBottom != oldValue { relayout() } } }
    var blurs = true { didSet { for band in bands { band.isHidden = !blurs } } }
    /// The tint's strength at the edge, 0...1.
    var tintOpacity: CGFloat = 0.6 { didSet { applyTint() } }
    /// What the owner puts on the tint (the progress fill): it fades with it.
    let tintView = NSView()

    private var bands: [NSVisualEffectView] = []
    private let tintFade = CAGradientLayer()
    private let hairline = CALayer()
    private var laidOutFor: (Style, Bool)?

    var fadeHeight: CGFloat { style == .soft ? softFadeHeight : Self.hardFadeHeight }
    var height: CGFloat { solidHeight + fadeHeight }
    /// The part of the frame the content stands on.
    var solidFrame: NSRect {
        atBottom ? NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: solidHeight)
                 : NSRect(x: frame.minX, y: frame.maxY - solidHeight, width: frame.width, height: solidHeight)
    }

    init(solidHeight: CGFloat, softFadeHeight: CGFloat) {
        self.solidHeight = solidHeight
        self.softFadeHeight = softFadeHeight
        super.init(frame: .zero)
        for _ in 0..<Self.blurBands {
            let band = NSVisualEffectView()
            band.material = .hudWindow
            band.blendingMode = .withinWindow
            band.state = .active
            band.appearance = NSAppearance(named: .darkAqua)
            addSubview(band)
            bands.append(band)
        }
        tintView.wantsLayer = true
        tintView.layer?.mask = tintFade
        addSubview(tintView)
        hairline.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        wantsLayer = true
        layer?.addSublayer(hairline)
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyTint() {
        tintView.layer?.backgroundColor = Chrome.Palette.overMedia.glassTint.withAlphaComponent(tintOpacity).cgColor
    }

    private func relayout() {
        laidOutFor = nil
        needsLayout = true
    }

    /// How much of the effect there is at `depth` points from the edge, 1 over the content and a cosine fall below it.
    private func coverage(atDepth depth: CGFloat) -> Double {
        guard depth > solidHeight else { return 1 }
        let t = min(1, Double((depth - solidHeight) / max(fadeHeight, 1)))
        return 0.5 * (1 + cos(Double.pi * t))
    }

    /// The opacity of each band, outermost (the tallest) first, so that the coverage at each depth is the target's: where
    /// bands 0...k are in, `1 - Π(1 - a)` is the target at the middle of that stretch.
    private func bandOpacities() -> [CGFloat] {
        let count = bands.count
        let heights = (0..<count).map { solidHeight + fadeHeight * CGFloat(count - 1 - $0) / CGFloat(count - 1) }
        var result: [CGFloat] = []
        var covered = 0.0
        for k in 0..<count {
            let lower = k + 1 < count ? heights[k + 1] : 0
            let middle = (heights[k] + lower) / 2
            // At the stretch the band shares with the larger ones: the target's coverage, of the most the blur takes.
            let target = max(covered, Self.blurCover * coverage(atDepth: middle))
            let opacity = target >= 1 ? 1 : (target - covered) / (1 - covered)
            result.append(CGFloat(max(0, min(1, opacity))))
            covered = target
        }
        return result
    }

    private func bandHeights() -> [CGFloat] {
        let count = bands.count
        return (0..<count).map { solidHeight + fadeHeight * CGFloat(count - 1 - $0) / CGFloat(count - 1) }
    }

    /// The tint's fade: solid under the content, then the same fall.
    private func applyTintFade() {
        let total = max(height, 1)
        let steps = 9
        var colors: [CGColor] = [], locations: [NSNumber] = []
        for i in 0...steps {
            let depth = solidHeight + fadeHeight * CGFloat(i) / CGFloat(steps)
            colors.append(NSColor(white: 0, alpha: coverage(atDepth: depth)).cgColor)
            locations.append(NSNumber(value: Double(depth / total)))
        }
        colors.insert(NSColor(white: 0, alpha: 1).cgColor, at: 0)
        locations.insert(0, at: 0)
        tintFade.colors = colors
        tintFade.locations = locations
        // Layer coordinates run upwards: the top edge is y = 1.
        tintFade.startPoint = CGPoint(x: 0.5, y: atBottom ? 0 : 1)
        tintFade.endPoint = CGPoint(x: 0.5, y: atBottom ? 1 : 0)
    }

    override func layout() {
        super.layout()
        tintView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintFade.frame = tintView.bounds
        if laidOutFor?.0 != style || laidOutFor?.1 != atBottom {
            laidOutFor = (style, atBottom)
            applyTintFade()
            let opacities = bandOpacities()
            let heights = bandHeights()
            for (band, (opacity, bandHeight)) in zip(bands, zip(opacities, heights)) {
                band.alphaValue = opacity
                band.isHidden = !blurs
                // `bounds.height` can be a little under `height` while the owner sizes the view: the bands follow the edge.
                band.frame = NSRect(x: 0, y: atBottom ? 0 : bounds.height - bandHeight, width: bounds.width, height: bandHeight)
            }
            hairline.isHidden = style != .hard
        } else {
            for (band, bandHeight) in zip(bands, bandHeights()) {
                band.frame = NSRect(x: 0, y: atBottom ? 0 : bounds.height - bandHeight, width: bounds.width, height: bandHeight)
            }
        }
        // The hard edge's hairline lies on the inner edge of the tint.
        hairline.frame = NSRect(x: 0, y: atBottom ? height - 1 : 0, width: bounds.width, height: 1)
        CATransaction.commit()
    }
}
