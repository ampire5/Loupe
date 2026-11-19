import AppKit
import ImageIO
import LoupeCore

@MainActor final class FramingLearningWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let coordinator: FramingLearningCoordinator
    var capture: ((Bool) -> Void)?
    var nextPhoto: (() -> Void)?
    var didClose: (() -> Void)?
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextView()
    private let previews = [FramingCropPreview(), FramingCropPreview(), FramingCropPreview()]
    private var buttons: [String: NSButton] = [:]
    private var votes: [NSButton] = []
    private var previewTask: Task<Void, Never>?
    private let previewLoader = FramingPreviewLoader()
    private var previewKey = ""
    private var hasPreview = false
    var previewReady: Bool { hasPreview }
    private var selected: FramingReference? {
        coordinator.references.indices.contains(table.selectedRow) ? coordinator.references[table.selectedRow] : nil
    }
    init(coordinator: FramingLearningCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1060, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Learn framing — \(coordinator.profile.name) · \(coordinator.intent.title)"
        window.minSize = .init(width: 900, height: 720); window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true; window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window); window.delegate = self
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = .init(top: 16, left: 16, bottom: 16, right: 16); root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor), root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor)])
        func addRow(_ views: [NSView]) {
            let row = NSStackView(views: views); row.spacing = 8; root.addArrangedSubview(row)
        }
        addRow([button("save", "Remember crop", #selector(save)), button("save-next", "Remember and next", #selector(saveNext)),
                button("next", "Skip photo", #selector(next)), button("remove", "Remove reference", #selector(remove))])
        root.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "Adjust the photo in its viewer, then remember it. Keep related photos in one series. Reserve entire series for validation."))
        table.identifier = .init("learning.references"); table.dataSource = self; table.delegate = self; table.rowHeight = 26
        for (id, title, width) in [("file", "Photo", 270.0), ("series", "Series (edit to regroup)", 330.0), ("validation", "Validation", 85.0), ("error", "Candidate / best proposal", 175.0)] {
            let col = NSTableColumn(identifier: .init(id)); col.title = title; col.width = width; table.addTableColumn(col)
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder; root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        addRow([button("fit", "Fit preferences", #selector(fit)), button("cancel", "Cancel fit", #selector(cancelFit)),
                button("reload", "Reload references", #selector(reload)), button("compare-next", "Next comparison", #selector(nextComparison))])
        status.font = .systemFont(ofSize: 12); root.addArrangedSubview(status)
        let previewRow = NSStackView(); previewRow.spacing = 8; previewRow.distribution = .fillEqually
        for (i, title) in ["Your reference", "First", "Second"].enumerated() {
            previews[i].identifier = .init("learning.preview.\(i)"); previews[i].clipsToBounds = true
            let column = NSStackView(views: [NSTextField(labelWithString: title), previews[i]])
            column.orientation = .vertical; column.alignment = .leading; previewRow.addArrangedSubview(column)
            previews[i].widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            previews[i].heightAnchor.constraint(equalToConstant: 175).isActive = true
        }
        root.addArrangedSubview(previewRow); previewRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        let voteRow = NSStackView(); voteRow.spacing = 8
        for (i, title) in ["First is better", "Second is better", "Equal", "Both poor"].enumerated() {
            let vote = NSButton(title: title, target: self, action: #selector(vote(_:))); vote.tag = i
            voteRow.addArrangedSubview(vote); votes.append(vote)
        }
        root.addArrangedSubview(voteRow)
        details.isEditable = false; details.isSelectable = true; details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let report = NSScrollView(); report.documentView = details; report.hasVerticalScroller = true
        root.addArrangedSubview(report); report.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        report.heightAnchor.constraint(greaterThanOrEqualToConstant: 75).isActive = true
        addRow([button("apply", "Apply to this tab", #selector(applyTab)), button("persist", "Save to profile", #selector(persist)),
                button("undo", "Undo application", #selector(undo))])
        coordinator.changed = { [weak self] in self?.refresh() }
        window.center(); refresh()
    }
    required init?(coder: NSCoder) { nil }
    private func button(_ id: String, _ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.identifier = .init("learning." + id)
        buttons[id] = b; return b
    }
    static func candidateFirst(index: Int, run: UUID) -> Bool {
        // Alternating assignment is balanced; the run seed changes the starting side without revealing labels.
        (index + Int(run.uuid.0)) % 2 == 0
    }
    func windowWillClose(_ notification: Notification) {
        previewTask?.cancel(); previewLoader.cancelPending(); coordinator.cancel(); coordinator.changed = nil; didClose?()
    }
    private func refresh() {
        let oldID = selected?.id
        table.reloadData()
        if let oldID, let i = coordinator.references.firstIndex(where: { $0.id == oldID }) { table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }
        else if table.selectedRow < 0, !coordinator.references.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        status.stringValue = coordinator.message
        if let result = coordinator.result {
            status.stringValue += String(format: "  ·  training %.3f → %.3f", result.baselineTrainingLoss, result.trainingLoss)
            if let loss = result.validationLoss { status.stringValue += String(format: "  ·  validation %.3f", loss) }
        }
        buttons["fit"]?.isEnabled = !coordinator.running && coordinator.references.contains { !$0.validation }
        buttons["cancel"]?.isEnabled = coordinator.isFitting
        for id in ["remove", "reload", "save", "save-next"] { buttons[id]?.isEnabled = !coordinator.running }
        buttons["apply"]?.isEnabled = coordinator.canApply; buttons["persist"]?.isEnabled = coordinator.canApply
        buttons["undo"]?.isEnabled = coordinator.canUndo
        updateSelection()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { coordinator.references.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let reference = coordinator.references[row]
        switch tableColumn?.identifier.rawValue {
        case "validation":
            let b = NSButton(checkboxWithTitle: "Reserve", target: self, action: #selector(validation(_:)))
            b.tag = row; b.state = reference.validation ? .on : .off; b.isEnabled = !coordinator.running; return b
        case "series":
            let field = NSTextField(string: reference.group); field.tag = row; field.target = self; field.action = #selector(series(_:))
            field.isEnabled = !coordinator.running; return field
        case "error":
            let result = coordinator.result?.samples.first { $0.id == reference.id }
            return NSTextField(labelWithString: result.map { String(format: "%.3f / %.3f", $0.candidate.loss, $0.bestProposalLoss) } ?? "—")
        default: return NSTextField(labelWithString: reference.source.lastPathComponent)
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private func updateSelection() {
        guard let selected else { details.string = "Save a reference crop to begin."; return }
        let sample = coordinator.result?.samples.first { $0.id == selected.id }
        if let sample {
            details.string = String(format: "Viewport: X %+.1f%% · Y %+.1f%% · scale %+.1f%% · overlap %.1f%%\n",
                sample.candidate.dx * 100, sample.candidate.dy * 100, (exp(sample.candidate.logScale) - 1) * 100, sample.candidate.overlap * 100)
                + String(format: "Group: X %+.1f%% · Y %+.1f%%\n", sample.candidate.groupDX * 100, sample.candidate.groupDY * 100)
                + sample.candidate.elements.sorted { $0.loss > $1.loss }.map(\.summary).joined(separator: "\n")
        } else { details.string = "\(selected.instances.count) detected elements · \(selected.behavior.rawValue) · \(selected.intent.title)\nFit preferences to see per-object errors." }
        let key = selected.id.uuidString + (coordinator.result?.id.uuidString ?? "baseline")
        guard key != previewKey else { updateVoting(); return }
        previewKey = key; previewTask?.cancel(); hasPreview = false; updateVoting()
        for preview in previews { preview.image = nil }
        let baseline = FramingReplay.transform(reference: selected, profile: coordinator.profile)
        let candidate = sample?.candidateView.transform ?? baseline
        let first = Self.candidateFirst(index: table.selectedRow, run: coordinator.result?.id ?? selected.id)
        let views = [selected.target.transform, first ? candidate : baseline, first ? baseline : candidate]
        for i in previews.indices { previews[i].geometry = try? FramingGeometry(views[i]) }
        previewTask = Task { [weak self] in
            guard let loader = self?.previewLoader else { return }
            let image = await loader.image(source: selected.source, applied: selected.boxes.applied, revision: selected.sourceRevision)
            guard let self, !Task.isCancelled, previewKey == key else { return }
            hasPreview = image != nil
            for preview in previews { preview.image = image }
            if image == nil { details.string += "\nImage unavailable or changed; numeric reference retained." }
            updateVoting()
        }
    }
    private func updateVoting() {
        for vote in votes { vote.isEnabled = hasPreview && selected?.validation == true && coordinator.result != nil && !coordinator.running }
    }
    @objc private func save() { capture?(false) }
    @objc private func saveNext() { capture?(true) }
    @objc private func next() { nextPhoto?() }
    @objc private func remove() { if let selected { coordinator.remove(selected.id) } }
    @objc private func fit() { coordinator.fit() }
    @objc private func cancelFit() { coordinator.cancel() }
    @objc private func reload() { coordinator.load() }
    @objc private func applyTab() { coordinator.apply(persist: false) }
    @objc private func persist() { coordinator.apply(persist: true) }
    @objc private func undo() { coordinator.undo() }
    @objc private func validation(_ sender: NSButton) {
        guard coordinator.references.indices.contains(sender.tag) else { return }
        let r = coordinator.references[sender.tag]; coordinator.group(r.id, name: r.group, validation: sender.state == .on)
    }
    @objc private func series(_ sender: NSTextField) {
        guard coordinator.references.indices.contains(sender.tag), !sender.stringValue.isEmpty else { return }
        let r = coordinator.references[sender.tag]; coordinator.group(r.id, name: sender.stringValue, validation: r.validation)
    }
    @objc private func nextComparison() {
        let rows = coordinator.references.enumerated().filter { $0.element.validation }.map(\.offset)
        if let next = rows.first(where: { $0 > table.selectedRow }) ?? rows.first { table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false) }
    }
    @objc private func vote(_ sender: NSButton) {
        guard let selected, let result = coordinator.result else { return }
        let choices: [FramingComparisonVote.Choice] = [.first, .second, .equal, .bothPoor]
        coordinator.vote(reference: selected.id, choice: choices[sender.tag],
                         candidateFirst: Self.candidateFirst(index: table.selectedRow, run: result.id))
    }
}

@MainActor private final class FramingCropPreview: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var geometry: FramingGeometry? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(rect: bounds).addClip()
        NSColor.black.setFill(); bounds.fill()
        guard let image, let geometry else { return }
        let t = geometry.transform
        let factor = min(bounds.width / t.viewSize.width, bounds.height / t.viewSize.height)
        let origin = t.viewPoint(forImage: .zero)
        let rect = NSRect(x: (bounds.width - t.viewSize.width * factor) / 2 + origin.x * factor,
            y: (bounds.height - t.viewSize.height * factor) / 2 + origin.y * factor,
            width: t.imageSize.width * t.scale * factor, height: t.imageSize.height * t.scale * factor)
        NSImage(cgImage: image, size: .zero).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}
