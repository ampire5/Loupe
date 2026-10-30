import AppKit
import HomeChrome
import LoupeCore

/// The viewer's native toolbar: Back, one interactive status surface, then colour controls and secondary menus.
/// Native overflow yields secondary controls first; the status keeps EXIF and the SmartZoom selection visible.
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
        var statusAction: ((ViewerStatusAction) -> Void)? = nil
        var statusChoices: (() -> ViewerStatusChoices)? = nil
    }

    let nsToolbar: NSToolbar
    private let actions: Actions
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let statusView = ViewerToolbarStatusView()
    private var sliders: [String: NSSlider] = [:]
    private weak var hostWindow: NSWindow?
    private var smartModesShown = false
    var onZoomModesChange: ((NSToolbarItem.Identifier, NSToolbarItem.Identifier) -> Void)?


    private enum Item: String, CaseIterable {
        case back, navigation, zoom, zoomSet, zoomModes, smartModes, smartZoom, keepZoom, zoomMenu, status, autoColour, strength, vibranceSwitch, vibrance, strip, stats, scaling

        var identifier: NSToolbarItem.Identifier { .init("viewer.\(rawValue)") }
        var priority: Int {
            switch self {
            case .status: 1000
            case .back: 120
            case .navigation: 90
            case .zoom: 80
            case .zoomSet: 110
            case .zoomModes, .smartModes: 25
            case .smartZoom: 65
            case .keepZoom: 64
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

    private static let zoomModes: [(String, String, KeyAction)] = [
        ("arrow.down.right.and.arrow.up.left", "Fit", .fit),
        ("1.magnifyingglass", "100 %", .actual100),
        ("arrow.left.and.right", "Fit Width", .fitWidth),
        ("arrow.up.and.down", "Fit Height", .fitHeight),
        ("arrow.up.left.and.arrow.down.right", "Fill", .fill),
    ]

    private static let smartModes: [(String, String, SmartZoomMode)] = [
        ("viewfinder", "Auto", .frame),
        ("arrow.up.and.down.and.arrow.left.and.right", "Pan only", .pan),
    ]

    /// The colour switches, each in front of its slider; the `tag` of a switch's item is its index here.
    private static let colourSwitches: [(item: Item, symbol: String, label: String, action: KeyAction)] = [
        (.autoColour, "wand.and.stars", "Auto Colour", .toggleAutoColor),
        (.vibranceSwitch, "drop.halffull", "Vibrance", .toggleVibrance),
    ]

    /// The status takes available space between Back and the secondary controls. Global centring would force it
    /// into overflow beside the traffic lights at small widths, even when its compact form fits the toolbar.
    private static let order: [NSToolbarItem.Identifier] = [
        Item.back, .navigation, .zoom, .zoomSet, .zoomModes, .smartZoom, .keepZoom, .zoomMenu,
    ].map(\.identifier) + [.flexibleSpace, Item.status.identifier, .flexibleSpace] + [
        Item.autoColour, .strength, .vibranceSwitch, .vibrance, .strip, .stats, .scaling,
    ].map(\.identifier)

    init(actions: Actions) {
        self.actions = actions
        nsToolbar = NSToolbar(identifier: "viewer.photo")
        super.init()
        nsToolbar.delegate = self
        nsToolbar.displayMode = .iconOnly
        nsToolbar.allowsUserCustomization = false
        nsToolbar.autosavesConfiguration = false
        nsToolbar.centeredItemIdentifiers = []
        statusView.choices = actions.statusChoices
        statusView.onAction = { action in
            switch action {
            case .info: actions.info()
            case .step(let step): actions.step(step)
            case .key(let key): actions.zoom(key)
            case .advanced: actions.smartZoom()
            default: actions.statusAction?(action)
            }
        }
        for item in Item.allCases {
            let toolbarItem = make(item)
            toolbarItem.visibilityPriority = .init(item.priority)
            items[item.identifier] = toolbarItem
        }
    }

    func attach(to window: NSWindow) {
        if let hostWindow { NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: hostWindow) }
        hostWindow = window
        NotificationCenter.default.addObserver(self, selector: #selector(updateWidthBudget), name: NSWindow.didResizeNotification, object: window)
        updateWidthBudget()
    }

    @objc private func updateWidthBudget() {
        guard let hostWindow, let item = items[Item.status.identifier] else { return }
        let width = min(680, max(140, hostWindow.frame.width - 800))
        if item.minSize.width != width { item.minSize = NSSize(width: width, height: ViewerToolbarStatusView.height) }
    }

    private func make(_ item: Item) -> NSToolbarItem {
        switch item {
        case .back:
            return button(item, symbol: "arrow.backward", label: "Back", tip: "Back to where the photo was opened from",
                          action: #selector(backClicked))
        case .navigation:
            return group(item, [("chevron.left", "Previous", "Previous photo"), ("chevron.right", "Next", "Next photo")], action: #selector(stepClicked(_:)))
        case .zoom:
            return group(item, [("minus.magnifyingglass", "Zoom Out", "Zoom out"), ("plus.magnifyingglass", "Zoom In", "Zoom in")], action: #selector(zoomClicked(_:)))
        case .zoomSet:
            let workflow = NSToolbarItemGroup(itemIdentifier: item.identifier,
                titles: ["Manual", "SmartZoom"], selectionMode: .selectOne,
                labels: ["Manual zoom", "SmartZoom"], target: self, action: #selector(workflowClicked(_:)))
            workflow.controlRepresentation = .expanded
            workflow.label = "Zoom workflow"
            workflow.toolTip = "Manual zoom / SmartZoom"
            return workflow
        case .zoomModes:
            return group(item, Self.zoomModes.map { ($0.0, $0.1, $0.1) }, mode: .selectOne, action: #selector(presetClicked(_:)))
        case .smartModes:
            return group(item, Self.smartModes.map { ($0.0, $0.1, $0.1) }, mode: .selectOne,
                         action: #selector(smartModeClicked(_:)))
        case .smartZoom:
            return button(item, symbol: "viewfinder", label: "SmartZoom", tip: "SmartZoom settings", action: #selector(smartZoomClicked))
        case .keepZoom:
            return group(item, [("pin", "Keep Zoom", "Keep zoom and position between photos")], mode: .selectAny, action: #selector(keepZoomClicked))
        case .zoomMenu:
            return menuItem(item, symbol: "ellipsis.circle", label: "Zoom Options", tip: "More zoom options",
                            menu: Settings.shared.makeZoomToolbarMenu())
        case .autoColour, .vibranceSwitch:
            let index = Self.colourSwitches.firstIndex { $0.item == item } ?? 0
            let part = Self.colourSwitches[index]
            let toggle = group(item, [(part.symbol, part.label, part.label)], mode: .selectAny,
                               action: #selector(colourClicked(_:)))
            for subitem in toggle.subitems {
                subitem.tag = index; subitem.target = self; subitem.action = #selector(colourClicked(_:))
            }
            return toggle
        case .strength:
            return sliderItem(item, label: "Auto Colour Strength", tip: "How strongly Auto Colour is applied", key: "auto-color-strength")
        case .vibrance:
            return sliderItem(item, label: "Vibrance Amount", tip: "How much vibrance is added", key: "vibrance-amount")
        case .stats:
            return button(item, symbol: "text.alignleft", label: "Status", tip: "Show or hide the stats bar (I)", action: #selector(statsClicked))
        case .strip:
            return button(item, symbol: "rectangle.bottomthird.inset.filled", label: "Filmstrip", tip: "Pin or hide the filmstrip", action: #selector(stripClicked))
        case .status:
            let toolbarItem = NSToolbarItem(itemIdentifier: item.identifier)
            toolbarItem.label = "Current photo"
            toolbarItem.toolTip = "Current photo and its place in the folder"
            toolbarItem.view = statusView
            toolbarItem.isBordered = false
            // Explicit bounds let NSToolbar compress this manually laid-out custom view.
            toolbarItem.minSize = NSSize(width: 140, height: ViewerToolbarStatusView.height)
            toolbarItem.maxSize = NSSize(width: statusView.preferredWidth,
                                        height: ViewerToolbarStatusView.height)
            return toolbarItem
        case .scaling:
            return menuItem(item, symbol: "slider.horizontal.3", label: "Scaling", tip: "Scaling filters", menu: Settings.shared.makeScalingMenu())
        }
    }

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

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.order.map { smartModesShown && $0 == Item.zoomModes.identifier ? Item.smartModes.identifier : $0 }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.order + [Item.smartModes.identifier]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        items[identifier]
    }

    func setBackDestination(_ destination: String?) {
        guard let item = items[Item.back.identifier] else { return }
        let title = destination ?? "Back"
        let label = destination.map { "Back to \($0)" } ?? "Back"
        // `title` is visible beside the native arrow even in icon-only toolbar
        // mode; `label` also describes the destination in the overflow menu.
        if item.title != title { item.title = title }
        if item.label != label { item.label = label }
        if item.toolTip != label { item.toolTip = label }
        if item.isEnabled != (destination != nil) { item.isEnabled = destination != nil }
    }

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

    func updateStatus(_ status: ImageStatus, zoomMode: ZoomMode? = nil, screenShare: Bool = false) {
        let smartMode = status.zoomDetails?.mode ?? .off
        showSmartModes(smartMode != .off)
        if let modes = items[Item.smartModes.identifier] as? NSToolbarItemGroup {
            let selected = smartMode == .frame ? 0 : smartMode == .pan ? 1 : -1
            if modes.selectedIndex != selected { modes.selectedIndex = selected }
        }
        statusView.update(status)
        if let item = items[Item.status.identifier], item.maxSize.width != statusView.preferredWidth {
            item.maxSize = NSSize(width: statusView.preferredWidth, height: ViewerToolbarStatusView.height)
        }
        if let workflow = items[Item.zoomSet.identifier] as? NSToolbarItemGroup {
            workflow.selectedIndex = (status.zoomDetails?.mode ?? .off) == .off ? 0 : 1
            workflow.isEnabled = status.photo != nil
        }
        let selected: Int
        switch zoomMode {
        case .fit?: selected = 0
        case .actual(1)?: selected = 1
        case .fitWidth?: selected = 2
        case .fitHeight?: selected = 3
        case .fill?: selected = 4
        default: selected = -1
        }
        if let modes = items[Item.zoomModes.identifier] as? NSToolbarItemGroup,
           modes.selectedIndex != selected { modes.selectedIndex = selected }
        if let keep = items[Item.keepZoom.identifier] as? NSToolbarItemGroup {
            keep.setSelected(status.zoomDetails?.keepingZoom == true, at: 0)
            keep.isEnabled = status.photo != nil
        }
    }

    private func showSmartModes(_ smart: Bool) {
        guard smart != smartModesShown else { return }
        let old = smartModesShown ? Item.smartModes.identifier : Item.zoomModes.identifier
        let new = smart ? Item.smartModes.identifier : Item.zoomModes.identifier
        smartModesShown = smart
        // The standalone toolbar and the window's retained host use the same
        // cached groups; only the mode slot changes, never the whole toolbar.
        if let index = nsToolbar.items.firstIndex(where: { $0.itemIdentifier == old }) {
            nsToolbar.removeItem(at: index)
            nsToolbar.insertItem(withItemIdentifier: new, at: index)
        }
        onZoomModesChange?(old, new)
    }

    @objc private func smartModeClicked(_ sender: NSToolbarItemGroup) {
        guard Self.smartModes.indices.contains(sender.selectedIndex) else { return }
        actions.statusAction?(.mode(Self.smartModes[sender.selectedIndex].2))
    }

    @objc private func stepClicked(_ sender: NSToolbarItemGroup) { actions.step(sender.selectedIndex == 0 ? -1 : 1) }
    @objc private func zoomClicked(_ sender: NSToolbarItemGroup) { actions.zoom(sender.selectedIndex == 0 ? .zoomOut : .zoomIn) }
    @objc private func presetClicked(_ sender: NSToolbarItemGroup) {
        guard Self.zoomModes.indices.contains(sender.selectedIndex) else { return }
        actions.zoom(Self.zoomModes[sender.selectedIndex].2)
    }
    @objc private func workflowClicked(_ sender: NSToolbarItemGroup) {
        actions.zoom(sender.selectedIndex == 0 ? .manualZoom : .zoomSubject)
    }
    @objc private func smartZoomClicked() { actions.smartZoom() }
    @objc private func keepZoomClicked() { actions.zoom(.toggleKeepZoom) }

    @objc private func backClicked() { actions.back() }
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
}
