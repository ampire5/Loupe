import AppKit

/// A short line at the viewer's bottom centre, above the strip, saying what a key just did (`S`: "upscale-high:
/// ewa-lanczos · this folder", folder settings spec §5). The problems box's look (`ConfigWarningsOverlay`): a dark
/// translucent rounded box, light monospaced text, a layer-backed view of its own over the viewer. Visible for
/// `toast-duration` (read at each `show`), then a short fade; a new toast replaces the one showing and starts the time
/// over. It takes no event at all (`hitTest` is always nil) and never becomes first responder.
@MainActor final class ToastView: NSView {
    private static let fadeSeconds: TimeInterval = 0.25
    private static let padding = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    private let label = NSTextField(labelWithString: "")
    private var fadeTimer: Timer?
    /// Bumped on every show, so the fade of a replaced toast does not hide the newer one.
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        isHidden = true
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding.top),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding.bottom),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding.left),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding.right),
        ])
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `text` at full opacity and starts its time.
    func show(_ text: String) {
        generation += 1
        label.stringValue = text
        // Over a fade that is still running: its animation must not finish on the new toast.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = 1
        }
        alphaValue = 1
        isHidden = false
        fadeTimer?.invalidate()
        let shown = generation
        let visibleSeconds = TimeInterval(Settings.shared.config.toastDurationMilliseconds) / 1000
        // In the common modes, so menu tracking or a live resize does not hold the fade back.
        let timer = Timer(timeInterval: visibleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fade(generation: shown) }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func fade(generation shown: Int) {
        guard shown == generation, !isHidden else { return }
        fadeTimer = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeSeconds
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, shown == self.generation else { return }
                self.isHidden = true
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
