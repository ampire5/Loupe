import AppKit
import HomeChrome
import HomeScreenModel
import LoupeCore

enum ViewerStatusAction: Equatable {
    case info, advanced
    case position(Int), key(KeyAction), zoomPercent(Double)
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
    private static let top: CGFloat = 24
    private static let bottom: CGFloat = 5
    private static let row: CGFloat = 17
    var onAction: ((ViewerStatusAction) -> Void)?
    var choices: (() -> ViewerStatusChoices)?
    private let glass = ChromeGlass(style: .overMedia(.light), cornerRadius: 12)
    private let titleLabel = NSTextField(labelWithString: "Loupe")
    private let folderLabel = NSTextField(labelWithString: "")
    let positionButton = NSButton(title: "—", target: nil, action: nil)
    private let compactInfo = NSButton(title: "", target: nil, action: nil)
    let metadataButton = NSButton(title: "", target: nil, action: nil)
    private let exposureLabels = (0..<5).map { _ in NSTextField(labelWithString: "") }
    private let noExposure = NSTextField(labelWithString: "—")
    let modeButton = NSButton(title: "Manual", target: nil, action: nil)
    let zoomButton = NSButton(title: "100%", target: nil, action: nil)
    let profileButton = NSButton(title: "Vision", target: nil, action: nil)
    let groupButton = NSButton(title: "—", target: nil, action: nil)
    private let profileLabel = NSTextField(labelWithString: "Profile")
    private let groupLabel = NSTextField(labelWithString: "Group")
    private let dividers = [NSView(), NSView()]
    private let progress = NSView()
    private var status = ImageStatus()
    private var hasStatus = false
    private var exposure: ImageStatus.Fact?
    private var zoomDetails: ImageStatus.ZoomDetails?
    private var numericPanels: [ViewerStatusPopover.Kind: ViewerStatusPopover] = [:]
    private var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // NSToolbar owns this view's frame. A self-width constraint becomes its fitting minimum on macOS 26.
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .darkAqua)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        for label in [titleLabel, folderLabel, noExposure, profileLabel, groupLabel] + exposureLabels {
            label.font = .systemFont(ofSize: 11)
            label.textColor = ProCameraStyle.primary
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            glass.contentView.addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        for label in [folderLabel, noExposure, profileLabel, groupLabel] { label.textColor = ProCameraStyle.secondary }
        configure(positionButton, "Go to Photo", #selector(positionClicked))
        configure(compactInfo, "Photo information", #selector(infoClicked), symbol: "info.circle")
        configure(metadataButton, "Photo information", #selector(infoClicked))
        configure(modeButton, "SmartZoom mode", #selector(modeClicked))
        configure(zoomButton, "Zoom", #selector(zoomClicked))
        configure(profileButton, "SmartZoom profile", #selector(profileClicked))
        configure(groupButton, "Subject group", #selector(groupClicked))
        zoomButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        compactInfo.contentTintColor = ProCameraStyle.secondary
        for button in [positionButton, metadataButton] {
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }
        for label in exposureLabels {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }
        for value in [modeButton, profileButton, groupButton] { value.font = .systemFont(ofSize: 12, weight: .medium) }

        for divider in dividers {
            divider.wantsLayer = true
            divider.layer?.backgroundColor = ProCameraStyle.separator.withAlphaComponent(0.14).cgColor
            glass.contentView.addSubview(divider)
        }
        progress.wantsLayer = true
        progress.layer?.backgroundColor = ProCameraStyle.secondary.cgColor
        glass.contentView.addSubview(progress)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        toolTip = "Current photo, EXIF and zoom controls"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    private func configure(_ button: NSButton, _ label: String, _ action: Selector, symbol: String? = nil) {
        button.target = self
        button.action = action
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11)
        button.alignment = .left
        button.contentTintColor = ProCameraStyle.primary
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.wraps = false
        button.setAccessibilityLabel(label)
        button.toolTip = label
        if let symbol {
            button.image = Icons.symbol(symbol, pointSize: 11, description: label)
            button.imagePosition = .imageOnly
        }
        glass.contentView.addSubview(button)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissPopover() }
    }

    func update(_ new: ImageStatus) {
        guard !hasStatus || new != status else { return }
        hasStatus = true
        if new.photo != status.photo {
            dismissPopover()
        } else if new.count != status.count, popover?.isShown == true,
                  let page = popover?.contentViewController as? ViewerStatusPopover, page.kind == .position {
            page.updatePhotoCount(new.count)
        }
        status = new
        if !new.pending.contains(.exposure) || exposure == nil { exposure = new.facts.first { $0.kind == .exposure } }
        zoomDetails = new.zoomDetails
        set(titleLabel, new.title.isEmpty ? "Loupe" : new.title)
        titleLabel.textColor = ProCameraStyle.color(new.titleTone, monochrome: false)
        // A root-volume display-name lookup would perform synchronous I/O. The pure path label suffices here.
        set(folderLabel, new.note ?? new.folder.map { StatsLine.folderName(of: $0, volumeName: nil) } ?? "")
        folderLabel.textColor = ProCameraStyle.color(new.note == nil ? .quiet : new.noteTone, monochrome: false)
        folderLabel.toolTip = new.note ?? new.folder?.path
        set(positionButton, new.value(.position) ?? "—")
        positionButton.toolTip = new.value(.position).map { "Go to Photo (\($0))" } ?? "Go to Photo"
        positionButton.setAccessibilityValue(new.value(.position))
        let metadata = ([new.resolutionText] + [ImageStatus.Kind.megapixels, .format, .fileSize].map { new.value($0) })
            .compactMap { $0 }.joined(separator: " · ")
        set(metadataButton, metadata.isEmpty ? "Photo info" : metadata)
        metadataButton.contentTintColor = new.stale ? ProCameraStyle.secondary : ProCameraStyle.primary
        let timings = [new.decodeMilliseconds.map { "Decode \($0) ms" }, new.upscale?.milliseconds.map { "Upscale \($0) ms" }]
            .compactMap { $0 }.joined(separator: " · ")
        let infoTip = [new.title.isEmpty ? nil : new.title, folderLabel.toolTip, metadata.isEmpty ? nil : metadata,
                       exposure?.value, timings.isEmpty ? nil : timings, "Show Info (⌘I)"].compactMap { $0 }.joined(separator: "\n")
        metadataButton.toolTip = infoTip
        compactInfo.toolTip = infoTip
        let parts = exposure?.parts.map(\.text) ?? []
        for i in exposureLabels.indices {
            set(exposureLabels[i], i < parts.count ? parts[i] : "")
            exposureLabels[i].textColor = new.stale ? ProCameraStyle.secondary : ProCameraStyle.primary
        }
        set(noExposure, exposure.map { $0.parts.isEmpty ? $0.value : "" }
            ?? (new.photo == nil ? "—" : (new.pending.contains(.exposure) || (metadata.isEmpty && new.titleTone != .warning)) ? "Reading EXIF…" : "No EXIF"))
        if let zoom = zoomDetails {
            set(modeButton, zoom.mode == .off ? "Manual" : zoom.mode == .frame ? "Auto" : "Pan")
            set(profileButton, zoom.profile)
            set(groupButton, zoom.group)
            let percent = String(format: zoom.scale < 0.1 ? "%.1f%%" : "%.0f%%", zoom.scale * 100)
            set(zoomButton, new.upscale.map { "\(percent) · \($0.indicator)" } ?? percent)
            profileButton.toolTip = "Profile: " + zoom.profile
            profileButton.setAccessibilityLabel("SmartZoom profile: " + zoom.profile)
            groupButton.toolTip = "Group: " + zoom.group
            groupButton.setAccessibilityLabel("Subject group: " + zoom.group)
        } else {
            set(modeButton, "Manual"); set(zoomButton, "—")
            set(profileButton, "—"); set(groupButton, "—")
            profileButton.toolTip = "SmartZoom profile"
            profileButton.setAccessibilityLabel("SmartZoom profile")
            groupButton.toolTip = "Subject group"
            groupButton.setAccessibilityLabel("Subject group")
        }
        let zoomTip = new.value(.zoom) ?? "Zoom presets and exact percentage"
        zoomButton.toolTip = (new.upscale?.detail ?? new.upscale?.indicator).map { zoomTip + "\n" + $0 } ?? zoomTip
        zoomButton.setAccessibilityValue(zoomDetails == nil ? nil : zoomButton.title)
        modeButton.setAccessibilityValue(zoomDetails == nil ? nil : modeButton.title)
        zoomButton.contentTintColor = ProCameraStyle.color(new.facts.first { $0.kind == .zoom }?.tone ?? .normal,
                                                          monochrome: false)
        let hasPhoto = new.photo != nil
        for button in [positionButton, compactInfo, metadataButton] {
            button.isEnabled = hasPhoto
        }
        for button in [modeButton, zoomButton, profileButton, groupButton] {
            button.isEnabled = hasPhoto && zoomDetails != nil
        }
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
        let metadataWidth = ceil(metadataButton.cell!.cellSize.width)
        let capture = max(210, min(320, max(metadataWidth, exposureWidth) + 16))
        let zoom = min(500, max(280, ceil(groupButton.cell!.cellSize.width) + 70,
            ceil(profileButton.cell!.cellSize.width) + 176))
        let file = min(600, max(280, titleLabel.cell!.cellSize.width + 18,
            folderLabel.cell!.cellSize.width + positionWidth + 24))
        return (ceil(file), ceil(capture), ceil(zoom))
    }

    private var positionWidth: CGFloat {
        min(120, max(48, ceil(positionButton.cell!.cellSize.width) + 4))
    }

    /// NSToolbar may compress below this, but extra window space belongs outside the glass surface.
    var preferredWidth: CGFloat {
        let sections = preferredSections
        return sections.file + sections.capture + sections.zoom
    }

    override func layout() {
        super.layout()
        let preferred = preferredSections
        let width = min(bounds.width, preferred.file + preferred.capture + preferred.zoom)
        glass.frame = NSRect(x: 0, y: 0, width: width, height: Self.height)
        for label in exposureLabels { label.isHidden = exposure?.parts.isEmpty != false || label.stringValue.isEmpty }
        noExposure.isHidden = exposure?.parts.isEmpty == false
        if width < 550 { layoutCompact(width: width); return }
        let fileWidth = min(preferred.file, max(180, width - preferred.capture - preferred.zoom))
        let captureWidth = min(preferred.capture, max(210, width - fileWidth - 230))
        let zoomWidth = width - fileWidth - captureWidth
        let captureRect = NSRect(x: fileWidth, y: 0, width: captureWidth, height: Self.height)
        let zoomRect = NSRect(x: fileWidth + captureWidth, y: 0, width: zoomWidth, height: Self.height)
        for (divider, x) in zip(dividers, [captureRect.minX, zoomRect.minX]) {
            divider.isHidden = false
            divider.frame = backingAlignedRect(NSRect(x: x, y: 7, width: 1, height: 32), options: .alignAllEdgesNearest)
        }
        let top = Self.top, bottom = Self.bottom, row = Self.row
        // ChromeGlass's content is unflipped. Both rows are placed explicitly in its coordinates.
        compactInfo.isHidden = true
        folderLabel.isHidden = false
        let positionWidth = positionWidth
        titleLabel.frame = NSRect(x: 9, y: top, width: fileWidth - 18, height: row)
        positionButton.isHidden = status.index == nil
        positionButton.frame = NSRect(x: fileWidth - positionWidth - 6, y: bottom, width: positionWidth, height: row)
        folderLabel.frame = NSRect(x: 9, y: bottom, width: max(0, fileWidth - (positionButton.isHidden ? 18 : positionWidth + 24)), height: row)
        layoutProgress(x: 8, width: fileWidth - 16)

        metadataButton.isHidden = false
        metadataButton.frame = NSRect(x: captureRect.minX + 8, y: top, width: captureWidth - 16, height: row)
        noExposure.frame = NSRect(x: captureRect.minX + 8, y: bottom, width: captureWidth - 16, height: row)
        layoutExposure(x: captureRect.minX + 8, width: captureWidth - 16, gap: 8)
        let left = zoomRect.minX + 8, right = zoomRect.maxX - 8
        let inner = max(0, right - left)
        let labelled = inner >= 200
        profileLabel.isHidden = !labelled; groupLabel.isHidden = !labelled
        let caption: CGFloat = labelled ? 54 : 0
        let valueX = left + caption
        profileLabel.frame = NSRect(x: left, y: top, width: caption, height: row)
        groupLabel.frame = NSRect(x: left, y: bottom, width: caption, height: row)
        let percentWidth = min(preferredZoomWidth, inner * 0.70)
        let modeWidth: CGFloat = inner >= 250 ? 45 : 0
        modeButton.isHidden = modeWidth == 0
        zoomButton.frame = NSRect(x: right - percentWidth, y: top, width: percentWidth, height: row)
        modeButton.frame = NSRect(x: right - percentWidth - modeWidth - 3, y: top, width: modeWidth, height: row)
        profileButton.frame = NSRect(x: valueX, y: top, width: max(0, inner - caption - percentWidth - modeWidth - 6), height: row)
        groupButton.frame = NSRect(x: valueX, y: bottom, width: max(0, inner - caption), height: row)
    }

    /// Keep the current file and zoom in the first row when the native toolbar compresses the summary.
    private func layoutCompact(width: CGFloat) {
        for view in [folderLabel, profileLabel, groupLabel, metadataButton] as [NSView] { view.isHidden = true }
        dividers[1].isHidden = true
        let inset: CGFloat = 8, gap: CGFloat = 6
        let top = Self.top, bottom = Self.bottom, row = Self.row
        let right = width - inset
        compactInfo.isHidden = false
        compactInfo.frame = NSRect(x: inset, y: top, width: 17, height: row)
        let titleX = compactInfo.frame.maxX + 3
        let zoomWidth = min(preferredZoomWidth, width * 0.42)
        zoomButton.frame = NSRect(x: right - zoomWidth, y: top, width: zoomWidth, height: row)
        let positionWidth = width >= 320 && status.index != nil ? self.positionWidth : 0
        positionButton.isHidden = positionWidth == 0
        positionButton.frame = NSRect(x: zoomButton.frame.minX - gap - positionWidth, y: top, width: positionWidth, height: row)
        let titleEnd = positionButton.isHidden ? zoomButton.frame.minX : positionButton.frame.minX
        titleLabel.frame = NSRect(x: titleX, y: top, width: max(0, titleEnd - gap - titleX), height: row)

        let inner = max(0, right - inset)
        let captureWidth = min(225, floor(inner * 0.42))
        dividers[0].isHidden = false
        dividers[0].frame = backingAlignedRect(
            NSRect(x: inset + captureWidth + gap / 2, y: bottom + 3, width: 1, height: row - 6),
            options: .alignAllEdgesNearest)
        noExposure.frame = NSRect(x: inset, y: bottom, width: captureWidth, height: row)
        layoutExposure(x: inset, width: captureWidth, gap: 6)
        let modeWidth: CGFloat = width >= 430 ? 49 : 0
        modeButton.isHidden = modeWidth == 0
        modeButton.frame = NSRect(x: inset + captureWidth + gap, y: bottom, width: modeWidth, height: row)
        let profileX = modeButton.frame.maxX + (modeButton.isHidden ? 0 : gap)
        let profileWidth = floor(max(0, right - profileX - gap) * 0.45)
        profileButton.frame = NSRect(x: profileX, y: bottom, width: profileWidth, height: row)
        let groupX = profileButton.frame.maxX + gap
        groupButton.frame = NSRect(x: groupX, y: bottom, width: max(0, right - groupX), height: row)
        layoutProgress(x: inset, width: inner)
    }

    private var preferredZoomWidth: CGFloat { max(42, ceil(zoomButton.cell!.cellSize.width) + 4) }

    private func layoutProgress(x: CGFloat, width: CGFloat) {
        progress.isHidden = status.progress <= 0
        progress.frame = backingAlignedRect(NSRect(x: x, y: 0, width: width * min(1, max(0, status.progress)), height: 2),
                                            options: .alignAllEdgesNearest)
    }

    /// Keep each visible setting intact. The info control's tooltip and the Info panel keep the full values.
    private func layoutExposure(x origin: CGFloat, width: CGFloat, gap: CGFloat) {
        let end = origin + width
        var x = origin
        for label in exposureLabels where !label.isHidden {
            let measured = ceil(label.cell!.cellSize.width) + 1
            guard x + measured <= end else { label.isHidden = true; continue }
            label.frame = NSRect(x: x, y: Self.bottom, width: measured, height: Self.row)
            x += measured + gap
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
        page.onAction = { [weak self] action in
            if action != .key(.toggleKeepZoom) { self?.popover?.performClose(nil) }
            self?.onAction?(action)
        }
        page.update(index: status.index, count: status.count, zoom: zoomDetails)
        if popover == nil { let p = NSPopover(); p.behavior = .transient; popover = p }
        popover?.contentViewController = page
        popover?.delegate = page
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func dismissPopover() { popover?.performClose(nil) }
    @objc private func menuChosen(_ item: NSMenuItem) {
        if let action = item.representedObject as? ViewerStatusAction { onAction?(action) }
    }
    @objc private func infoClicked() { onAction?(.info) }
    @objc private func modeClicked() { showMenu("mode", from: modeButton) }
    @objc private func profileClicked() { showMenu("profile", from: profileButton) }
    @objc private func groupClicked() { showMenu("group", from: groupButton) }
    @objc private func zoomClicked() { showNumbers(.zoom, from: zoomButton) }
    @objc private func positionClicked() { showNumbers(.position, from: positionButton) }
}
