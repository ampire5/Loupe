import AppKit
import LoupeCore

/// A modal draft: virtualized category/weight rows and explicit priority rules, no file work in UI actions.
@MainActor final class DetectorProfileEditor: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var draft: DetectorProfileDraft
    private let categories: [SubjectKind]
    private let creating: Bool
    private let categoryTable = NSTableView()
    private let ruleTable = NSTableView()
    private let nameField = NSTextField()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let classPadding = NSTextField()
    private var selected = Set<SubjectKind>()
    private var invalidEdit = false
    private var saving = false
    var save: ((DetectorProfileDraft, @escaping (Result<Void, Error>) -> Void) -> Void)?
    var didClose: (() -> Void)?

    init(draft: DetectorProfileDraft, categories: [SubjectKind], creating: Bool, applyingToTab: Bool = false) {
        self.draft = draft; self.categories = categories; self.creating = creating
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 880, height: 740),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = .init(width: 880, height: 640)
        window.isReleasedWhenClosed = false; window.autorecalculatesKeyViewLoop = true
        window.title = applyingToTab ? "Vision framing — this tab" : creating ? "New SmartZoom profile" : "Edit SmartZoom profile"
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        let body = ProfileEditorDocument(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        body.edgeInsets = .init(top: 16, left: 16, bottom: 16, right: 16)
        body.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(); window.contentView = root
        let form = NSScrollView(); form.hasVerticalScroller = true; form.autohidesScrollers = true; form.drawsBackground = false
        form.translatesAutoresizingMaskIntoConstraints = false; form.documentView = body; root.addSubview(form)
        body.widthAnchor.constraint(equalTo: form.contentView.widthAnchor).isActive = true
        nameField.stringValue = draft.name; nameField.isEditable = creating
        nameField.placeholderString = "Profile name"; nameField.identifier = .init("profile.name")
        body.addArrangedSubview(row([label("Name"), nameField]))
        nameField.widthAnchor.constraint(equalToConstant: 570).isActive = true
        if applyingToTab { body.addArrangedSubview(label("Changes apply to this tab. Use Save SmartZoom for folder to remember them.")) }
        body.addArrangedSubview(label("Select categories to build a rule. All model categories in a group are required; Vision categories are individual fallback rules."))
        let left = column(), right = column()
        left.addArrangedSubview(label("Categories and framing")); right.addArrangedSubview(label("Priority rules — first complete group wins"))
        categoryTable.identifier = .init("profile.categories"); ruleTable.identifier = .init("profile.rules")
        for (id, title, width) in [("category", "Category", 140.0), ("weight", "Weight", 55.0),
                                   ("radius", "Radius", 65.0), ("crop", "Max cut", 75.0)] {
            let col = NSTableColumn(identifier: .init(id)); col.title = title
            col.minWidth = id == "category" ? 100 : id == "weight" ? 50 : id == "radius" ? 65 : 75
            col.width = width
            col.resizingMask = id == "crop" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            categoryTable.addTableColumn(col)
        }
        let rule = NSTableColumn(identifier: .init("rule")); rule.width = 355; ruleTable.addTableColumn(rule); ruleTable.headerView = nil
        for table in [categoryTable, ruleTable] {
            table.dataSource = self; table.delegate = self; table.rowHeight = 24; table.allowsEmptySelection = true
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        }
        left.addArrangedSubview(scroll(categoryTable)); right.addArrangedSubview(scroll(ruleTable))
        classPadding.identifier = .init("profile.protection-padding"); classPadding.delegate = self
        classPadding.widthAnchor.constraint(equalToConstant: 85).isActive = true
        classPadding.isEnabled = false; classPadding.stringValue = "Default"
        left.addArrangedSubview(row([label("Protection padding"), classPadding]))
        left.addArrangedSubview(label("Select a category to edit padding. Radius and cut are percentages. Default inherits; Off disables protection. Max cut applies to each edge."))
        let buttons = row([button("Add", #selector(addRule)), button("Replace", #selector(replaceRule)),
                           button("Remove", #selector(removeRule)), button("↑", #selector(ruleUp)), button("↓", #selector(ruleDown))])
        right.addArrangedSubview(buttons)
        let tables = row([left,right]); tables.alignment = .top; tables.distribution = .fillEqually
        body.addArrangedSubview(tables)
        tables.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
        addSlider("Target size", value: draft.size * 100, range: 20...100, step: 1, to: body) { [weak self] in self?.draft.size = $0 / 100 }
        addSlider("Maximum auto zoom", value: draft.composition.maxZoom * 100, range: 25...400, step: 25, to: body) { [weak self] in self?.draft.composition.maxZoom = $0 / 100 }
        addSlider("Margin", value: draft.composition.margin * 100, range: 0...100, step: 1, to: body) { [weak self] in self?.draft.composition.margin = $0 / 100 }
        addSlider("Circle radius", value: draft.composition.circleRadius * 100, range: 25...200, step: 1, to: body) { [weak self] in self?.draft.composition.circleRadius = $0 / 100 }
        addSlider("Protection padding", value: draft.composition.protectionMargin * 100, range: 0...50, step: 1, to: body) { [weak self] in self?.draft.composition.protectionMargin = $0 / 100 }
        let protection = NSSegmentedControl(labels: ["Protect all found", "Protect selected group"], trackingMode: .selectOne, target: self, action: #selector(protectionChanged(_:)))
        protection.selectedSegment = draft.composition.protectionScope == .all ? 0 : 1
        let steady = NSButton(checkboxWithTitle: "Keep similar photos steady", target: self, action: #selector(steadyChanged(_:)))
        steady.state = draft.composition.steadyFraming ? .on : .off
        body.addArrangedSubview(protection); body.addArrangedSubview(steady)
        let normalize = NSSegmentedControl(labels: ["Weight per type", "Weight per object"], trackingMode: .selectOne, target: self, action: #selector(normalizationChanged(_:)))
        normalize.selectedSegment = draft.composition.normalization == .class ? 0 : 1
        let overflow = NSSegmentedControl(labels: ["Zoom out if group does not fit", "Keep zoom"], trackingMode: .selectOne, target: self, action: #selector(overflowChanged(_:)))
        overflow.selectedSegment = draft.composition.panOverflow == .fit ? 0 : 1
        body.addArrangedSubview(normalize); body.addArrangedSubview(overflow)
        note.font = .systemFont(ofSize: 11); note.textColor = .systemOrange; note.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(note)
        saveButton.title = applyingToTab ? "Apply to tab" : creating ? "Create profile" : "Save profile"
        saveButton.target = self; saveButton.action = #selector(saveClicked); saveButton.keyEquivalent = "\r"
        cancelButton.target = self; cancelButton.action = #selector(cancelClicked); cancelButton.keyEquivalent = "\u{1b}"
        let footer = row([cancelButton,saveButton]); footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: root.topAnchor), form.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor), form.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -8),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            note.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        categoryTable.reloadData(); ruleTable.reloadData()
    }
    required init?(coder: NSCoder) { nil }
    private func column() -> NSStackView { let v = NSStackView(); v.orientation = .vertical; v.alignment = .leading; v.spacing = 6; return v }
    private func row(_ views: [NSView]) -> NSStackView { let v = NSStackView(views: views); v.orientation = .horizontal; v.spacing = 8; return v }
    private func label(_ text: String) -> NSTextField { let v = NSTextField(wrappingLabelWithString: text); v.font = .systemFont(ofSize: 12); return v }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func scroll(_ table: NSTableView) -> NSScrollView {
        let view = NSScrollView(); view.hasVerticalScroller = true; view.autohidesScrollers = true
        view.documentView = table; view.borderType = .bezelBorder
        view.heightAnchor.constraint(equalToConstant: 240).isActive = true
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return view
    }
    private func addSlider(_ title: String, value: Double, range: ClosedRange<Double>, step: Double, to body: NSStackView,
                           changed: @escaping (Double) -> Void) {
        let slider = SmartZoomSlider(title: title, range: range, step: step, suffix: "%", changed: changed)
        slider.set(value); body.addArrangedSubview(slider)
        slider.heightAnchor.constraint(equalToConstant: 40).isActive = true
        slider.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === categoryTable ? categories.count : draft.chain.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        if tableView === ruleTable {
            let id = NSUserInterfaceItemIdentifier("rule.label")
            let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
            field.identifier = id; field.stringValue = "\(row + 1). \(draft.chain[row].title)"
            field.lineBreakMode = .byTruncatingTail; field.toolTip = draft.chain[row].rawValue
            return field
        }
        let kind = categories[row]
        if let name = column?.identifier.rawValue, ["weight", "radius", "crop"].contains(name) {
            let id = NSUserInterfaceItemIdentifier("profile." + name)
            let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField()
            field.identifier = id; field.delegate = self; field.tag = row
            field.stringValue = name == "weight" ? String(draft.composition.weights[kind] ?? 1)
                : draft.classValue(for: kind, field: name == "radius" ? .radius : .crop)
            field.alignment = .right
            field.setAccessibilityLabel(kind.title + " " + name)
            return field
        }
        let id = NSUserInterfaceItemIdentifier("profile.category")
        let checkbox = tableView.makeView(withIdentifier: id, owner: self) as? NSButton ?? NSButton(checkboxWithTitle: "", target: self, action: #selector(categoryChanged(_:)))
        checkbox.identifier = id; checkbox.tag = row; checkbox.title = kind.title; checkbox.toolTip = kind.rawValue
        checkbox.state = selected.contains(kind) ? .on : .off
        return checkbox
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === categoryTable { refreshClassDetails(); return }
        guard notification.object as? NSTableView === ruleTable, draft.chain.indices.contains(ruleTable.selectedRow) else { return }
        selected = Set(draft.chain[ruleTable.selectedRow].parts); categoryTable.reloadData()
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              categories.indices.contains(field.tag) else { return }
        let kind = categories[field.tag]
        let name = field.identifier?.rawValue ?? ""
        if ["profile.radius", "profile.crop", "profile.protection-padding"].contains(name) {
            let type: DetectorProfileDraft.ClassField = name == "profile.radius" ? .radius : name == "profile.crop" ? .crop : .padding
            guard draft.setClassValue(field.stringValue, for: kind, field: type) else {
                invalidEdit = true; field.stringValue = draft.classValue(for: kind, field: type)
                note.stringValue = "Radius: 25–200%. Max cut: 0–49% per edge or Off. Padding: 0–50%. Use Default to inherit."
                return
            }
            field.stringValue = draft.classValue(for: kind, field: type); note.stringValue = ""; return
        }
        guard name == "profile.weight" else { return }
        guard let v = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")), v.isFinite, (0.25...4).contains(v) else {
            invalidEdit = true; field.stringValue = String(draft.composition.weights[kind] ?? 1)
            note.stringValue = "Weights must be between 0.25 and 4."; return
        }
        draft.composition.weights[kind] = v; note.stringValue = ""
    }
    @objc private func categoryChanged(_ sender: NSButton) {
        let kind = categories[sender.tag]
        if sender.state == .on { selected.insert(kind) } else { selected.remove(kind) }
        categoryTable.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
        refreshClassDetails()
    }
    private func refreshClassDetails() {
        let index = categoryTable.selectedRow
        classPadding.isEnabled = categories.indices.contains(index)
        guard categories.indices.contains(index) else { return }
        classPadding.tag = index
        classPadding.stringValue = draft.classValue(for: categories[index], field: .padding)
        classPadding.setAccessibilityLabel(categories[index].title + " protection padding")
    }
    private func selectedRule() -> SubjectKind? {
        let parts = categories.filter(selected.contains)
        guard !parts.isEmpty, let group = SubjectKind(rawValue: parts.map(\.rawValue).joined(separator: "+")) else {
            note.stringValue = "Select model categories for a group, or one Vision category as a fallback."; return nil
        }
        return group
    }
    private func setRule(replacing: Bool) {
        guard let rule = selectedRule() else { return }
        let index = ruleTable.selectedRow
        if replacing && !draft.chain.indices.contains(index) { note.stringValue = "Select a rule to replace."; return }
        let canonical = Set(rule.parts)
        guard !draft.chain.enumerated().contains(where: { (!replacing || $0.offset != index) && Set($0.element.parts) == canonical }) else {
            note.stringValue = "This group already exists. Use ↑ / ↓ to change its priority."; return
        }
        if replacing { draft.chain[index] = rule } else { draft.chain.append(rule) }
        note.stringValue = ""; ruleTable.reloadData()
    }
    @objc private func addRule() { setRule(replacing: false) }
    @objc private func replaceRule() { setRule(replacing: true) }
    @objc private func removeRule() {
        let i = ruleTable.selectedRow; guard draft.chain.indices.contains(i) else { return }
        draft.chain.remove(at: i); ruleTable.reloadData(); selected = []; categoryTable.reloadData()
    }
    private func move(_ delta: Int) {
        let i = ruleTable.selectedRow, j = i + delta
        guard draft.chain.indices.contains(i), draft.chain.indices.contains(j) else { return }
        draft.chain.swapAt(i,j); ruleTable.reloadData(); ruleTable.selectRowIndexes(IndexSet(integer: j), byExtendingSelection: false)
    }
    @objc private func ruleUp() { move(-1) }
    @objc private func ruleDown() { move(1) }
    @objc private func normalizationChanged(_ sender: NSSegmentedControl) { draft.composition.normalization = sender.selectedSegment == 0 ? .class : .object }
    @objc private func overflowChanged(_ sender: NSSegmentedControl) { draft.composition.panOverflow = sender.selectedSegment == 0 ? .fit : .keep }
    @objc private func protectionChanged(_ sender: NSSegmentedControl) { draft.composition.protectionScope = sender.selectedSegment == 0 ? .all : .selected }
    @objc private func steadyChanged(_ sender: NSButton) { draft.composition.steadyFraming = sender.state == .on }
    @objc private func cancelClicked() { if !saving { finish() } }
    private func finish() {
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        didClose?()
    }
    @objc private func saveClicked() {
        invalidEdit = false; window?.makeFirstResponder(nil)
        guard !invalidEdit, !saving else { return }
        draft.name = nameField.stringValue
        saving = true; saveButton.isEnabled = false; cancelButton.isEnabled = false; note.stringValue = "Saving…"
        save?(draft) { [weak self] result in
            guard let self else { return }
            saving = false; saveButton.isEnabled = true; cancelButton.isEnabled = true
            switch result { case .success: finish(); case .failure(let error): note.stringValue = error.localizedDescription }
        }
    }
}

@MainActor private final class ProfileEditorDocument: NSStackView {
    override var isFlipped: Bool { true }
}
