import AppKit
import InfoPanelKit

/// "‹ Recent" / "‹ Stash" (a chevron and the title) in the top left corner over the picture, on a glass capsule, as
/// FrameScrub's: goes back to where the photo was opened from (File › Back, ⌘[). It comes and goes with the strip.
final class BackButton: NSView {
    static let height: CGFloat = 40

    var onClick: (() -> Void)?
    var title = "" {
        didSet { label.stringValue = title }
    }
    private let backdrop = GlassBackdrop(cornerRadius: BackButton.height / 2)
    private let chevron = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        chevron.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        chevron.contentTintColor = .white
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .white
        for view in [chevron, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && alphaValue > 0.01 && frame.contains(point) ? self : nil   // faded out: clicks reach the picture
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { setPressed(true) }
    override func mouseDragged(with event: NSEvent) { setPressed(isInside(event)) }
    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        if isInside(event) { onClick?() }
    }

    override func accessibilityLabel() -> String? { "Back to \(title)" }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    private func isInside(_ event: NSEvent) -> Bool { bounds.contains(convert(event.locationInWindow, from: nil)) }

    private func setPressed(_ pressed: Bool) {
        for view in [chevron, label] { view.alphaValue = pressed ? 0.55 : 1 }
    }
}
