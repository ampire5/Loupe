import AppKit
import QuartzCore

/// `switch-preview` (`ViewerSession.standIn`): covers the viewer while the photo navigated to cannot be shown yet, so the
/// photo before never stands for it. Opaque in the viewer's `background`, with the strip's decoded cell of the new photo
/// scaled up to fit in it, or nothing (the blank placeholder). A view of its own over the viewer, hidden whenever there
/// is no stand-in, so the picture keeps its direct-to-display path the rest of the time (spec §2.1); the cell goes in as
/// layer contents, so showing it costs no decode or draw on the main thread.
@MainActor final class SwitchStandInView: NSView {
    private let picture = CALayer()
    private var shown: SwitchStandIn?
    private var background: CGColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        picture.contentsGravity = .resizeAspect
        picture.minificationFilter = .trilinear
        picture.magnificationFilter = .linear
        layer?.addSublayer(picture)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The stand-in to show (nil: hidden), and the viewer's background behind it. Called on every session change (every
    /// frame of a pan), so it only compares unless something changed.
    func show(_ standIn: SwitchStandIn?, background: CGColor) {
        guard standIn != shown || background != self.background else { return }
        shown = standIn
        self.background = background
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = background
        picture.contents = standIn?.picture
        isHidden = standIn == nil
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        picture.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Purely visual: clicks, gestures and the cursor belong to the viewer under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
