import AppKit
import HomeChrome
import QuartzCore

/// `strip-loading-indicator=yes` (M2.5 spec §5.2): a small spinner in the viewer's bottom-right corner while the
/// photo on screen is only its stretched thumbnail. A view of its own over the viewer, not a sublayer of the Metal
/// layer, so the picture keeps its direct-to-display path (spec §2.1); one `CAShapeLayer` arc turned by a Core
/// Animation rotation, so spinning costs the main thread nothing.
@MainActor final class LoadingIndicator: NSView {
    static let size: CGFloat = 18
    private static let lineWidth: CGFloat = 2
    private let arc = CAShapeLayer()

    /// Shown and turning, or hidden with no animation.
    var isSpinning = false {
        didSet {
            guard isSpinning != oldValue else { return }
            isHidden = !isSpinning
            if isSpinning {
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = 0
                turn.toValue = -2 * Double.pi   // clockwise in a y-up layer
                turn.duration = 0.9
                turn.repeatCount = .infinity
                arc.add(turn, forKey: "spin")
            } else {
                arc.removeAnimation(forKey: "spin")
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        arc.fillColor = nil
        arc.strokeColor = Chrome.Palette.overMedia.text.cgColor
        arc.lineWidth = Self.lineWidth
        arc.lineCap = .round
        arc.strokeEnd = 0.75
        // Readable over a light photo too.
        arc.shadowColor = Chrome.Palette.overMedia.mediaShadow.cgColor
        arc.shadowOpacity = 1
        arc.shadowRadius = 1.5
        arc.shadowOffset = .zero
        layer?.addSublayer(arc)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: Self.lineWidth, dy: Self.lineWidth), transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        arc.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Purely visual: clicks and the cursor belong to whatever is under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
