import AppKit
import HomeScreenKit
import HomeScreenModel
import LoupeCore

/// Docked File View information. The controls survive selection and navigation; only changed values are assigned.
@MainActor public final class BrowserInspectorController: NSViewController {
    public let loader: BrowserInspectorLoader
    public var onClose: (() -> Void)?
    private let defaults: UserDefaults
    private let name = NSTextField(wrappingLabelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let preview = NSImageView()
    private let summary = InspectorRows()
    private var sections: [String: InspectorSection] = [:]
    private let content = NSStackView()
    private let scroll = NSScrollView()
    private let reveal = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let copyPath = NSButton(title: "Copy Path", target: nil, action: nil)
    private var displayed: BrowserInspectorContent?
    private var previewImage: CGImage?
    private var detailsWindow: NSWindow?

    public init(thumbnails: ThumbnailStore? = nil, defaults: UserDefaults = .standard,
                loader: BrowserInspectorLoader? = nil) {
        self.defaults = defaults
        self.loader = loader ?? BrowserInspectorLoader(catalog: { entry in
            guard let thumbnails else { return nil }
            let facts = await thumbnails.facts([entry.url])[entry.url]
            let header = await thumbnails.headerFacts([entry.url])[entry.url]
            let image = await thumbnails.cell(entry.url, maxPixel: 160)
            let metadata: PhotoMetadata?
            if let size = entry.size.flatMap(Int.init(exactly:)), let date = entry.date {
                metadata = await thumbnails.photoMetadata(for: entry.url, stamp: FileStamp(modified: date, size: size))
            } else { metadata = nil }
            return BrowserInspectorSeed(facts: BrowserInspectorSeed.supplement(facts, with: header), thumbnail: image, metadata: metadata)
        }, reader: { entry in
            let result = await Task.detached(priority: .utility) { BrowserInspectorResult.read(entry) }.value
            if let thumbnails, let size = entry.size.flatMap(Int.init(exactly:)), let date = entry.date,
               result.metadata.modified == date {
                await thumbnails.keepPhotoMetadata(result.metadata, for: entry.url, stamp: FileStamp(modified: date, size: size))
            }
            return result
        })
        super.init(nibName: nil, bundle: nil)
        self.loader.onChange = { [weak self] in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .withinWindow
        root.state = .followsWindowActiveState
        view = root
        let heading = NSTextField(labelWithString: "Information")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide Info")!,
                             target: self, action: #selector(closeClicked))
        close.bezelStyle = .inline
        close.isBordered = false
        close.toolTip = "Hide Info (⌘I)"
        let spacer = NSView()
        let header = NSStackView(views: [heading, spacer, close])
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        let document = FlippedInspectorView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
        ])
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.isSelectable = true
        name.maximumNumberOfLines = 3
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([preview.widthAnchor.constraint(equalToConstant: 64), preview.heightAnchor.constraint(equalToConstant: 64)])
        let identity = NSStackView(views: [name, subtitle])
        identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 3
        let snapshot = NSStackView(views: [preview, identity])
        snapshot.orientation = .horizontal; snapshot.spacing = 12
        add(snapshot)
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 12)
        add(message)
        summary.onFullText = { [weak self] label, value in self?.showFullText(label, value) }
        add(summary)
        for title in ["Capture", "Generation", "File and Location", "Technical Details"] {
            let section = InspectorSection(title: title, defaults: defaults)
            section.rows.onFullText = { [weak self] label, value in self?.showFullText(label, value) }
            sections[title] = section
            add(section)
        }
        reveal.target = self; reveal.action = #selector(revealClicked)
        copyPath.target = self; copyPath.action = #selector(copyPathClicked)
        reveal.controlSize = .small; copyPath.controlSize = .small
        let actions = NSStackView(views: [reveal, copyPath])
        actions.orientation = .vertical; actions.alignment = .leading; actions.spacing = 8
        add(actions)
        refresh()
    }

    private func add(_ child: NSView) {
        content.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let value = loader.content
        if value != displayed {
            if name.stringValue != value.name { name.stringValue = value.name }
            if subtitle.stringValue != value.subtitle { subtitle.stringValue = value.subtitle }
            message.stringValue = value.message ?? ""
            message.isHidden = value.message == nil
            summary.show(value.summary)
            for (title, section) in sections {
                let data = value.sections.first { $0.title == title }
                section.show(data?.rows ?? [], present: data != nil, pending: value.pendingSections.contains(title))
            }
            let hasPath = loader.entry?.url.isFileURL == true
            reveal.isHidden = !hasPath; copyPath.isHidden = !hasPath
            displayed = value
        }
        let image = loader.thumbnail
        if image !== previewImage {
            previewImage = image
            preview.image = image.map { NSImage(cgImage: $0, size: .zero) }
        }
        if image == nil {
            preview.image = NSImage(systemSymbolName: loader.entry?.isContainer == true ? "folder" : "photo", accessibilityDescription: nil)
            preview.contentTintColor = .secondaryLabelColor
        } else { preview.contentTintColor = nil }
    }

    @objc private func closeClicked() { onClose?() }
    @objc private func revealClicked() {
        guard let url = loader.entry?.url, url.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([ArchivePath.split(url)?.archive ?? url])
    }
    @objc private func copyPathClicked() {
        guard let url = loader.entry?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.isFileURL ? url.path : url.absoluteString, forType: .string)
    }

    private func showFullText(_ label: String, _ value: String) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = label
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isRichText = false; text.isSelectable = true
        text.autoresizingMask = [.width]
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.font = .systemFont(ofSize: 13)
        text.string = value
        scroll.documentView = text
        window.contentView?.addSubview(scroll)
        detailsWindow?.close()
        detailsWindow = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }
}

private final class FlippedInspectorView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class InspectorSection: NSStackView {
    let rows = InspectorRows()
    private let disclosure: NSButton
    private let status = NSTextField(labelWithString: "")
    private let key: String
    private let defaults: UserDefaults
    init(title: String, defaults: UserDefaults) {
        self.defaults = defaults
        key = "browserInspector.expanded.\(title)"
        disclosure = NSButton(title: title, target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        let line = NSBox(); line.boxType = .separator
        addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        disclosure.setButtonType(.onOff)
        disclosure.bezelStyle = .disclosure
        disclosure.font = .systemFont(ofSize: 13, weight: .semibold)
        disclosure.state = (defaults.object(forKey: key) as? Bool ?? true) ? .on : .off
        disclosure.target = self; disclosure.action = #selector(toggle)
        // The native triangle and an adjacent text label share the same click target and accessibility label.
        let label = NSButton(title: title, target: self, action: #selector(toggleLabel))
        label.isBordered = false; label.font = .systemFont(ofSize: 13, weight: .semibold)
        let heading = NSStackView(views: [disclosure, label]); heading.spacing = 4
        addArrangedSubview(heading)
        addArrangedSubview(rows)
        rows.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        rows.isHidden = disclosure.state != .on
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.heightAnchor.constraint(equalToConstant: 16).isActive = true
        addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        status.isHidden = disclosure.state != .on
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(_ values: [InfoRow], present: Bool, pending: Bool) {
        if isHidden == present { isHidden = !present }
        rows.show(values)
        let text = pending ? "Requesting information…" : values.isEmpty ? "No information in file." : ""
        if status.stringValue != text { status.stringValue = text }
    }
    @objc private func toggle() {
        rows.isHidden = disclosure.state != .on
        status.isHidden = disclosure.state != .on
        defaults.set(disclosure.state == .on, forKey: key)
    }
    @objc private func toggleLabel() { disclosure.state = disclosure.state == .on ? .off : .on; toggle() }
}

@MainActor private final class InspectorRows: NSStackView {
    var onFullText: ((String, String) -> Void)?
    private var fields: [String: (NSView, NSTextField, NSButton)] = [:]
    private var values: [String: String] = [:]
    private var shown: [InfoRow] = []
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical; alignment = .leading; spacing = 8
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(_ rows: [InfoRow]) {
        guard rows != shown else { return }
        shown = rows
        let labels = Set(rows.map(\.label))
        for (label, field) in fields {
            let hidden = !labels.contains(label)
            if field.0.isHidden != hidden { field.0.isHidden = hidden }
        }
        for row in rows {
            if fields[row.label] == nil {
                let label = NSTextField(labelWithString: row.label)
                label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 12)
                label.translatesAutoresizingMaskIntoConstraints = false
                label.widthAnchor.constraint(equalToConstant: 82).isActive = true
                let value = NSTextField(wrappingLabelWithString: "")
                value.font = .systemFont(ofSize: 12); value.isSelectable = true
                value.maximumNumberOfLines = 5
                value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let more = NSButton(title: "Show Full Text…", target: self, action: #selector(showFullText(_:)))
                more.identifier = .init(row.label); more.controlSize = .small
                let column = NSStackView(views: [value, more]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 4
                let horizontal = NSStackView(views: [label, column]); horizontal.alignment = .top; horizontal.spacing = 10
                addArrangedSubview(horizontal)
                horizontal.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
                fields[row.label] = (horizontal, value, more)
            }
            let (container, field, more) = fields[row.label]!
            if container.isHidden { container.isHidden = false }
            if values[row.label] != row.value {
                // Limit summary text layout even for a large embedded workflow or description.
                field.stringValue = String(row.value.prefix(320)) + (row.value.count > 320 ? "…" : "")
                values[row.label] = row.value
                more.isHidden = row.value.count <= 160
                field.setAccessibilityLabel(row.label)
            }
        }
    }
    @objc private func showFullText(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let value = values[key] else { return }
        onFullText?(key, value)
    }
}
