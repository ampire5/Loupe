import AppKit
import LoupeRender

@MainActor final class UpscaleSlotPanel: NSView, NSMenuDelegate {
    private let upscale: ViewerUpscale
    private let scale = NSPopUpButton()
    private let model = NSPopUpButton()
    private let compute = NSPopUpButton()
    private let margin = NSTextField()
    private let lookahead = NSPopUpButton()
    private let showOriginal = NSButton(checkboxWithTitle: "Show original", target: nil, action: nil)
    private let autoSave = NSButton(checkboxWithTitle: "Save copies automatically", target: nil, action: nil)
    private let replace = NSButton(title: "Replace Original…", target: nil, action: nil)
    private let directory = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var visible = false
    private var holds = 0
    var interactionChanged: (() -> Void)?
    var isInteracting: Bool { holds > 0 || margin.currentEditor() != nil }

    init(upscale: ViewerUpscale) {
        self.upscale = upscale
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        directory.textColor = NSColor(srgbRed: 0.604, green: 0.604, blue: 0.635, alpha: 1)
        directory.lineBreakMode = .byTruncatingMiddle
        hint.textColor = directory.textColor
        for popup in [scale, model, compute, lookahead] {
            popup.menu?.delegate = self
            popup.target = self
            popup.controlSize = .small
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        scale.setAccessibilityLabel("Upscale factor")
        scale.toolTip = "Model output size relative to the source photo."
        scale.setAccessibilityHelp(scale.toolTip)
        scale.action = #selector(chooseScale)
        for factor in ViewerUpscale.Scale.allCases {
            scale.addItem(withTitle: factor.title)
            scale.lastItem?.tag = factor.rawValue
        }
        model.setAccessibilityLabel("Upscale model")
        model.action = #selector(chooseModel)
        compute.setAccessibilityLabel("Core ML compute units")
        compute.toolTip = "Hardware Core ML can use for this model. Automatic allows CPU, GPU, and Neural Engine."
        compute.setAccessibilityHelp(compute.toolTip)
        compute.action = #selector(saveParameters)
        compute.addItems(withTitles: ["CPU and GPU", "CPU and Neural Engine", "Automatic"])
        margin.target = self
        margin.action = #selector(saveParameters)
        margin.controlSize = .small
        margin.setAccessibilityLabel("Tile context in pixels")
        margin.toolTip = "Extra input pixels along each internal tile edge. More context can reduce seams and increase the number of tiles."
        margin.setAccessibilityHelp(margin.toolTip)
        margin.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 1023
        margin.formatter = formatter

        lookahead.setAccessibilityLabel("Photos to upscale ahead")
        lookahead.toolTip = "Prepare the next photos in the direction you are browsing."
        lookahead.action = #selector(chooseLookahead)
        for count in UpscaleLookahead.depths {
            lookahead.addItem(withTitle: count == 0 ? "Off" : String(count))
            lookahead.lastItem?.tag = count
        }
        showOriginal.target = self
        showOriginal.action = #selector(toggleOriginal)
        autoSave.target = self
        autoSave.action = #selector(toggleAutoSave)
        autoSave.toolTip = "Keep enhanced AVIF copies in a hidden folder beside the originals or their ZIP archive."
        replace.target = self
        replace.action = #selector(replaceOriginal)
        replace.controlSize = .small

        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadCatalog))
        let buttons = NSStackView(views: [choose, reload])
        buttons.spacing = 6
        let settings = NSGridView(views: [
            [label("Scale"), scale],
            [label("Model"), model],
            [label("Compute"), compute],
            [label("Tile context"), NSStackView(views: [margin, label("px")])],
            [label("Look ahead"), lookahead]
        ])
        settings.columnSpacing = 8
        settings.rowSpacing = 6
        settings.rowAlignment = .firstBaseline
        let content = NSStackView(views: [buttons, directory, showOriginal, settings, autoSave, replace, hint])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            directory.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24),
            hint.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24),
            settings.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24)
        ])
        upscale.onCatalogChange = { [weak self] in self?.refresh() }
        upscale.onStoredChange = { [weak self] in self?.refreshReplacement() }
        upscale.onComparisonChange = { [weak self] in self?.refreshComparison() }
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if visible { reloadCatalog() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        holds += 1
        interactionChanged?()
    }

    func menuDidClose(_ menu: NSMenu) {
        holds = max(0, holds - 1)
        interactionChanged?()
    }

    private func label(_ title: String) -> NSTextField {
        let text = NSTextField(labelWithString: title)
        text.textColor = NSColor(srgbRed: 0.949, green: 0.949, blue: 0.969, alpha: 1)
        return text
    }

    private func refresh() {
        let path = upscale.directory.path
        directory.stringValue = (path as NSString).abbreviatingWithTildeInPath
        directory.toolTip = path
        scale.selectItem(withTag: upscale.scale.rawValue)
        lookahead.selectItem(withTag: upscale.lookaheadDepth)
        autoSave.state = upscale.autoSave ? .on : .off
        refreshComparison()
        refreshReplacement()
        let available = upscale.models
        model.removeAllItems()
        for (index, entry) in available.enumerated() {
            // NSMenu permits display names to coincide. Use a tag so the picker keeps their paths distinct.
            let item = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
            item.tag = index
            item.toolTip = entry.url.path
            model.menu?.addItem(item)
        }
        if let selected = upscale.selected, let index = available.firstIndex(of: selected) {
            model.selectItem(at: index)
            compute.selectItem(at: NeuralUpscaleModel.Compute.allCases.firstIndex(of: selected.compute) ?? 0)
            margin.integerValue = selected.margin
        } else {
            model.addItem(withTitle: "No \(upscale.scale.title) models")
            margin.stringValue = ""
        }
        let enabled = upscale.selected != nil
        model.isEnabled = enabled
        compute.isEnabled = enabled
        margin.isEnabled = enabled
        hint.stringValue = upscale.scanning ? "Looking for models…" : enabled ? ""
            : "Put a compatible \(upscale.scale.title) Core ML model in this folder, then click Reload."
    }

    private func refreshReplacement() {
        replace.isEnabled = upscale.storedCopy?.replacementType != nil
    }

    @objc private func reloadCatalog() {
        upscale.reload()
        refresh()
    }

    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = upscale.directory
        holds += 1
        interactionChanged?()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            holds = max(0, holds - 1)
            interactionChanged?()
            if response == .OK, let folder = panel.url {
                upscale.setDirectory(folder)
                refresh()
            }
        }
    }

    @objc private func chooseModel() {
        let available = upscale.models
        guard let index = model.selectedItem?.tag, available.indices.contains(index) else { return }
        upscale.select(available[index].url)
    }

    @objc private func chooseScale() {
        guard let tag = scale.selectedItem?.tag, let factor = ViewerUpscale.Scale(rawValue: tag) else { return }
        upscale.setScale(factor)
    }

    @objc private func chooseLookahead() {
        if let count = lookahead.selectedItem?.tag { upscale.setLookaheadDepth(count) }
    }

    private func refreshComparison() { showOriginal.state = upscale.showsOriginal ? .on : .off }

    @objc private func toggleOriginal() { upscale.setShowsOriginal(showOriginal.state == .on) }

    @objc private func toggleAutoSave() { upscale.setAutoSave(autoSave.state == .on) }

    @objc private func replaceOriginal() {
        guard let copy = upscale.storedCopy, let window else { return }
        UpscaleReplacement.shared.confirm([copy], in: window)
    }

    @objc private func saveParameters() {
        let index = compute.indexOfSelectedItem
        guard NeuralUpscaleModel.Compute.allCases.indices.contains(index) else { return }
        upscale.setParameters(margin: margin.integerValue, compute: NeuralUpscaleModel.Compute.allCases[index])
    }
}
