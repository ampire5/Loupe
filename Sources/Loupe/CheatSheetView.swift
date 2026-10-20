import AppKit
import LoupeCore

/// The `?` cheat sheet (spec §6): a dark HUD panel centred over the window, listing every key of the effective layout
/// (`Settings.inputMap`: the built-in keys with input.conf's on top) in its sections (Navigation, Zoom, Scaling, Colour,
/// View), the mouse buttons' bindings (`InputMap.mouseLabels`) and the mouse and trackpad inputs from `KeyMap.gestures`,
/// so the sheet cannot say something the keys do not do. A reload that changes the layout builds it again.
///
/// The view itself covers the whole window and, while open, takes every mouse event over it: a press of any button
/// closes the sheet (`onClose`) and reaches nothing underneath, and scroll and pinch go nowhere, so nothing
/// moves behind the sheet. Closed, it is hidden and `hitTest` passes everything through. It never becomes first
/// responder: the viewer keeps the keys and closes the sheet from there.
///
/// A window too small for the panel gets a smaller one: the content is built again with its fonts and spacing scaled
/// (laid out natively at that size, so the text stays crisp and unclipped), down to a legible floor; below that the
/// window's edge cuts the panel off.
@MainActor final class CheatSheetView: NSView {
    private static let margin: CGFloat = 16
    private static let minimumScale: CGFloat = 0.75

    private let panel = NSVisualEffectView()
    private let tint = NSView()
    private var content = NSView()
    /// The scale `content` was built at (0: not built yet), and the size the sheet has at scale 1, measured in the
    /// window on the first layout.
    private var contentScale: CGFloat = 0
    private var fullSize = NSSize.zero
    /// The layout the sheet lists.
    private var inputMap = Settings.shared.inputMap

    /// A click closed the sheet; the window controller owns what else goes with closing.
    var onClose: (() -> Void)?

    var isOpen: Bool { !isHidden }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        clipsToBounds = true   // a panel larger than the window ends at the window's edge
        translatesAutoresizingMaskIntoConstraints = false
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.masksToBounds = true
        addSubview(panel)
        // The material alone stays light over a bright photo; a dark wash under the text keeps it readable.
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        panel.addSubview(tint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        guard isHidden else { return }
        isHidden = false
        contentScale = 0   // built afresh: the menu's shortcuts and the Stash rows follow the settings
        needsLayout = true
        DebugLog.log("cheat sheet open")
    }

    /// input.conf was read again: a changed layout is listed at the next layout (at once while open, else on opening).
    func inputMapChanged(_ map: InputMap) {
        guard map != inputMap else { return }
        inputMap = map
        contentScale = 0
        needsLayout = true
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        DebugLog.log("cheat sheet closed")
    }

    /// Centres the panel at its full size, or smaller (`fit`, in steps of 5 %) when the window is smaller, but never
    /// below `minimumScale` (13 pt text at about 10 pt). A window too small even for that shows the panel from its
    /// top-left corner, so the title and the first columns stay readable and the window's edge cuts off the rest.
    override func layout() {
        super.layout()
        guard !isHidden else { return }
        if contentScale == 0 {
            build(scale: 1)
            fullSize = content.fittingSize   // here, in the window, so the text is measured at the screen's scale
        }
        let room = NSSize(width: max(1, bounds.width - 2 * Self.margin), height: max(1, bounds.height - 2 * Self.margin))
        let fit = min(1, room.width / fullSize.width, room.height / fullSize.height)
        let scale = max(Self.minimumScale, (fit * 20).rounded(.down) / 20)
        if scale != contentScale { build(scale: scale) }
        let size = content.fittingSize
        let x = size.width <= room.width ? ((bounds.width - size.width) / 2).rounded() : Self.margin
        let y = size.height <= room.height ? ((bounds.height - size.height) / 2).rounded()
            : bounds.height - Self.margin - size.height   // the top edge at the margin (y up)
        panel.frame = NSRect(x: x, y: y, width: size.width.rounded(.up), height: size.height.rounded(.up))
        tint.frame = panel.bounds
        content.frame = panel.bounds
    }

    private func build(scale: CGFloat) {
        content.removeFromSuperview()
        content = Self.makeContent(scale: scale, inputMap: inputMap)
        contentScale = scale
        panel.addSubview(content)
    }

    // MARK: Events

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClose?() }
    override func rightMouseDown(with event: NSEvent) { onClose?() }
    override func otherMouseDown(with event: NSEvent) { onClose?() }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    // The release and drags of that press, and every gesture while open, end here: nothing behind the sheet moves.
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}

    /// The arrow over the sheet, not the viewer's hand.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    // MARK: Content

    /// Title, then three columns (Navigation over Colour over View, Zoom over Scaling, Mouse over Mouse & Trackpad),
    /// then how to close; every font size and gap times `k`. An action input.conf left without a key is not listed.
    private static func makeContent(scale k: CGFloat, inputMap: InputMap) -> NSView {
        let keyFont = NSFont.systemFont(ofSize: 13 * k, weight: .semibold)
        let titleFont = NSFont.systemFont(ofSize: 13 * k)
        let headerFont = NSFont.systemFont(ofSize: 11 * k, weight: .bold)
        let padding = 24 * k
        func section(_ title: String, _ rows: [(String, String)]) -> NSView {
            let header = label(title.uppercased(), font: headerFont, color: NSColor(white: 1, alpha: 0.5))
            // Rows of their own (not a grid, which hands spare height to its first row): the keys in a column as wide
            // as the widest of this section's.
            let keyLabels = rows.map { label($0.0, font: keyFont, color: .white) }
            let keyWidth = (keyLabels.map(\.fittingSize.width).max() ?? 0).rounded(.up)
            let lines = zip(keyLabels, rows).map { key, row -> NSView in
                key.widthAnchor.constraint(equalToConstant: keyWidth).isActive = true
                let line = NSStackView(views: [key, label(row.1, font: titleFont, color: NSColor(white: 1, alpha: 0.85))])
                line.orientation = .horizontal
                line.alignment = .firstBaseline
                line.spacing = 14 * k
                return line
            }
            let stack = NSStackView(views: [header] + lines)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 5 * k
            stack.setCustomSpacing(8 * k, after: header)
            return stack
        }
        func keys(_ group: KeyGroup) -> [(String, String)] {
            KeyAction.allCases.map { inputMap.keys.label($0) }.filter { $0.group == group && !$0.keys.isEmpty }
                .map { ($0.keys, $0.title) }
        }
        func column(_ views: [NSView]) -> NSStackView {
            // A shorter column is as tall as the tallest one; the filler at its end takes the difference, so its
            // sections keep their spacing instead of spreading apart.
            let filler = NSView()
            filler.setContentHuggingPriority(.init(1), for: .vertical)
            let stack = NSStackView(views: views + [filler])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 22 * k
            stack.setCustomSpacing(0, after: views[views.count - 1])
            return stack
        }
        let buttons = inputMap.mouseLabels()
        let mouse = buttons.isEmpty ? [] : [section("Mouse", buttons.map { ($0.input, $0.title) })]
        let steps = inputMap.keys.stepLabels()
        let custom = steps.isEmpty ? [] : [section("input.conf", steps.map { ($0.keys, $0.title) })]
        let stash = Settings.shared.config.stashURL == nil ? [] : [section("Stash", stashRows)]
        let columns = NSStackView(views: [
            column([section("Navigation", keys(.navigation)), section("Colour", keys(.colour)), section("View", keys(.view))]
                   + custom),
            // input.conf's tab and window keys under the menu's.
            column([section("Zoom", keys(.zoom)), section("Scaling", keys(.scaling)),
                    section("Window", menuRows() + keys(.tabs))] + stash),
            column(mouse + [section("Mouse & Trackpad", KeyMap.gestures.map { ($0.input, $0.title) })]),
        ])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 36 * k
        let title = label("Keys and Gestures", font: .systemFont(ofSize: 17 * k, weight: .semibold), color: .white)
        let footer = label("Press any key or click to close", font: .systemFont(ofSize: 11 * k),
                           color: NSColor(white: 1, alpha: 0.5))
        let stack = NSStackView(views: [title, columns, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18 * k
        // The padding as constraints of a wrapper, so the wrapper's fitting size includes it on every side.
        let wrapper = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: padding),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -padding + 6 * k),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: padding + 4 * k),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -padding - 4 * k),
        ])
        return wrapper
    }

    private static func menuRows() -> [(String, String)] {
        MenuShortcuts.rows().map { ($0.input, $0.title) }
    }

    /// What Stash's page and its galleries answer to (StashKitUI's `StashLibraryView`, `BackButton`).
    private static let stashRows: [(String, String)] = [
        ("‹ Recent  ‹ Stash", "Over what Home opened: back there (⌘[)"),
        ("⌘[  ⌘]  ⌘←  ⌘→", "In Stash: back / forward a page"),
        ("Mouse back / forward", "In Stash: back / forward a page"),
        ("⌘R", "In Stash: reload the page"),
        ("Click a gallery", "Open it here; folder steps follow Stash's list"),
    ]

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        return field
    }
}
