import AppKit
import HomeChrome
import LoupeCore

/// The viewer's `NSToolbar`: back and the photo steps, the zoom block and the photo's status on the left and in the
/// middle; each colour switch before its slider, the toggles and the scaling menu on the right. A narrow window hides
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
        let smartZoom: () -> Void
    }

    let nsToolbar: NSToolbar
    private let actions: Actions
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let statusView = ViewerToolbarStatusView()
    private var sliders: [String: NSSlider] = [:]

    private enum Item: String, CaseIterable {
        case smartZoom, back, navigation, zoom, zoomSet, zoomModes, smartModes, zoomMenu, status, autoColour, strength, vibranceSwitch, vibrance, info, strip, stats, scaling

        var identifier: NSToolbarItem.Identifier { .init("viewer.\(rawValue)") }
        var priority: Int {
            switch self {
            case .status: 1000
            case .back: 100
            case .navigation: 90
            case .zoom: 80
            case .zoomModes, .smartModes: 70
            case .zoomSet, .smartZoom: 1100
            case .info: 60
            case .autoColour: 50
            case .vibranceSwitch: 49
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

    /// The smart zoom modes (spec §3.3), shown in the zoom block in place of the classic ones when the set is smart.
    private static let smartModes: [(symbol: String, label: String, action: KeyAction)] = [
        ("person.crop.rectangle", "Subject", .zoomSubject),
        ("rectangle.dashed", "Screen Share", .screenShare),
        ("viewfinder", "Fill on Subject", .fillSubject),
    ]

    /// The colour switches, each in front of its slider; the `tag` of a switch's item is its index here.
    private static let colourSwitches: [(item: Item, symbol: String, label: String, action: KeyAction)] = [
        (.autoColour, "wand.and.stars", "Auto Colour", .toggleAutoColor),
        (.vibranceSwitch, "drop.halffull", "Vibrance", .toggleVibrance),
    ]

    /// Left to right; the status is centred in the window (`centeredItemIdentifiers`), not between the groups, which differ
    /// in width; the flexible spaces push the groups to the edges.
    private static let order: [NSToolbarItem.Identifier] = [
        Item.back, .navigation, .zoom, .zoomSet, .zoomModes, .smartZoom, .zoomMenu,
    ].map(\.identifier) + [.flexibleSpace, Item.status.identifier, .flexibleSpace] + [
        Item.autoColour, .strength, .vibranceSwitch, .vibrance, .info, .strip, .stats, .scaling,
    ].map(\.identifier)

    init(actions: Actions) {
        self.actions = actions
        nsToolbar = NSToolbar(identifier: "viewer.photo")
        super.init()
        nsToolbar.delegate = self
        nsToolbar.displayMode = .iconOnly
        nsToolbar.allowsUserCustomization = false
        nsToolbar.autosavesConfiguration = false
        nsToolbar.centeredItemIdentifiers = [Item.status.identifier]
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
        case .zoomSet:
            let itemView = NSToolbarItem(itemIdentifier: item.identifier)
            let control = NSSegmentedControl(labels: ["Manual", "SmartZoom"], trackingMode: .selectOne,
                                             target: self, action: #selector(workflowClicked(_:)))
            control.appearance = NSAppearance(named: .darkAqua)
            control.toolTip = "Manual preserves the current view · SmartZoom applies Auto using the selected profile (⇧Z)"
            control.setAccessibilityLabel("Zoom workflow")
            itemView.view = control; itemView.label = "Zoom workflow"
            return itemView
        case .smartModes:
            let modes = group(item, Self.smartModes.map { ($0.symbol, $0.label, $0.label) }, mode: .selectOne,
                              action: #selector(smartModeClicked(_:)))
            modes.selectedIndex = -1
            return modes
        case .smartZoom:
            return button(item, symbol: "viewfinder", label: "SmartZoom", tip: "SmartZoom panel", action: #selector(smartZoomClicked))
        case .zoomMenu:
            return menuItem(item, symbol: "ellipsis.circle", label: "Zoom Options", tip: "More zoom options",
                            menu: Settings.shared.makeZoomToolbarMenu())
        case .autoColour, .vibranceSwitch:
            let index = Self.colourSwitches.firstIndex { $0.item == item } ?? 0
            let switchItem = Self.colourSwitches[index]
            let toggle = group(item, [(switchItem.symbol, switchItem.label, switchItem.label)], mode: .selectAny,
                               action: #selector(colourClicked(_:)))
            // The window's value (the folder's) says what is lit afterwards, so the click only asks for the action.
            for subitem in toggle.subitems {
                subitem.tag = index
                subitem.target = self
                subitem.action = #selector(colourClicked(_:))
            }
            return toggle
        case .strength:
            return sliderItem(item, label: "Auto Colour Strength", tip: "How strongly Auto Colour is applied",
                              key: "auto-color-strength")
        case .vibrance:
            return sliderItem(item, label: "Vibrance Amount", tip: "How much vibrance is added", key: "vibrance-amount")
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

    @objc private func smartZoomClicked() { actions.smartZoom() }

    private func image(_ name: String, _ description: String) -> NSImage {
        Icons.symbol(name, pointSize: 14, description: description) ?? NSImage()
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

    /// A small slider, 0...1; the switch before it names it.
    private func sliderItem(_ item: Item, label: String, tip: String, key: String) -> NSToolbarItem {
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: self, action: #selector(sliderMoved(_:)))
        slider.controlSize = .small
        slider.isContinuous = true
        slider.identifier = NSUserInterfaceItemIdentifier(key)
        slider.setAccessibilityLabel(label)
        slider.toolTip = tip
        slider.translatesAutoresizingMaskIntoConstraints = false
        sliders[key] = slider
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(slider)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 88),
            box.heightAnchor.constraint(equalToConstant: 28),
            slider.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
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

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.order + [Item.smartModes.identifier]
    }

    /// Shows the classic modes or the smart ones in the zoom block; the set's button shows which.
    func setZoomSet(_ set: ZoomSet) {} // Compatibility: ordinary presets are always visible.

    func updateWorkflow(_ mode: SmartZoomMode) {
        guard let control = items[Item.zoomSet.identifier]?.view as? NSSegmentedControl else { return }
        control.selectedSegment = mode == .off ? 0 : 1
    }

    /// The smart mode on screen lit: Zoom to Subject, a free zoom kept as the screen's share, Fill.
    func updateSmartMode(subject: Bool, screen: Bool, fill: Bool) {
        guard let group = items[Item.smartModes.identifier] as? NSToolbarItemGroup else { return }
        let index = subject ? 0 : screen ? 1 : fill ? 2 : -1
        if group.selectedIndex != index { group.selectedIndex = index }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        items[identifier]
    }

    func setBackEnabled(_ enabled: Bool) { items[Item.back.identifier]?.isEnabled = enabled }

    /// The colour switches and their sliders follow the window's values (the folder's or loupe.conf's).
    func updateColour(_ config: Config) {
        (items[Item.autoColour.identifier] as? NSToolbarItemGroup)?.setSelected(config.autoColor, at: 0)
        (items[Item.vibranceSwitch.identifier] as? NSToolbarItemGroup)?.setSelected(config.vibrance, at: 0)
        set(sliders["auto-color-strength"], to: config.autoColorStrength, enabled: config.autoColor)
        set(sliders["vibrance-amount"], to: config.vibranceAmount, enabled: config.vibrance)
    }

    private func set(_ slider: NSSlider?, to value: Double, enabled: Bool) {
        guard let slider else { return }
        slider.isEnabled = enabled
        // Not under the pointer: a drag is the one that sets it.
        if abs(slider.doubleValue - value) > 0.004, NSApp.currentEvent?.type != .leftMouseDragged { slider.doubleValue = value }
    }

    /// The photo's status in the chip, and the zoom block lit for the mode on screen.
    func updateStatus(_ status: ImageStatus, zoomMode: ZoomMode) {
        setZoomMode(zoomMode)
        statusView.update(status)
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
    @objc private func workflowClicked(_ sender: NSSegmentedControl) {
        actions.zoom(sender.selectedSegment == 0 ? .manualZoom : .zoomSubject)
    }
    @objc private func smartModeClicked(_ sender: NSToolbarItemGroup) {
        guard Self.smartModes.indices.contains(sender.selectedIndex) else { return }
        actions.zoom(Self.smartModes[sender.selectedIndex].action)
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

/// The photo's status in the middle of the toolbar. Names use the available window width;
/// the folder truncates independently from the photo, with the shared metadata row below.
@MainActor private final class ViewerToolbarStatusView: NSView {
    private static let height: CGFloat = 46
    private var preferredWidth: NSLayoutConstraint!
    private let glass = ChromeGlass(style: .overMedia(.light), cornerRadius: 16)
    private let title = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let separator = NSTextField(labelWithString: "·")
    private let facts = FactsRowView(style: .init(options: .init(size: 11, icons: true), formatBadge: true))

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
        facts.translatesAutoresizingMaskIntoConstraints = false
        facts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.font = .systemFont(ofSize: 12.5, weight: .regular)
        folder.textColor = ProCameraStyle.secondary
        folder.lineBreakMode = .byTruncatingMiddle
        folder.maximumNumberOfLines = 1
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.translatesAutoresizingMaskIntoConstraints = false
        separator.font = folder.font
        separator.textColor = ProCameraStyle.secondary
        let details = NSStackView(views: [title, separator, folder])
        details.orientation = .horizontal
        details.alignment = .centerY
        details.spacing = 8
        details.translatesAutoresizingMaskIntoConstraints = false
        let column = NSStackView(views: [details, facts])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(column)

        // A soft preference lets AppKit keep the surrounding toolbar controls visible.
        preferredWidth = widthAnchor.constraint(equalToConstant: 400)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth,
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
            details.widthAnchor.constraint(lessThanOrEqualTo: glass.contentView.widthAnchor, constant: -24),
            title.widthAnchor.constraint(lessThanOrEqualTo: glass.contentView.widthAnchor, multiplier: 0.5, constant: -24),
            folder.widthAnchor.constraint(lessThanOrEqualTo: glass.contentView.widthAnchor, multiplier: 0.5, constant: -24),
            facts.widthAnchor.constraint(equalTo: glass.contentView.widthAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(updatePreferredWidth),
                                                   name: NSWindow.didResizeNotification, object: window)
        }
        updatePreferredWidth()
    }

    @objc private func updatePreferredWidth() {
        // Keep the centred chip within the middle half of the window, leaving both control groups room.
        // Only window resizing changes this preference; photo and folder names never resize the chip.
        let width = max(220, floor((window?.frame.width ?? 800) / 2))
        if preferredWidth.constant != width { preferredWidth.constant = width }
    }

    func update(_ status: ImageStatus) {
        // Folder news takes the photo title's place; facts keep their fixed slots below.
        let text = status.note ?? (status.title.isEmpty ? "Loupe" : status.title)
        if title.stringValue != text {
            title.stringValue = text
        }
        title.toolTip = status.note ?? [text, status.folder?.path].compactMap { $0 }.joined(separator: "\n")
        title.textColor = ProCameraStyle.color(status.note == nil ? status.titleTone : status.noteTone, monochrome: false)
        facts.update(status.facts, stale: status.stale, pending: status.pending)
        let folderName = status.folder.map(FolderLabel.name(of:)) ?? ""
        if folder.stringValue != folderName { folder.stringValue = folderName }
        folder.toolTip = status.folder?.path
        folder.isHidden = folderName.isEmpty
        separator.isHidden = folderName.isEmpty
    }
}
