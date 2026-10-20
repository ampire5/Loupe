import AppKit
import LoupeCore

/// The loupe.conf and input.conf problems box (Task 17c, user: `strip-magnify-reach=0.00` was rejected on stderr only
/// and looked like a broken setting): a dark translucent rounded box at the viewer's top centre, light text, like the
/// stats bar's overlay look. A layer-backed view of its own over the viewer, so the Metal surface stays
/// direct-to-display. Hidden when there is nothing to say; otherwise it fades out after `visibleSeconds`, or at once on
/// a left click on the box. It takes no other event (`hitTest` claims only a left mouse-down inside the box, so scroll,
/// magnify and the other buttons reach the viewer even over it) and never becomes first responder, so keys go on
/// reaching the viewer. One line per warning, truncated at the tail when the box is narrower than the line; what does
/// not fit the height the window allows is clipped.
@MainActor final class ConfigWarningsOverlay: NSView {
    static let visibleSeconds: TimeInterval = 8
    private static let fadeSeconds: TimeInterval = 0.4
    private static let dismissSeconds: TimeInterval = 0.15
    private static let padding = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let lines = NSStackView()
    private var fadeTimer: Timer?
    /// Bumped on every show and hide, so a fade that was overtaken does not hide the newer box.
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        layer?.cornerRadius = 8
        isHidden = true
        layer?.masksToBounds = true
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 0
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        // The bottom gives way (priority below required) to a height limit the window controller sets.
        let bottom = lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding.bottom)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            lines.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding.top), bottom,
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding.left),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding.right),
        ])
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `warnings` (`ConfigWarningsText`) and starts the 8 s fade; an empty list hides the box.
    func show(_ warnings: [String]) {
        guard let text = ConfigWarningsText.block(for: warnings) else {
            hide()
            return
        }
        generation += 1
        for old in lines.arrangedSubviews { old.removeFromSuperview() }
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let field = NSTextField(labelWithString: String(line))
            field.font = n == 0 ? NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold) : Self.font
            field.textColor = NSColor(white: 0.92, alpha: 1)
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            lines.addArrangedSubview(field)
            field.trailingAnchor.constraint(lessThanOrEqualTo: lines.trailingAnchor).isActive = true
        }
        // Over a fade that is still running: its animation must not finish on an invisible box that takes clicks.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = 1
        }
        alphaValue = 1
        isHidden = false
        fadeTimer?.invalidate()
        let shown = generation
        // In the common modes, so menu tracking or a live resize does not hold the fade back.
        let timer = Timer(timeInterval: Self.visibleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fade(over: Self.fadeSeconds, generation: shown) }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    /// Gone at once, with no fade (the file was fixed).
    func hide() {
        generation += 1
        fadeTimer?.invalidate()
        fadeTimer = nil
        isHidden = true
    }

    private func fade(over seconds: TimeInterval, generation shown: Int) {
        guard shown == generation, !isHidden else { return }
        fadeTimer = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = seconds
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, shown == self.generation else { return }
                self.isHidden = true
            }
        }
    }

    /// Only a left mouse-down on the box is the box's; hidden, beside it, or any other event (scroll, magnify, the
    /// other buttons, a mouse move for the cursor) belongs to what is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, NSApp.currentEvent?.type == .leftMouseDown,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        fadeTimer?.invalidate()
        fade(over: Self.dismissSeconds, generation: generation)
    }
}
