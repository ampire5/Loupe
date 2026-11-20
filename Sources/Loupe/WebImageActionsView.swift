import AppKit

@MainActor final class WebImageActionsView: NSStackView {
    private let message = NSTextField(wrappingLabelWithString: "")
    private let sourceButton: NSButton
    private let saveButton: NSButton

    init(target: AnyObject, openSource: Selector, save: Selector) {
        sourceButton = NSButton(title: "Open Source Page", target: target, action: openSource)
        saveButton = NSButton(title: "Save Original", target: target, action: save)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer?.cornerRadius = 10
        appearance = NSAppearance(named: .darkAqua)
        orientation = .vertical
        alignment = .centerX
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        message.textColor = NSColor(white: 0.95, alpha: 1)
        message.alignment = .center
        message.maximumNumberOfLines = 3
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(message)
        let actions = NSStackView(views: [sourceButton, saveButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        addArrangedSubview(actions)
    }

    required init?(coder: NSCoder) { nil }

    func show(error: String?, canOpenSource: Bool, canSave: Bool) {
        let text = error ?? ""
        if message.stringValue != text { message.stringValue = text }
        message.isHidden = error == nil
        sourceButton.isHidden = !canOpenSource
        saveButton.isHidden = error != nil
        saveButton.isEnabled = canSave
        isHidden = false
    }
}
