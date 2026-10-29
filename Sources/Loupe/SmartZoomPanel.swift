import AppKit
import LoupeCore

/// A retained Slot page. No observation, timers or detection work while hidden.
@MainActor final class SmartZoomPanel: NSObject, NSMenuDelegate {
    struct Snapshot {
        var mode: SmartZoomMode
        var profile: String
        var profiles: [String]
        var groups: [SubjectKind]
        var selected: SubjectKind?
        var kinds: [SubjectKind]
        var options: CompositionOptions
        var size: Double
        var note: String
        var showsBoxes: Bool
        var modelPath = ""
        var models: [DetectorModelEntry] = []
        var modelLoading = false
        var modelNote = ""
        var canEditProfile = false
    }
    let view = NSScrollView()
    private let body = SmartZoomDocumentView()
    private let mode = NSSegmentedControl(labels: ["Manual", "Pan only", "Auto framing"], trackingMode: .selectOne, target: nil, action: nil)
    private let overflow = NSSegmentedControl(labels: ["Zoom out to fit group", "Keep zoom"], trackingMode: .selectOne, target: nil, action: nil)
    private let profile = SmartZoomPopUp()
    private let model = SmartZoomPopUp()
    private let browseModel = NSButton(title: "Choose model…", target: nil, action: nil)
    private let editProfileButton = NSButton(title: "Edit profile…", target: nil, action: nil)
    private let modelNote = NSTextField(wrappingLabelWithString: "")
    private let groups = SmartZoomGroupsView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let weights = NSStackView()
    private let normalize = NSSegmentedControl(labels: ["Per type", "Per object"], trackingMode: .selectOne, target: nil, action: nil)
    private let showBoxes = NSButton(checkboxWithTitle: "Show detections and frame", target: nil, action: nil)
    private var controls: [String: SmartZoomSlider] = [:]
    private var weightRows: [SubjectKind: SmartZoomSlider] = [:]
    private var groupButtons: [SubjectKind: SmartZoomButton] = [:]
    private var snapshot: Snapshot?
    private var visible = false
    private var menuTracking = false
    private var editingProfile = false
    var isInteracting: Bool { menuTracking || editingProfile }
    var interactionChanged: (() -> Void)?
    private var weightsExpanded = false
    var source: (() -> Snapshot)?
    var chooseMode: ((SmartZoomMode) -> Void)?
    var chooseProfile: ((String) -> Void)?
    var newProfile: (() -> Void)?
    var editProfile: (() -> Void)?
    var modelsRequested: (() -> Void)?
    var chooseModel: ((String?) -> Void)?
    var chooseGroup: ((SubjectKind?) -> Void)?
    var edit: ((String, String) -> Void)?
    var toggleBoxes: (() -> Void)?
    var saveFolder: (() -> Void)?
    var saveProfile: (() -> Void)?

    override init() {
        super.init()
        view.drawsBackground = false; view.hasVerticalScroller = true
        view.appearance = NSAppearance(named: .darkAqua)
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
        body.edgeInsets = NSEdgeInsets(top: 52, left: 14, bottom: 16, right: 14)
        body.translatesAutoresizingMaskIntoConstraints = false
        view.documentView = body
        NSLayoutConstraint.activate([body.widthAnchor.constraint(equalTo: view.contentView.widthAnchor)])
        let title = label("SmartZoom", size: 16); title.font = .systemFont(ofSize: 16, weight: .semibold)
        body.addArrangedSubview(title)
        body.addArrangedSubview(label("Detection model", size: 11))
        let modelRow = NSStackView(views: [model, browseModel]); modelRow.spacing = 8
        body.addArrangedSubview(modelRow)
        modelRow.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -28).isActive = true
        browseModel.target = self; browseModel.action = #selector(browseModelClicked)
        model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        model.target = self; model.action = #selector(modelChanged)
        model.identifier = NSUserInterfaceItemIdentifier("smartzoom.model")
        model.menu?.delegate = self
        modelNote.font = .systemFont(ofSize: 11); modelNote.textColor = .secondaryLabelColor
        body.addArrangedSubview(modelNote)
        body.addArrangedSubview(label("Composition profile", size: 11))
        body.addArrangedSubview(profile); profile.target = self; profile.action = #selector(profileChanged)
        profile.menu?.delegate = self
        let newButton = NSButton(title: "New profile…", target: self, action: #selector(newProfileClicked))
        editProfileButton.target = self; editProfileButton.action = #selector(editProfileClicked)
        let profileActions = NSStackView(views: [newButton, editProfileButton])
        body.addArrangedSubview(profileActions)
        profileActions.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -28).isActive = true
        mode.identifier = NSUserInterfaceItemIdentifier("smartzoom.mode")
        body.addArrangedSubview(mode); mode.target = self; mode.action = #selector(modeChanged)
        mode.toolTip = "⌥S Manual/SmartZoom · ⇧Z apply Auto · N next group · M next profile"
        body.addArrangedSubview(overflow); overflow.target = self; overflow.action = #selector(overflowChanged)
        body.addArrangedSubview(groups)
        groups.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -28).isActive = true
        addSlider("max-zoom", title: "Maximum auto zoom", range: 25...400, step: 25)
        addSlider("size", title: "Target size", range: 20...100, step: 1)
        addSlider("margin", title: "Margin", range: 0...100, step: 1)
        let explanation = label("Pan only never zooms in. If the group does not fit, choose zoom out or keep zoom. Auto framing never goes below Fit.", size: 11)
        body.addArrangedSubview(explanation)
        let disclosure = SmartZoomButton("Type weights ▸") { [weak self] button in
            guard let self else { return }; weightsExpanded.toggle(); weights.isHidden = !weightsExpanded
            button.title = weightsExpanded ? "Type weights ▾" : "Type weights ▸"
            refreshWeights()
        }
        body.addArrangedSubview(disclosure)
        weights.orientation = .vertical; weights.alignment = .leading; weights.spacing = 8; weights.isHidden = true
        body.addArrangedSubview(weights)
        weights.addArrangedSubview(normalize); normalize.target = self; normalize.action = #selector(normalizeChanged)
        weights.addArrangedSubview(SmartZoomButton("Equal weights") { [weak self] _ in self?.edit?("weights", "") })
        body.addArrangedSubview(showBoxes); showBoxes.target = self; showBoxes.action = #selector(boxesChanged)
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        body.addArrangedSubview(note)
        let save = NSStackView(views: [
            SmartZoomButton("Save SmartZoom for folder") { [weak self] _ in self?.saveFolder?() },
            SmartZoomButton("Save to profile") { [weak self] _ in self?.saveProfile?() }])
        save.orientation = .vertical; save.alignment = .leading; save.spacing = 6
        body.addArrangedSubview(save)
        for item in [mode, model, modelNote, profile, groups, explanation, weights, note] as [NSView] {
            item.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -28).isActive = true
        }
    }
    private func label(_ text: String, size: Double) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text)
        result.textColor = .labelColor; result.font = .systemFont(ofSize: size)
        return result
    }
    private func addSlider(_ key: String, title: String, range: ClosedRange<Double>, step: Double) {
        let row = SmartZoomSlider(title: title, range: range, step: step, suffix: "%") { [weak self] value in
            self?.edit?(key, "\(value)%")
        }
        controls[key] = row; body.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -28).isActive = true
    }
    func setProfileEditing(_ editing: Bool) { editingProfile = editing; interactionChanged?() }
    func setVisible(_ shown: Bool) { visible = shown; if shown { refresh(); modelsRequested?() } }
    func refresh() {
        guard visible, let next = source?() else { return }
        snapshot = next
        mode.selectedSegment = SmartZoomMode.allCases.firstIndex(of: next.mode) ?? 0
        if profile.titleOfSelectedItem != next.profile {
            profile.removeAllItems(); profile.addItem(withTitle: next.profile)
        }
        let modelTitle = next.modelPath.isEmpty ? "Choose a model…"
            : (next.models.first { $0.path == next.modelPath }?.title
                ?? URL(fileURLWithPath: next.modelPath).deletingPathExtension().lastPathComponent)
        if model.titleOfSelectedItem != modelTitle { model.removeAllItems(); model.addItem(withTitle: modelTitle.isEmpty ? "Choose a model…" : modelTitle) }
        model.isEnabled = !next.modelLoading
        browseModel.isEnabled = !next.modelLoading
        editProfileButton.isEnabled = next.canEditProfile
        modelNote.stringValue = next.modelNote
        modelNote.isHidden = next.modelNote.isEmpty
        let wanted = next.groups
        if groups.buttons.count != wanted.count + 1 || groups.order != wanted {
            groupButtons = [:]
            var buttons: [NSButton] = [SmartZoomButton("First available group") { [weak self] _ in self?.chooseGroup?(nil) }]
            for kind in wanted {
                let button = SmartZoomButton(kind.title) { [weak self] _ in self?.chooseGroup?(kind) }
                button.setButtonType(.toggle); button.toolTip = kind.title
                groupButtons[kind] = button; buttons.append(button)
            }
            groups.set(buttons, order: wanted)
        }
        for (kind, button) in groupButtons { button.state = kind == next.selected ? .on : .off }
        controls["max-zoom"]?.set(next.options.maxZoom * 100)
        controls["size"]?.set(next.size * 100)
        controls["margin"]?.set(next.options.margin * 100)
        overflow.selectedSegment = next.options.panOverflow == .fit ? 0 : 1
        normalize.selectedSegment = next.options.normalization == .class ? 0 : 1
        showBoxes.state = next.showsBoxes ? .on : .off
        note.stringValue = next.note
        refreshWeights()
    }
    @objc private func overflowChanged() { edit?("pan-overflow", overflow.selectedSegment == 0 ? "fit" : "keep") }

    private func refreshWeights() {
        guard visible, weightsExpanded, let snapshot else { return }
        let kinds = snapshot.kinds
        for kind in Array(weightRows.keys) where !kinds.contains(kind) {
            if let row = weightRows.removeValue(forKey: kind) { weights.removeArrangedSubview(row); row.removeFromSuperview() }
        }
        for kind in kinds {
            if weightRows[kind] == nil {
                let row = SmartZoomSlider(title: kind.title, range: 0.25...4, step: 0.25, suffix: "") { [weak self] value in
                    guard let self, var values = self.snapshot?.options.weights else { return }
                    values[kind] = value
                    let encoded = values.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue):\($0.value)" }.joined(separator: ",")
                    edit?("weights", encoded)
                }
                weightRows[kind] = row; weights.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -28).isActive = true
            }
            weightRows[kind]?.set(snapshot.options.weights[kind] ?? 1)
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === profile.menu || menu === model.menu else { return }
        menuTracking = true
        view.window?.makeFirstResponder(menu === model.menu ? model : profile)
        interactionChanged?()
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === profile.menu || menu === model.menu else { return }
        menuTracking = false; interactionChanged?()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let snapshot else { return }
        if menu === model.menu {
            model.removeAllItems()
            for entry in snapshot.models {
                model.addItem(withTitle: entry.title); model.lastItem?.representedObject = entry.path
            }
            model.addItem(withTitle: "Choose compiled model…")
            if let i = snapshot.models.firstIndex(where: { $0.path == snapshot.modelPath }) { model.selectItem(at: i) }
            return
        }
        guard menu === profile.menu else { return }
        profile.removeAllItems(); profile.addItems(withTitles: snapshot.profiles)
        profile.selectItem(withTitle: snapshot.profile)
    }
    @objc private func modeChanged() { chooseMode?(SmartZoomMode.allCases[mode.selectedSegment]) }
    @objc private func browseModelClicked() { chooseModel?(nil) }
    @objc private func newProfileClicked() { newProfile?() }
    @objc private func editProfileClicked() { editProfile?() }
    @objc private func modelChanged() { chooseModel?(model.selectedItem?.representedObject as? String) }
    @objc private func profileChanged() { if let value = profile.titleOfSelectedItem { chooseProfile?(value) } }
    @objc private func normalizeChanged() { edit?("weight-normalization", normalize.selectedSegment == 0 ? "class" : "object") }
    @objc private func boxesChanged() { toggleBoxes?() }
}

@MainActor final class SmartZoomButton: NSButton {
    private let clicked: (SmartZoomButton) -> Void
    init(_ title: String, clicked: @escaping (SmartZoomButton) -> Void) {
        self.clicked = clicked
        super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; target = self; action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func invoke() { clicked(self) }
}

@MainActor final class SmartZoomSlider: NSStackView {
    private let slider: NSSlider
    private let caption = NSTextField(labelWithString: "")
    private let title: String
    private let step: Double
    private let suffix: String
    private let changed: (Double) -> Void
    init(title: String, range: ClosedRange<Double>, step: Double, suffix: String, changed: @escaping (Double) -> Void) {
        self.title = title; self.step = step; self.suffix = suffix; self.changed = changed
        slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 3
        caption.font = .systemFont(ofSize: 11); caption.textColor = .labelColor
        addArrangedSubview(caption); addArrangedSubview(slider)
        slider.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        slider.target = self; slider.action = #selector(editValue); slider.isContinuous = true
        slider.setAccessibilityLabel(title)
        set(range.lowerBound)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func set(_ value: Double) { slider.doubleValue = value; caption.stringValue = "\(title): \(String(format: "%g", value))\(suffix)" }
    @objc private func editValue() {
        let value = (slider.doubleValue / step).rounded() * step
        set(value); changed(value)
    }
}

@MainActor private final class SmartZoomDocumentView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Wrapping group chips retain their buttons across ordinary parameter changes.
@MainActor private final class SmartZoomGroupsView: NSView {
    var buttons: [NSButton] = []
    var order: [SubjectKind] = []
    private var height = 30.0
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
    func set(_ buttons: [NSButton], order: [SubjectKind]) {
        for old in self.buttons { old.removeFromSuperview() }
        self.buttons = buttons; self.order = order
        for button in buttons { addSubview(button) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        var x = 0.0, y = 0.0
        let available = max(bounds.width, 120)
        for button in buttons {
            let width = min(max(button.fittingSize.width, 40), available)
            if x > 0 && x + width > available { x = 0; y += 30 }
            button.frame = NSRect(x: x, y: y, width: width, height: 26)
            x += width + 6
        }
        let next = y + 28
        if height != next { height = next; invalidateIntrinsicContentSize() }
    }
}

@MainActor private final class SmartZoomPopUp: NSPopUpButton {
    override var acceptsFirstResponder: Bool { true }
}
