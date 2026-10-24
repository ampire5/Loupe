import AppKit
import HomeChrome
import LoupeCore

/// The camera-HUD palette of the photo's facts: white for the numbers that matter, grey for the rest, yellow for the
/// parameters one changes (format, zoom), as on a camera's screen.
enum ProCameraStyle {
    static let yellow = NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)
    static let primary = NSColor.white
    static let secondary = NSColor.white.withAlphaComponent(0.62)
    static let separator = NSColor.white.withAlphaComponent(0.24)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// `2 / 5`: the number lit, the total dim.
    static func position(_ text: String, size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let parts = text.components(separatedBy: " / ")
        result.append(NSAttributedString(string: parts[0], attributes: [.font: font(size), .foregroundColor: primary]))
        if parts.count > 1 {
            result.append(NSAttributedString(string: " / " + parts[1],
                                             attributes: [.font: font(size, .medium), .foregroundColor: secondary]))
        }
        return result
    }

    /// A value with its colour; `bold` for the lit ones.
    static func value(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .semibold) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font(size, weight), .foregroundColor: color])
    }
}

/// One fact of the photo in the toolbar's status: its text and the width of its slot.
private struct ViewerToolbarFact: Equatable {
    enum Kind: CaseIterable { case position, size, file, format, zoom }

    let kind: Kind
    let value: String
    let tip: String

    /// Each kind has a slot of its own width, so a new photo or a zoom step does not move the other facts.
    var slotWidth: CGFloat {
        switch kind {
        case .position: 74
        case .size: 108
        case .file: 68
        case .format: 54
        case .zoom: 88
        }
    }
}

/// The viewer's `NSToolbar`: back and the photo steps, the zoom block and the photo's status on the left and in the
/// middle; the colour switches with their sliders, the toggles and the scaling menu on the right. A narrow window hides
/// the items by `visibilityPriority` (the status last, the menus first); the system's overflow keeps them reachable.
@MainActor final class ViewerToolbarController: NSObject, NSToolbarDelegate {
    struct Actions {
        let back: () -> Void
        let step: (Int) -> Void
        let zoom: (KeyAction) -> Void
        let colour: (KeyAction) -> Void
        let setValue: (String, Double) -> Void
        let stats: () -> Void
        let strip: () -> Void
        let info: () -> Void
    }

    let nsToolbar: NSToolbar
    private let actions: Actions
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let statusView = ViewerToolbarStatusView()
    private var sliders: [String: NSSlider] = [:]

    private enum Item: String, CaseIterable {
        case back, navigation, zoom, zoomModes, zoomMenu, status, colour, strength, vibrance, info, strip, stats, scaling

        var identifier: NSToolbarItem.Identifier { .init("viewer.\(rawValue)") }
        var priority: Int {
            switch self {
            case .status: 1000
            case .back: 100
            case .navigation: 90
            case .zoom: 80
            case .zoomModes: 70
            case .info: 60
            case .colour: 50
            case .strength: 30
            case .vibrance: 29
            case .strip: 20
            case .stats: 10
            case .zoomMenu: 5
            case .scaling: -40
            }
        }
    }

    /// The zoom modes of the block (`⌥`-less keys `0`, `1`, … are the same actions).
    private static let zoomModes: [(symbol: String, label: String, action: KeyAction)] = [
        ("arrow.down.right.and.arrow.up.left", "Fit", .fit),
        ("1.magnifyingglass", "100 %", .actual100),
        ("arrow.left.and.right", "Fit Width", .fitWidth),
        ("arrow.up.and.down", "Fit Height", .fitHeight),
        ("arrow.up.left.and.arrow.down.right", "Fill", .fill),
    ]

    private static let colourSwitches: [(symbol: String, label: String, action: KeyAction)] = [
        ("wand.and.stars", "Auto Colour", .toggleAutoColor),
        ("drop.halffull", "Vibrance", .toggleVibrance),
    ]

    /// Left to right; the flexible spaces centre the status between the left group and the right one.
    private static let order: [NSToolbarItem.Identifier] = [
        Item.back, .navigation, .zoom, .zoomModes, .zoomMenu,
    ].map(\.identifier) + [.flexibleSpace, Item.status.identifier, .flexibleSpace] + [
        Item.colour, .strength, .vibrance, .info, .strip, .stats, .scaling,
    ].map(\.identifier)

    init(actions: Actions) {
        self.actions = actions
        nsToolbar = NSToolbar(identifier: "viewer.photo")
        super.init()
        nsToolbar.delegate = self
        nsToolbar.displayMode = .iconOnly
        nsToolbar.allowsUserCustomization = false
        nsToolbar.autosavesConfiguration = false
        for item in Item.allCases {
            let toolbarItem = make(item)
            toolbarItem.visibilityPriority = .init(item.priority)
            items[item.identifier] = toolbarItem
        }
    }

    private func make(_ item: Item) -> NSToolbarItem {
        switch item {
        case .back:
            return button(item, symbol: "arrow.backward", label: "Back", tip: "Back to where the photo was opened from",
                          action: #selector(backClicked))
        case .navigation:
            return group(item, [("chevron.left", "Previous", "Previous photo"),
                                ("chevron.right", "Next", "Next photo")], action: #selector(stepClicked(_:)))
        case .zoom:
            return group(item, [("minus.magnifyingglass", "Zoom Out", "Zoom out"),
                                ("plus.magnifyingglass", "Zoom In", "Zoom in")], action: #selector(zoomClicked(_:)))
        case .zoomModes:
            let modes = group(item, Self.zoomModes.map { ($0.symbol, $0.label, $0.label) }, mode: .selectOne,
                              action: #selector(zoomModeClicked(_:)))
            modes.selectedIndex = -1
            return modes
        case .zoomMenu:
            return menuItem(item, symbol: "ellipsis.circle", label: "Zoom Options", tip: "More zoom options",
                            menu: Settings.shared.makeZoomToolbarMenu())
        case .colour:
            let switches = group(item, Self.colourSwitches.map { ($0.symbol, $0.label, $0.label) }, mode: .selectAny,
                                 action: #selector(colourClicked(_:)))
            // Each switch asks for its own action: the window's value (the folder's) says what is lit afterwards.
            for (index, subitem) in switches.subitems.enumerated() {
                subitem.tag = index
                subitem.target = self
                subitem.action = #selector(colourClicked(_:))
            }
            return switches
        case .strength:
            return sliderItem(item, symbol: "wand.and.stars", label: "Auto Colour Strength",
                              tip: "How strongly Auto Colour is applied", key: "auto-color-strength")
        case .vibrance:
            return sliderItem(item, symbol: "drop.halffull", label: "Vibrance Amount", tip: "How much vibrance is added",
                              key: "vibrance-amount")
        case .stats:
            return button(item, symbol: "text.alignleft", label: "Status", tip: "Show or hide the stats bar (I)",
                          action: #selector(statsClicked))
        case .strip:
            return button(item, symbol: "rectangle.bottomthird.inset.filled", label: "Filmstrip",
                          tip: "Pin or hide the filmstrip", action: #selector(stripClicked))
        case .info:
            return button(item, symbol: "info.circle", label: "Info", tip: "Show photo information (⌘I)",
                          action: #selector(infoClicked))
        case .status:
            let toolbarItem = NSToolbarItem(itemIdentifier: item.identifier)
            toolbarItem.label = "Current photo"
            toolbarItem.toolTip = "Current photo and its place in the folder"
            toolbarItem.view = statusView
            toolbarItem.isBordered = false
            return toolbarItem
        case .scaling:
            return menuItem(item, symbol: "slider.horizontal.3", label: "Scaling", tip: "Scaling filters",
                            menu: Settings.shared.makeScalingMenu())
        }
    }

    private func image(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    private func button(_ item: Item, symbol: String, label: String, tip: String, action: Selector) -> NSToolbarItem {
        let toolbarItem = NSToolbarItem(itemIdentifier: item.identifier)
        toolbarItem.image = image(symbol, label)
        toolbarItem.label = label
        toolbarItem.toolTip = tip
        toolbarItem.isBordered = true
        toolbarItem.target = self
        toolbarItem.action = action
        return toolbarItem
    }

    private func group(_ item: Item, _ parts: [(symbol: String, label: String, tip: String)],
                       mode: NSToolbarItemGroup.SelectionMode = .momentary, action: Selector) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: item.identifier,
                                       images: parts.map { image($0.symbol, $0.label) },
                                       selectionMode: mode, labels: parts.map(\.label),
                                       target: self, action: action)
        group.controlRepresentation = .expanded
        group.label = item.rawValue.capitalized
        group.toolTip = parts.map(\.tip).joined(separator: " / ")
        for (subitem, part) in zip(group.subitems, parts) { subitem.toolTip = part.tip }
        return group
    }

    private func menuItem(_ item: Item, symbol: String, label: String, tip: String, menu: NSMenu) -> NSMenuToolbarItem {
        let toolbarItem = NSMenuToolbarItem(itemIdentifier: item.identifier)
        toolbarItem.image = image(symbol, label)
        toolbarItem.label = label
        toolbarItem.toolTip = tip
        toolbarItem.showsIndicator = true
        toolbarItem.menu = menu
        return toolbarItem
    }

    /// A small slider with the switch's symbol before it, 0...1.
    private func sliderItem(_ item: Item, symbol: String, label: String, tip: String, key: String) -> NSToolbarItem {
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: self, action: #selector(sliderMoved(_:)))
        slider.controlSize = .small
        slider.isContinuous = true
        slider.identifier = NSUserInterfaceItemIdentifier(key)
        slider.setAccessibilityLabel(label)
        slider.toolTip = tip
        slider.translatesAutoresizingMaskIntoConstraints = false
        sliders[key] = slider
        let icon = NSImageView(image: image(symbol, label))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(icon)
        box.addSubview(slider)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 112),
            box.heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            slider.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            slider.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        let toolbarItem = NSToolbarItem(itemIdentifier: item.identifier)
        toolbarItem.view = box
        toolbarItem.label = label
        toolbarItem.toolTip = tip
        toolbarItem.isBordered = false
        return toolbarItem
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.order }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.order }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        items[identifier]
    }

    func setBackEnabled(_ enabled: Bool) { items[Item.back.identifier]?.isEnabled = enabled }

    /// The colour switches and their sliders follow the window's values (the folder's or loupe.conf's).
    func updateColour(_ config: Config) {
        guard let colourGroup = items[Item.colour.identifier] as? NSToolbarItemGroup else { return }
        colourGroup.setSelected(config.autoColor, at: 0)
        colourGroup.setSelected(config.vibrance, at: 1)
        set(sliders["auto-color-strength"], to: config.autoColorStrength, enabled: config.autoColor)
        set(sliders["vibrance-amount"], to: config.vibranceAmount, enabled: config.vibrance)
    }

    private func set(_ slider: NSSlider?, to value: Double, enabled: Bool) {
        guard let slider else { return }
        slider.isEnabled = enabled
        // Not under the pointer: a drag is the one that sets it.
        if abs(slider.doubleValue - value) > 0.004, NSApp.currentEvent?.type != .leftMouseDragged { slider.doubleValue = value }
    }

    func updateStatus(from session: ViewerSession) {
        let playlist = session.playlist
        let url = session.entry?.url ?? playlist?.current
        var title = session.folderMessage ?? session.loadingName.map { "Loading \($0)…" }
            ?? url.map(ArchivePath.shortName) ?? "Loupe"
        setZoomMode((session.zoomTarget ?? session.transform).mode)
        guard session.folderMessage == nil, let playlist else {
            statusView.update(title: title, facts: [])
            return
        }
        var index = url.flatMap { playlist.files.firstIndex(of: $0) } ?? playlist.index
        let pages = session.currentPages
        if session.loadingName == nil, url == playlist.current, let pages, let second = pages.second {
            title = ArchivePath.shortName(playlist.files[pages.first]) + " · "
                + ArchivePath.shortName(playlist.files[second])
            index = pages.first
        } else if session.loadingName != nil, let first = pages?.first {
            index = first
        }
        let first = pages?.first ?? index
        var facts = [ViewerToolbarFact(kind: .position,
                                       value: StatsLine.position(index: first, companion: pages?.second,
                                                                 count: playlist.files.count,
                                                                 counted: session.folderCounted),
                                       tip: "Position in folder")]
        if session.loadingName == nil, let entry = session.entry, entry.url == url, let info = entry.info {
            let size = info.displaySize(applying: session.appliesOrientation)
            facts.append(ViewerToolbarFact(kind: .size, value: "\(size.width)×\(size.height)", tip: "Image dimensions"))
            facts.append(ViewerToolbarFact(kind: .file,
                                           value: ByteCountFormatter.string(fromByteCount: Int64(info.fileSize),
                                                                            countStyle: .file),
                                           tip: "File size"))
            facts.append(ViewerToolbarFact(kind: .format, value: StatsLine.formatName(info.typeIdentifier),
                                           tip: "File format"))
        }
        facts.append(ViewerToolbarFact(kind: .zoom, value: StatsLine.modeText(session.zoomTarget ?? session.transform),
                                       tip: "Zoom mode"))
        statusView.update(title: title, facts: facts)
    }

    private var zoomModeGroup: NSToolbarItemGroup { items[Item.zoomModes.identifier] as! NSToolbarItemGroup }

    private func setZoomMode(_ mode: ZoomMode) {
        let index: Int?
        switch mode {
        case .fit: index = 0
        case .actual(let scale) where scale == 1: index = 1
        case .fitWidth: index = 2
        case .fitHeight: index = 3
        case .fill: index = 4
        default: index = nil
        }
        if zoomModeGroup.selectedIndex != (index ?? -1) { zoomModeGroup.selectedIndex = index ?? -1 }
    }

    @objc private func backClicked() { actions.back() }
    @objc private func stepClicked(_ sender: NSToolbarItemGroup) { actions.step(sender.selectedIndex == 0 ? -1 : 1) }
    @objc private func zoomClicked(_ sender: NSToolbarItemGroup) {
        actions.zoom(sender.selectedIndex == 0 ? .zoomOut : .zoomIn)
    }
    @objc private func zoomModeClicked(_ sender: NSToolbarItemGroup) {
        guard Self.zoomModes.indices.contains(sender.selectedIndex) else { return }
        actions.zoom(Self.zoomModes[sender.selectedIndex].action)
    }
    @objc private func colourClicked(_ sender: NSToolbarItem) {
        guard Self.colourSwitches.indices.contains(sender.tag) else { return }
        actions.colour(Self.colourSwitches[sender.tag].action)
    }
    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue else { return }
        actions.setValue(key, (sender.doubleValue * 100).rounded() / 100)
    }
    @objc private func statsClicked() { actions.stats() }
    @objc private func stripClicked() { actions.strip() }
    @objc private func infoClicked() { actions.info() }
}

/// The photo's status in the middle of the toolbar, in the style of a camera's screen: a glass chip of one size, the name
/// over a row of facts in slots of their own widths with hairlines between them (so nothing jumps when the photo or the
/// zoom changes), the position and size lit, the format and the zoom in the HUD yellow. Long values are cut, not wrapped.
@MainActor private final class ViewerToolbarStatusView: NSView {
    private static let width: CGFloat = 480
    private static let height: CGFloat = 46
    private let glass = ChromeGlass(style: .overMedia(.light), cornerRadius: 16)
    private let title = NSTextField(labelWithString: "")
    private let facts = NSStackView()
    private var displayedTitle: String?
    private var displayedFacts: [ViewerToolbarFact] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = ProCameraStyle.primary
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        title.alignment = .center
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        facts.orientation = .horizontal
        facts.alignment = .centerY
        facts.distribution = .gravityAreas
        facts.spacing = 0
        let column = NSStackView(views: [title, facts])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(column)

        let preferred = widthAnchor.constraint(equalToConstant: Self.width)
        preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferred,
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            heightAnchor.constraint(equalToConstant: Self.height),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: glass.contentView.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(lessThanOrEqualTo: glass.contentView.trailingAnchor, constant: -12),
            column.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: glass.contentView.widthAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(title text: String, facts items: [ViewerToolbarFact]) {
        if displayedTitle != text {
            displayedTitle = text
            title.stringValue = text
            title.toolTip = text
        }
        guard displayedFacts != items else { return }
        displayedFacts = items
        facts.arrangedSubviews.forEach {
            facts.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        facts.isHidden = items.isEmpty
        for (index, fact) in items.enumerated() {
            if index > 0 { facts.addArrangedSubview(hairline()) }
            facts.addArrangedSubview(slot(for: fact))
        }
    }

    private func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = ProCameraStyle.separator.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([line.widthAnchor.constraint(equalToConstant: 1),
                                     line.heightAnchor.constraint(equalToConstant: 12)])
        return line
    }

    private func slot(for fact: ViewerToolbarFact) -> NSView {
        let label = NSTextField(labelWithString: "")
        switch fact.kind {
        case .position: label.attributedStringValue = ProCameraStyle.position(fact.value, size: 11)
        case .size: label.attributedStringValue = ProCameraStyle.value(fact.value, size: 11, color: ProCameraStyle.primary)
        case .file: label.attributedStringValue = ProCameraStyle.value(fact.value, size: 11, color: ProCameraStyle.secondary,
                                                                       weight: .medium)
        case .format, .zoom: label.attributedStringValue = ProCameraStyle.value(fact.value, size: 11, color: ProCameraStyle.yellow)
        }
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = fact.tip
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSView()
        cell.toolTip = fact.tip
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        var constraints = [
            cell.widthAnchor.constraint(equalToConstant: fact.slotWidth),
            cell.heightAnchor.constraint(equalToConstant: 19),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ]
        if fact.kind == .format {
            // A format badge, as a camera marks RAW or JPG: a yellow outline round the letters.
            let badge = NSView()
            badge.wantsLayer = true
            badge.layer?.borderWidth = 1
            badge.layer?.borderColor = ProCameraStyle.yellow.withAlphaComponent(0.85).cgColor
            badge.layer?.cornerRadius = 4
            badge.layer?.cornerCurve = .continuous
            badge.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(badge, positioned: .below, relativeTo: label)
            constraints += [
                badge.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                badge.heightAnchor.constraint(equalToConstant: 16),
            ]
        }
        constraints += [
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
        ]
        NSLayoutConstraint.activate(constraints)
        return cell
    }
}
