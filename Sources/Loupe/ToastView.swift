import AppKit
import HomeChrome

/// A short line at the viewer's bottom centre, above the strip, saying what a key just did (`S`: "upscale-high:
/// ewa-lanczos · this folder", folder settings spec §5). Loupe's face of the kit's `ChromeToastView(.overMedia)`: the
/// same glass, radius and fades as every other piece of the viewer's chrome. Visible for `toast-duration` (read at each
/// `show`), then a short fade; a new toast replaces the one showing and starts the time over. It takes no event at all
/// (`hitTest` is always nil) and never becomes first responder.
@MainActor final class ToastView: NSView {
    private let toast = ChromeToastView(style: .overMedia(.regular))

    override init(frame: NSRect) {
        super.init(frame: frame)
        toast.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toast)
        NSLayoutConstraint.activate([
            toast.topAnchor.constraint(equalTo: topAnchor),
            toast.bottomAnchor.constraint(equalTo: bottomAnchor),
            toast.leadingAnchor.constraint(equalTo: leadingAnchor),
            toast.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `text` and starts its time.
    func show(_ text: String) {
        // The kit keeps its glass to itself; it is among the toast's subviews (`stats-toast-opacity`, `stats-toast-clear`).
        if let glass = toast.subviews.first(where: { $0 is ChromeGlass }) as? ChromeGlass {
            glass.tintOpacity = Settings.shared.config.statsToastOpacity
            glass.setClear(Settings.shared.config.statsToastClear)
        }
        toast.show(text, for: TimeInterval(Settings.shared.config.toastDurationMilliseconds) / 1000)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
