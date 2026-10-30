import AppKit
import HomeChrome
import HomeScreenModel
import LoupeCore

enum ViewerStatusAction: Equatable {
    case info, advanced
    case step(Int), position(Int), key(KeyAction), zoomPercent(Double)
    case mode(SmartZoomMode), profile(String), group(SubjectKind?)
}

struct ViewerStatusChoices {
    var profiles: [String] = []
    var groups: [SubjectKind] = []
    var selectedGroup: SubjectKind?
}

/// One retained 46 pt surface, with content-sized sections and a bounded native toolbar width.
@MainActor final class ViewerToolbarStatusView: NSView {
    static let height: CGFloat = 46
    var onAction: ((ViewerStatusAction) -> Void)?
    var choices: (() -> ViewerStatusChoices)?
    private let content = NSView()
    private let titleLabel = NSTextField(labelWithString: "Loupe")
    private let folderLabel = NSTextField(labelWithString: "")
    let positionButton = NSButton(title: "—", target: nil, action: nil)
    private let previous = NSButton(title: "", target: nil, action: nil)
    private let next = NSButton(title: "", target: nil, action: nil)
    private let compactInfo = NSButton(title: "", target: nil, action: nil)
    let metadataButton = NSButton(title: "", target: nil, action: nil)
    private let exposureLabels = (0..<5).map { _ in NSTextField(labelWithString: "") }
    private let noExposure = NSTextField(labelWithString: "—")
    let modeButton = NSButton(title: "Manual", target: nil, action: nil)
    let zoomButton = NSButton(title: "100%", target: nil, action: nil)
    let profileButton = NSButton(title: "Vision", target: nil, action: nil)
    let groupButton = NSButton(title: "—", target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "Zoom")
    private let modeLabel = NSTextField(labelWithString: "Mode")
    private let profileLabel = NSTextField(labelWithString: "Profile")
    private let groupLabel = NSTextField(labelWithString: "Group")
    private let dividers = [NSView(), NSView()]
    private let progress = NSView()
    private var status = ImageStatus()
    private var hasStatus = false
    private var exposure: ImageStatus.Fact?
    private var zoomDetails: ImageStatus.ZoomDetails?
    private var metadataText = ""
    private var numericPanels: [ViewerStatusPopover.Kind: ViewerStatusPopover] = [:]
    private var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // NSToolbar owns this view's frame. A self-width constraint becomes its fitting minimum on macOS 26.
        translatesAutoresizingMaskIntoConstraints = false
        // The native toolbar owns the material and appearance. Keep controls on
        // a plain content view instead of stacking a second glass surface.
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        for label in [titleLabel, folderLabel, noExposure, profileLabel, groupLabel, zoomLabel, modeLabel] + exposureLabels {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            content.addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        for label in [folderLabel, profileLabel, groupLabel, zoomLabel, modeLabel] { label.textColor = .secondaryLabelColor }
        configure(positionButton, "Photo position", #selector(positionClicked))
        configure(previous, "Previous photo", #selector(previousClicked), symbol: "chevron.left")
        configure(next, "Next photo", #selector(nextClicked), symbol: "chevron.right")
        configure(compactInfo, "Photo information", #selector(infoClicked), symbol: "info.circle")
        configure(metadataButton, "Photo information", #selector(infoClicked))
        configure(modeButton, "SmartZoom mode", #selector(modeClicked))
        configure(zoomButton, "Zoom", #selector(zoomClicked))
        configure(profileButton, "SmartZoom profile", #selector(profileClicked))
        configure(groupButton, "Subject group", #selector(groupClicked))
        zoomButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for value in [modeButton, profileButton, groupButton] { value.font = .systemFont(ofSize: 12, weight: .medium) }
        for caption in [zoomLabel, modeLabel, profileLabel, groupLabel] {
            caption.textColor = .secondaryLabelColor
            caption.stringValue = caption.stringValue.uppercased()
        }
        for divider in dividers {
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
            content.addSubview(divider)
        }
        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        content.addSubview(progress)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        toolTip = "Current photo, EXIF and zoom controls"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    private static func color(_ tone: ImageStatus.Tone) -> NSColor {
        switch tone {
        case .normal: .labelColor
        case .quiet: .secondaryLabelColor
        case .adjusted: .controlAccentColor
        case .good: .systemGreen
        case .caution: .systemOrange
        case .warning: .systemRed
        }
    }

    private func configure(_ button: NSButton, _ label: String, _ action: Selector, symbol: String? = nil) {
        button.target = self
        button.action = action
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11)
        button.alignment = .left
        button.contentTintColor = .labelColor
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.wraps = false
        button.setAccessibilityLabel(label)
        button.toolTip = label
        if let symbol {
            button.image = Icons.symbol(symbol, pointSize: 11, description: label)
            button.imagePosition = .imageOnly
        }
        content.addSubview(button)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissPopover() }
    }

    func update(_ new: ImageStatus) {
        guard !hasStatus || new != status else { return }
        hasStatus = true
        if !status.navigationKey.isEmpty, new.navigationKey != status.navigationKey { dismissPopover() }
        status = new
        if !new.pending.contains(.exposure) || exposure == nil { exposure = new.facts.first { $0.kind == .exposure } }
        zoomDetails = new.zoomDetails
        set(titleLabel, new.title.isEmpty ? "Loupe" : new.title)
        titleLabel.textColor = Self.color(new.titleTone)
        // A root-volume display-name lookup would perform synchronous I/O. The pure path label suffices here.
        set(folderLabel, new.note ?? new.folder.map { StatsLine.folderName(of: $0, volumeName: nil) } ?? "")
        folderLabel.textColor = Self.color(new.note == nil ? .quiet : new.noteTone)
        folderLabel.toolTip = new.note ?? new.folder?.path
        set(positionButton, new.value(.position) ?? "—")
        let metadata = [ImageStatus.Kind.size, .megapixels, .format, .fileSize]
            .compactMap { new.value($0) }.joined(separator: "  ")
        metadataText = metadata.isEmpty ? "Info" : metadata
        set(metadataButton, metadataText)
        metadataButton.toolTip = [metadata, exposure?.value, "Show Info (⌘I)"].compactMap { $0 }.joined(separator: "\n")
        let parts = exposure?.parts.map(\.text) ?? []
        for i in exposureLabels.indices {
            set(exposureLabels[i], i < parts.count ? parts[i] : "")
            exposureLabels[i].textColor = new.stale ? .secondaryLabelColor : .labelColor
        }
        set(noExposure, exposure.map { $0.parts.isEmpty ? $0.value : "" }
            ?? (new.photo == nil ? "—" : (new.pending.contains(.exposure) || (metadata.isEmpty && new.titleTone != .warning)) ? "Reading EXIF…" : "No EXIF"))
        if let zoom = zoomDetails {
            set(modeButton, zoom.mode == .off ? "Manual" : zoom.mode == .frame ? "Auto" : "Pan")
            set(profileButton, zoom.profile)
            set(groupButton, zoom.group)
            set(zoomButton, String(format: zoom.scale < 0.1 ? "%.1f%%" : "%.0f%%", zoom.scale * 100))
            profileButton.toolTip = "Profile: " + zoom.profile
            profileButton.setAccessibilityLabel("SmartZoom profile: " + zoom.profile)
            groupButton.toolTip = "Group: " + zoom.group
            groupButton.setAccessibilityLabel("Subject group: " + zoom.group)
        } else {
            set(modeButton, "Manual"); set(zoomButton, "—")
            set(profileButton, "—"); set(groupButton, "—")
        }
        zoomButton.toolTip = new.value(.zoom) ?? "Zoom presets and exact percentage"
        let hasPhoto = new.photo != nil
        for button in [previous, next, positionButton, modeButton, zoomButton, profileButton, groupButton] {
            button.isEnabled = hasPhoto
        }
        previous.isEnabled = hasPhoto && (new.index ?? 0) > 0
        next.isEnabled = hasPhoto && (new.count.map { (new.index ?? 0) + 1 < $0 } ?? true)
        // Progress is a frame change only; it never resizes the item or wakes the image renderer.
        needsLayout = true
    }

    private func set(_ label: NSTextField, _ value: String) {
        if label.stringValue != value { label.stringValue = value }
        label.toolTip = value.isEmpty ? nil : value
    }
    private func set(_ button: NSButton, _ value: String) {
        if button.title != value { button.title = value }
    }

    private var preferredSections: (file: CGFloat, capture: CGFloat, zoom: CGFloat) {
        let exposureCells = exposure?.parts.isEmpty == false ? exposureLabels.filter { !$0.stringValue.isEmpty } : []
        let exposureWidth = exposureCells.reduce(CGFloat(0)) { $0 + ceil($1.cell!.cellSize.width) + 1 }
            + CGFloat(max(0, exposureCells.count - 1)) * 8
        let metadataWidth = ceil((metadataText as NSString).size(withAttributes: [.font: metadataButton.font!]).width)
        let capture = max(210, min(320, max(metadataWidth, exposureWidth) + 16))
        let zoom = min(500, max(280, ceil(groupButton.cell!.cellSize.width) + 70,
            ceil(profileButton.cell!.cellSize.width) + 176))
        let file = min(600, max(280, titleLabel.cell!.cellSize.width + 18, folderLabel.cell!.cellSize.width + 88))
        return (ceil(file), ceil(capture), ceil(zoom))
    }

    /// NSToolbar may compress below this, but extra window space belongs outside the information content.
    var preferredWidth: CGFloat {
        let sections = preferredSections
        return sections.file + sections.capture + sections.zoom
    }

    override func layout() {
        super.layout()
        let width = min(bounds.width, preferredWidth)
        content.frame = NSRect(x: 0, y: 0, width: width, height: Self.height)
        for label in exposureLabels { label.isHidden = exposure?.parts.isEmpty != false || label.stringValue.isEmpty }
        if width < 270 { layoutMinimal(width: width); return }
        let compact = width < 430
        let fileCollapsed = width < 550
        let preferred = preferredSections
        let capturePreferred = preferred.capture
        let groupPreferred = preferred.zoom
        let filePreferred = preferred.file
        let fileWidth: CGFloat = fileCollapsed ? 24 : min(filePreferred, max(180, width - capturePreferred - groupPreferred))
        let captureWidth: CGFloat = compact ? min(164, max(126, (width - fileWidth) * 0.48))
            : min(capturePreferred, max(210, width - fileWidth - 230))
        let zoomWidth = max(0, width - fileWidth - captureWidth)
        let captureRect = NSRect(x: fileWidth, y: 0, width: captureWidth, height: Self.height)
        let zoomRect = NSRect(x: fileWidth + captureWidth, y: 0, width: zoomWidth, height: Self.height)
        dividers.forEach { $0.isHidden = false }
        modeButton.isHidden = false
        for (divider, x) in zip(dividers, [captureRect.minX, zoomRect.minX]) {
            divider.frame = NSRect(x: x, y: 6, width: 1, height: 34)
        }
        let top: CGFloat = 24, bottom: CGFloat = 5, row: CGFloat = 17
        // The plain content view is unflipped; both rows use its coordinates.
        for view in [titleLabel, folderLabel, positionButton, previous, next] { view.isHidden = fileCollapsed }
        compactInfo.isHidden = !fileCollapsed
        compactInfo.frame = NSRect(x: 2, y: 7, width: 20, height: 32)
        if !fileCollapsed {
            let positionWidth: CGFloat = 64
            titleLabel.frame = NSRect(x: 9, y: top, width: max(0, fileWidth - 18), height: row)
            positionButton.isHidden = fileWidth < 320
            positionButton.frame = NSRect(x: fileWidth - positionWidth - 6, y: bottom, width: positionWidth, height: row)
            previous.isHidden = true; next.isHidden = true // Native navigation buttons already live to the left.
            folderLabel.frame = NSRect(x: 9, y: bottom, width: max(0, fileWidth - (positionButton.isHidden ? 18 : positionWidth + 24)), height: row)
        }
        progress.isHidden = fileCollapsed || status.progress <= 0
        progress.frame = NSRect(x: 8, y: 0, width: max(0, fileWidth - 16) * min(1, max(0, status.progress)), height: 2)

        metadataButton.isHidden = compact
        set(metadataButton, metadataText)
        metadataButton.frame = NSRect(x: captureRect.minX + 8, y: top, width: max(0, captureWidth - 16), height: row)
        let hasParts = exposure?.parts.isEmpty == false
        noExposure.isHidden = hasParts
        noExposure.frame = NSRect(x: captureRect.minX + 8, y: compact ? 15 : bottom,
                                 width: max(0, captureWidth - 16), height: row)
        if compact {
            layoutExposure(Array(exposureLabels.prefix(3)), x: captureRect.minX + 5, y: top, width: captureWidth - 10, gap: 3)
            layoutExposure(Array(exposureLabels.suffix(2)), x: captureRect.minX + 5, y: bottom, width: captureWidth - 10, gap: 3)
        } else {
            layoutExposure(exposureLabels, x: captureRect.minX + 8, y: bottom, width: captureWidth - 16, gap: 8)
        }
        let left = zoomRect.minX + (compact ? 5 : 8), right = zoomRect.maxX - (compact ? 5 : 8)
        let inner = max(0, right - left)
        zoomLabel.isHidden = true; modeLabel.isHidden = true
        let labelled = inner >= 200
        profileLabel.isHidden = !labelled; groupLabel.isHidden = !labelled
        let caption: CGFloat = labelled ? 54 : 0
        let valueX = left + caption
        profileLabel.frame = NSRect(x: left, y: top, width: caption, height: row)
        groupLabel.frame = NSRect(x: left, y: bottom, width: caption, height: row)
        let percentWidth: CGFloat = min(49, inner * 0.25)
        let modeWidth: CGFloat = inner >= 250 ? 45 : 0
        modeButton.isHidden = modeWidth == 0
        zoomButton.frame = NSRect(x: right - percentWidth, y: top, width: percentWidth, height: row)
        modeButton.frame = NSRect(x: right - percentWidth - modeWidth - 3, y: top, width: modeWidth, height: row)
        profileButton.frame = NSRect(x: valueX, y: top, width: max(0, inner - caption - percentWidth - modeWidth - 6), height: row)
        groupButton.frame = NSRect(x: valueX, y: bottom, width: max(0, inner - caption), height: row)
    }

    /// Below the normal three-column budget the two essential sections use one row each. AppKit reserves
    /// titlebar space for traffic lights and overflow too, so a 320 pt window can leave less than 270 pt here.
    private func layoutMinimal(width: CGFloat) {
        for view in [titleLabel, folderLabel, positionButton, previous, next, compactInfo, profileLabel, groupLabel, zoomLabel, modeLabel, progress] {
            view.isHidden = true
        }
        dividers.forEach { $0.isHidden = true }
        modeButton.isHidden = true
        metadataButton.isHidden = false
        set(metadataButton, "")
        metadataButton.frame = NSRect(x: 3, y: 24, width: max(0, width - 6), height: 17)
        let hasParts = exposure?.parts.isEmpty == false
        noExposure.isHidden = hasParts
        noExposure.frame = metadataButton.frame
        layoutExposure(exposureLabels, x: 4, y: 24, width: width - 8, gap: 1)
        profileButton.isHidden = false; groupButton.isHidden = false; zoomButton.isHidden = false
        let profileWidth = max(40, (width - 50) * 0.43)
        profileButton.frame = NSRect(x: 4, y: 5, width: profileWidth, height: 17)
        zoomButton.frame = NSRect(x: width - 45, y: 5, width: 41, height: 17)
        groupButton.frame = NSRect(x: profileWidth + 7, y: 5, width: max(0, width - profileWidth - 55), height: 17)
    }

    /// Compress every value proportionally, so a long ISO/focal length cannot cover the next section.
    /// Full values remain available to VoiceOver and in the EXIF tooltip, including the narrowest window.
    private func layoutExposure(_ labels: [NSTextField], x origin: CGFloat, y: CGFloat, width: CGFloat, gap: CGFloat) {
        let shown = labels.filter { !$0.isHidden }
        let measured = shown.map { ceil($0.cell!.cellSize.width) + 1 }
        let available = max(0, width - gap * CGFloat(max(0, shown.count - 1)))
        let total = measured.reduce(0, +)
        let ratio = total > 0 ? min(1, available / total) : 1
        var x = origin
        for (label, natural) in zip(shown, measured) {
            let width = natural * ratio
            label.frame = NSRect(x: x, y: y, width: width, height: 17)
            label.toolTip = label.stringValue
            x += width + gap
        }
    }

    /// Menus deliberately take a fresh snapshot on open, never on a photo update or layout pass.
    func makeMenu(for kind: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: ViewerStatusAction, selected: Bool = false) {
            let item = NSMenuItem(title: title, action: #selector(menuChosen(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action; item.state = selected ? .on : .off
            menu.addItem(item)
        }
        switch kind {
        case "mode":
            for mode in SmartZoomMode.allCases { add(mode.title, .mode(mode), selected: zoomDetails?.mode == mode) }
        case "profile":
            for profile in choices?().profiles ?? [] { add(profile, .profile(profile), selected: zoomDetails?.profile == profile) }
        case "group":
            let current = choices?() ?? ViewerStatusChoices()
            add("First available group", .group(nil), selected: current.selectedGroup == nil)
            for group in current.groups { add(group.title, .group(group), selected: current.selectedGroup == group) }
        default: break
        }
        menu.addItem(.separator())
        add("SmartZoom settings…", .advanced)
        return menu
    }

    private func showMenu(_ kind: String, from button: NSButton) {
        makeMenu(for: kind).popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.minY - 4), in: button)
    }
    private func showNumbers(_ kind: ViewerStatusPopover.Kind, from button: NSButton) {
        let page: ViewerStatusPopover
        if let existing = numericPanels[kind] { page = existing }
        else { page = ViewerStatusPopover(kind: kind); numericPanels[kind] = page }
        page.onAction = { [weak self] action in self?.popover?.performClose(nil); self?.onAction?(action) }
        page.update(index: status.index, count: status.count, zoom: zoomDetails)
        if popover == nil { let p = NSPopover(); p.behavior = .transient; popover = p }
        popover?.contentViewController = page
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func dismissPopover() { popover?.performClose(nil) }
    @objc private func menuChosen(_ item: NSMenuItem) {
        if let action = item.representedObject as? ViewerStatusAction { onAction?(action) }
    }
    @objc private func infoClicked() { onAction?(.info) }
    @objc private func previousClicked() { onAction?(.step(-1)) }
    @objc private func nextClicked() { onAction?(.step(1)) }
    @objc private func modeClicked() { showMenu("mode", from: modeButton) }
    @objc private func profileClicked() { showMenu("profile", from: profileButton) }
    @objc private func groupClicked() { showMenu("group", from: groupButton) }
    @objc private func zoomClicked() { showNumbers(.zoom, from: zoomButton) }
    @objc private func positionClicked() { showNumbers(.position, from: positionButton) }
}
