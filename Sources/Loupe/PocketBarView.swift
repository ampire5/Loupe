import AppKit
import LoupeCore

/// The system's own scroll pocket (`NSScrollPocket`, macOS 26): what Photos' bars stand on, the blur that grows towards the
/// edge with the luminance adaptation of what is over it. AppKit has no header for it, so it is found by name and set by
/// key; where the class or a key is missing nothing happens (`isAvailable`, `set`).
@MainActor final class NativePocket {
    let view: NSView?

    init() {
        view = (NSClassFromString("NSScrollPocket") as? NSView.Type).map { $0.init(frame: .zero) }
    }

    var isAvailable: Bool { view != nil }

    /// Sets `key` through its setter when the pocket has one (a key by name that does not exist would raise).
    @discardableResult
    func set(_ key: String, _ value: Any?, on object: NSObject? = nil) -> Bool {
        guard let target = object ?? view, let first = key.first else { return false }
        let setter = NSSelectorFromString("set" + first.uppercased() + key.dropFirst() + ":")
        guard target.responds(to: setter) else { return false }
        target.setValue(value, forKey: key)
        return true
    }

    /// The knobs of `values` and the portal's source: what the pocket blurs. `picture` is the viewer, `window` its container.
    func apply(_ values: PocketTuning.Values, picture: NSView?, window: NSView?) {
        guard let view else { return }
        set("edge", 0)
        set("style", values.nativeStyle)
        set("appearanceBias", [nil, NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)][min(max(values.appearance, 0), 2)])
        set("prefersSolidColorHardPocket", values.solidHard)
        set("allowsColorSchemeAdaptivity", values.adaptivity)
        set("_showSeparatorsOnHardPocket", values.separators)
        set("captureColor", [nil, NSColor.black, NSColor.white, NSColor.gray][min(max(values.captureColor, 0), 3)])
        let source: NSView? = [nil, picture, window][min(max(values.portalSource, 0), 2)]
        for portal in portals(in: view) {
            guard let layer = portal.layer else { continue }
            set("sourceLayer", source?.layer, on: layer)
            set("matchesPosition", values.portalMatchesPosition, on: layer)
            set("matchesTransform", values.portalMatchesTransform, on: layer)
        }
        if values.forceBlur, let blur = subview(named: "PocketBlur", in: view) { blur.isHidden = false }
    }

    /// The class's own name without the module's mangling (`…PocketMask` of a private nested class).
    private func name(of view: NSView) -> String {
        NSStringFromClass(type(of: view)).replacingOccurrences(of: "^.*?[0-9]+(?=[A-Za-z]+$)", with: "", options: .regularExpression)
    }

    private func subview(named suffix: String, in root: NSView) -> NSView? {
        for sub in root.subviews {
            if name(of: sub).hasSuffix(suffix) { return sub }
            if let found = subview(named: suffix, in: sub) { return found }
        }
        return nil
    }

    private func portals(in root: NSView) -> [NSView] {
        var result: [NSView] = []
        for sub in root.subviews {
            if name(of: sub).hasSuffix("PortalView") { result.append(sub) }
            result += portals(in: sub)
        }
        return result
    }

    /// What the pocket is made of and in what state, for the tuning panel to show (and to be sent back).
    func dump() -> String {
        guard let view else { return "NSScrollPocket is not there." }
        var lines = ["NSScrollPocket \(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue)"]
        for key in ["edge", "style", "appearanceBias", "prefersSolidColorHardPocket", "allowsColorSchemeAdaptivity",
                    "captureColor"] {
            let value = view.responds(to: NSSelectorFromString(key)) ? view.value(forKey: key) : nil
            lines.append("  \(key) = \(value.map { "\($0)" } ?? "?")")
        }
        func walk(_ v: NSView, _ depth: Int) {
            var line = String(repeating: "  ", count: depth + 1) + name(of: v)
            line += " \(Int(v.frame.minX)),\(Int(v.frame.minY)) \(Int(v.frame.width))x\(Int(v.frame.height))"
            if v.isHidden { line += " HIDDEN" }
            if v.alphaValue != 1 { line += " a=\(String(format: "%.2f", v.alphaValue))" }
            if let layer = v.layer, name(of: v).hasSuffix("PortalView") {
                let source = layer.responds(to: NSSelectorFromString("sourceLayer")) ? layer.value(forKey: "sourceLayer") : nil
                let matches = layer.responds(to: NSSelectorFromString("matchesPosition")) ? layer.value(forKey: "matchesPosition") : nil
                line += " portal(source=\(source.map { String(describing: type(of: $0)) } ?? "nil")"
                line += " matchesPosition=\(matches.map { "\($0)" } ?? "?"))"
            }
            lines.append(line)
            for sub in v.subviews { walk(sub, depth + 1) }
        }
        for sub in view.subviews { walk(sub, 0) }
        return lines.joined(separator: "\n")
    }
}

/// A button of the bar: a symbol, white, lit (yellow) when it is a switch that is on.
private final class BarButton: NSButton {
    var spec = 0
    var isLit = false { didSet { if isLit != oldValue { needsDisplay = true; updateTint() } } }
    var baseOpacity = 0.92 { didSet { updateTint() } }

    func updateTint() {
        contentTintColor = (isLit ? ProCameraStyle.yellow : NSColor.white).withAlphaComponent(baseOpacity)
    }
}

/// A group of buttons that go together (back; the steps; the zoom), as a toolbar's grouped items do: on one glass pill, or,
/// without glass, bare.
private final class ButtonGroup: NSView {
    let glass = NSGlassEffectView()
    let inner = NSView()
    var buttons: [BarButton] = []
    private(set) var usesGlass = false

    /// Where the buttons stand: on a glass pill of the `clear` style or not, or on nothing.
    func setGlass(_ kind: Int) {
        let wanted = kind == 1 || kind == 2
        if wanted != usesGlass {
            usesGlass = wanted
            glass.removeFromSuperview()
            inner.removeFromSuperview()
            if wanted {
                glass.contentView = inner
                addSubview(glass)
            } else {
                glass.contentView = nil
                addSubview(inner)
            }
        }
        if wanted { glass.style = kind == 2 ? .clear : .regular }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
        inner.frame = bounds
    }
}

/// The prototype's one bar over the picture: on the system's scroll pocket (or an own blur and tint, or both, or none), the
/// photo's information in the middle and the buttons at the ends, in three states (`PocketBarState`): information and
/// buttons, the information only, nothing. Everything about its look is `PocketTuning`. It takes the clicks of its buttons
/// and no others.
@MainActor final class PocketBarView: NSView {
    typealias Actions = ViewerToolbarController.Actions

    private struct Spec {
        let symbol: String
        let label: String
        let tip: String
        let run: (Actions) -> Void
        var switchAction: KeyAction?
    }

    private let actions: Actions
    private let native = NativePocket()
    private var custom: EdgeEffectView?
    private let content = NSView()
    /// The two sides' glass containers: the pills of one side blend with each other as a toolbar's groups do.
    private let leftGlass = NSGlassEffectContainerView()
    private let rightGlass = NSGlassEffectContainerView()
    private let leftHolder = NSView()
    private let rightHolder = NSView()
    /// The first row: the facts. The second: the file's name and the folder's, or the news about the folder.
    private let titleLabel = NSTextField(labelWithString: "")
    private let facts = FactsRowView(style: .init(options: .init(size: 11.5, shadow: true), formatBadge: true))
    private var leftGroups: [ButtonGroup] = []
    private var rightGroups: [ButtonGroup] = []
    private var buttons: [BarButton] = []
    private var heightConstraint: NSLayoutConstraint!
    private var status = ImageStatus()
    private var geometry: (inset: CGFloat, row: CGFloat, fade: CGFloat)?
    /// What the pocket blurs: the viewer (the picture).
    weak var picture: NSView?

    var state = PocketBarState.stored {
        didSet {
            guard state != oldValue else { return }
            PocketBarState.stored = state
            applyState()
        }
    }

    /// The buttons by group, left to right: back; the steps | the zoom; fit and 100 %; the colour switches; the strip and the info.
    private lazy var leftSpecs: [[Spec]] = [
        [Spec(symbol: "arrow.backward", label: "Back", tip: "Back to where the photo was opened from", run: { $0.back() })],
        [Spec(symbol: "chevron.left", label: "Previous", tip: "Previous photo", run: { $0.step(-1) }),
         Spec(symbol: "chevron.right", label: "Next", tip: "Next photo", run: { $0.step(1) })],
    ]
    private lazy var rightSpecs: [[Spec]] = [
        [Spec(symbol: "minus.magnifyingglass", label: "Zoom Out", tip: "Zoom out", run: { $0.zoom(.zoomOut) }),
         Spec(symbol: "plus.magnifyingglass", label: "Zoom In", tip: "Zoom in", run: { $0.zoom(.zoomIn) })],
        [Spec(symbol: "arrow.down.right.and.arrow.up.left", label: "Fit", tip: "Fit", run: { $0.zoom(.fit) }),
         Spec(symbol: "1.magnifyingglass", label: "100 %", tip: "Actual size", run: { $0.zoom(.actual100) })],
        [Spec(symbol: "wand.and.stars", label: "Auto Colour", tip: "Auto Colour",
              run: { $0.colour(.toggleAutoColor) }, switchAction: .toggleAutoColor),
         Spec(symbol: "drop.halffull", label: "Vibrance", tip: "Vibrance",
              run: { $0.colour(.toggleVibrance) }, switchAction: .toggleVibrance)],
        [Spec(symbol: "rectangle.bottomthird.inset.filled", label: "Filmstrip", tip: "Pin or hide the filmstrip",
              run: { $0.strip() }),
         Spec(symbol: "info.circle", label: "Info", tip: "Show photo information (⌘I)", run: { $0.info() })],
    ]
    private var specList: [Spec] { (leftSpecs + rightSpecs).flatMap { $0 } }

    init(actions: Actions) {
        self.actions = actions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleLabel)
        content.addSubview(facts)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 1
        leftGlass.contentView = leftHolder
        rightGlass.contentView = rightHolder
        content.addSubview(leftGlass)
        content.addSubview(rightGlass)
        var index = 0
        func groups(_ specs: [[Spec]], into holder: NSView) -> [ButtonGroup] {
            specs.map { part in
                let group = ButtonGroup()
                for spec in part {
                    let button = makeButton(spec, index)
                    index += 1
                    group.buttons.append(button)
                    buttons.append(button)
                    group.inner.addSubview(button)
                }
                holder.addSubview(group)
                return group
            }
        }
        leftGroups = groups(leftSpecs, into: leftHolder)
        rightGroups = groups(rightSpecs, into: rightHolder)
        if let pocket = native.view {
            pocket.autoresizingMask = []
            addSubview(pocket)
            native.set("edge", 0)
            // The content is what the pocket adapts its luminance to, as a toolbar's items are.
            if pocket.responds(to: NSSelectorFromString("addElementContainer:")) {
                pocket.perform(NSSelectorFromString("addElementContainer:"), with: content)
            }
        }
        addSubview(content)
        heightConstraint = heightAnchor.constraint(equalToConstant: 80)
        heightConstraint.isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(tuningChanged), name: .pocketTuningChanged,
                                               object: nil)
        applyTuning()
        applyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func makeButton(_ spec: Spec, _ index: Int) -> BarButton {
        let button = BarButton()
        button.spec = index
        button.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.target = self
        button.action = #selector(clicked(_:))
        button.toolTip = spec.tip
        button.setAccessibilityLabel(spec.label)
        return button
    }

    @objc private func clicked(_ sender: BarButton) {
        let all = specList
        guard all.indices.contains(sender.spec) else { return }
        all[sender.spec].run(actions)
    }

    @objc private func tuningChanged() {
        applyTuning()
        updateGeometry(force: true)
    }

    /// The bar over the picture only where it takes clicks: its buttons.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard state == .full, let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is BarButton { return current }
            view = current.superview
        }
        return nil
    }

    // MARK: State and content

    /// False while Home or the toolbar stands in its place.
    var isEnabled = false {
        didSet { if isEnabled != oldValue { applyState() } }
    }

    func dumpPocket() -> String { native.dump() }

    private func applyState() {
        isHidden = !isEnabled || state == .hidden
        leftGlass.isHidden = state != .full
        rightGlass.isHidden = state != .full
        needsLayout = true
    }

    func update(_ new: ImageStatus) {
        guard new != status else { return }
        let old = status
        status = new
        if new.title != old.title || new.titleTone != old.titleTone || new.note != old.note || new.noteTone != old.noteTone
            || new.folder != old.folder {
            refreshTitle()
        }
        facts.update(new.facts)
    }

    private func refreshTitle() {
        let size = PocketTuning.shared.values.infoSize
        let name = status.title.isEmpty ? "Loupe" : status.title
        let line = NSMutableAttributedString(attributedString: ProCameraStyle.name(
            name, size: size + 0.5, weight: .semibold, color: ProCameraStyle.color(status.titleTone, monochrome: false)))
        // The folder after the file, quiet; the news about the folder in its place.
        let folder = status.folder.map(FolderLabel.name(of:)) ?? ""
        let aside = status.note ?? folder
        if !aside.isEmpty {
            let tone = status.note == nil ? ImageStatus.Tone.quiet : status.noteTone
            line.append(ProCameraStyle.name("   ·   ", size: size + 0.5, weight: .regular, color: ProCameraStyle.secondary))
            line.append(ProCameraStyle.name(aside, size: size + 0.5, weight: .regular,
                                            color: ProCameraStyle.color(tone, monochrome: false)))
        }
        // The field takes its alignment from the text's paragraph style.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        titleLabel.attributedStringValue = line
        titleLabel.toolTip = [name, status.note ?? status.folder?.path].compactMap { $0 }.joined(separator: "\n")
    }

    /// The colour switches are lit as the window's values say.
    func updateColour(_ config: Config) {
        for (index, spec) in specList.enumerated() {
            guard let action = spec.switchAction, buttons.indices.contains(index) else { continue }
            buttons[index].isLit = action == .toggleAutoColor ? config.autoColor : config.vibrance
        }
    }

    // MARK: Look

    private func applyTuning() {
        let values = PocketTuning.shared.values
        let backdrop = PocketTuning.Backdrop(rawValue: values.backdrop) ?? .native
        native.view?.isHidden = !(backdrop == .native || backdrop == .both)
        native.apply(values, picture: picture, window: window?.contentView)
        facts.style = .init(options: .init(size: values.infoSize, shadow: true), formatBadge: true)
        refreshTitle()
        let bezel = values.buttonGlass == 3
        for group in leftGroups + rightGroups { group.setGlass(bezel ? 0 : values.buttonGlass) }
        for button in buttons {
            button.baseOpacity = values.buttonOpacity
            button.image = button.image?.withSymbolConfiguration(.init(pointSize: values.buttonSize, weight: .medium))
            // A glass bezel on each button: the system's own glass button, outlined, in place of a pill for the group.
            button.isBordered = bezel
            button.bezelStyle = bezel ? .glass : .regularSquare
            button.updateTint()
        }
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTuning()
        updateGeometry(force: true)
    }

    /// The part of the top the title bar takes (none in full screen), for the row to stand below it.
    private var titlebarInset: CGFloat {
        guard let window, let content = window.contentView else { return 0 }
        return max(0, content.bounds.height - window.contentLayoutRect.maxY)
    }

    /// The height of the bar follows the title bar and the knobs; the owner calls this when the window's top changes.
    func updateGeometry(force: Bool = false) {
        let values = PocketTuning.shared.values
        let inset = values.rowInTitlebar ? 0 : titlebarInset
        let next = (inset: inset, row: CGFloat(values.rowHeight), fade: CGFloat(values.fadeBelow))
        guard force || geometry?.inset != next.inset || geometry?.row != next.row || geometry?.fade != next.fade else { return }
        geometry = next
        let solid = (values.rowInTitlebar ? max(titlebarInset, next.row) : inset + next.row)
        heightConstraint.constant = solid + next.fade
        // Own blur and tint: made again for the height, which they know from the start.
        custom?.removeFromSuperview()
        custom = nil
        let backdrop = PocketTuning.Backdrop(rawValue: values.backdrop) ?? .native
        if backdrop == .custom || backdrop == .both {
            let effect = EdgeEffectView(solidHeight: solid, softFadeHeight: max(next.fade, 1))
            effect.style = values.customHard ? .hard : .soft
            effect.tintOpacity = CGFloat(values.customTint)
            effect.blurs = values.customBlur
            addSubview(effect, positioned: .below, relativeTo: content)
            custom = effect
        }
        needsLayout = true
    }

    /// The buttons of a side, from its outer edge inwards: each group a pill as wide as its buttons.
    private func place(_ groups: [ButtonGroup], from edge: CGFloat, direction: CGFloat, rowY: CGFloat, rowHeight: CGFloat,
                       values: PocketTuning.Values) -> CGFloat {
        let size = CGFloat(values.buttonSize) + 14
        let pad = values.buttonGlass == 1 || values.buttonGlass == 2 ? CGFloat(values.pillPadding) : 0
        let inner: CGFloat = values.buttonGlass == 3 ? 6 : 2
        let height = size + 2 * pad
        var x = edge
        for group in groups {
            let count = CGFloat(group.buttons.count)
            let width = count * size + (count - 1) * inner + 2 * pad
            let originX = direction > 0 ? x : x - width
            group.frame = NSRect(x: originX, y: rowY + (rowHeight - height) / 2, width: width, height: height)
            for (index, button) in group.buttons.enumerated() {
                button.frame = NSRect(x: pad + CGFloat(index) * (size + inner), y: pad, width: size, height: size)
            }
            x += direction * (width + CGFloat(values.buttonGap))
        }
        return x - direction * CGFloat(values.buttonGap)
    }

    override func layout() {
        super.layout()
        let values = PocketTuning.shared.values
        native.view?.frame = bounds
        if let custom {
            let height = custom.height
            custom.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        }
        if values.forceBlur { native.apply(values, picture: picture, window: window?.contentView) }
        content.frame = bounds
        guard let geometry else { return }
        let rowTop = values.rowInTitlebar ? 0 : geometry.inset
        let rowHeight = geometry.row
        let rowY = bounds.height - rowTop - rowHeight
        let fullScreen = window?.styleMask.contains(.fullScreen) == true
        let leftEdge = CGFloat(values.sideInset) + (values.rowInTitlebar && !fullScreen ? CGFloat(values.windowedLeftInset) : 0)
        let rightEdge = bounds.width - CGFloat(values.sideInset)
        var leftEnd = leftEdge, rightStart = rightEdge
        // Each side's holder is the container's content: the pills blend within a side.
        leftGlass.frame = bounds
        rightGlass.frame = bounds
        leftHolder.frame = bounds
        rightHolder.frame = bounds
        let blend = CGFloat(values.buttonGap) + 2
        leftGlass.spacing = blend
        rightGlass.spacing = blend
        if state == .full {
            leftEnd = place(leftGroups, from: leftEdge, direction: 1, rowY: rowY, rowHeight: rowHeight, values: values)
            rightStart = place(rightGroups.reversed(), from: rightEdge, direction: -1, rowY: rowY, rowHeight: rowHeight, values: values)
        }
        // The information in the middle: what is left between the buttons, centred on the bar when it fits.
        let gapInfo = CGFloat(values.infoGap)
        let room = max(0, rightStart - leftEnd - 2 * gapInfo)
        let width = min(room, max(facts.naturalWidth, 240))
        let centred = (bounds.width - width) / 2
        let infoX = max(leftEnd + gapInfo, min(centred, rightStart - gapInfo - width))
        let titleHeight: CGFloat = 17, factsHeight: CGFloat = 16
        let block = titleHeight + factsHeight + 2
        let blockY = rowY + (rowHeight - block) / 2
        // The facts first, the names under them.
        facts.frame = NSRect(x: infoX, y: blockY + titleHeight + 2, width: width, height: factsHeight)
        titleLabel.frame = NSRect(x: infoX, y: blockY, width: width, height: titleHeight)
        facts.isHidden = status.facts.isEmpty || room < 120
        titleLabel.isHidden = room < 60
    }
}
