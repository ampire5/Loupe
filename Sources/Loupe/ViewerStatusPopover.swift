import AppKit
import LoupeCore

/// Each numeric page is built on first use and retained by the status view.
@MainActor final class ViewerStatusPopover: NSViewController {
    enum Kind: Hashable { case zoom, position }
    let kind: Kind
    var onAction: ((ViewerStatusAction) -> Void)?
    private let heading = NSTextField(labelWithString: "")
    private let input = NSTextField(string: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let keep = NSButton(checkboxWithTitle: "Keep zoom and position", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private var count: Int?
    private static let presets: [(String, KeyAction)] = [
        ("Fit", .fit), ("100%", .actual100), ("200%", .actual200), ("400%", .actual400),
        ("Fit Width", .fitWidth), ("Fit Height", .fitHeight), ("Fill", .fill),
    ]

    init(kind: Kind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let size = NSSize(width: 290, height: kind == .zoom ? 194 : 106)
        view = NSView(frame: NSRect(origin: .zero, size: size))
        view.appearance = NSAppearance(named: .darkAqua)
        preferredContentSize = size
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        input.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        // Numeric entry does not use system prose-editing tools.
        input.allowsWritingTools = false
        input.target = self; input.action = #selector(applyClicked)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyButton.target = self; applyButton.action = #selector(applyClicked)
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded
        keep.target = self; keep.action = #selector(keepClicked)
        keep.font = .systemFont(ofSize: 11)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 1
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(heading)
        if kind == .zoom {
            for range in [0..<4, 4..<7] {
                let row = NSStackView()
                row.orientation = .horizontal; row.spacing = 5; row.distribution = .fillEqually
                for i in range {
                    let button = NSButton(title: Self.presets[i].0, target: self, action: #selector(presetClicked(_:)))
                    button.tag = i; button.bezelStyle = .rounded; button.controlSize = .small
                    row.addArrangedSubview(button)
                }
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }
        let entry = NSStackView(views: [input, applyButton])
        entry.orientation = .horizontal; entry.spacing = 8; entry.alignment = .centerY
        column.addArrangedSubview(entry)
        entry.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        if kind == .zoom { column.addArrangedSubview(keep) }
        column.addArrangedSubview(errorLabel)
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
        ])
    }

    func update(index: Int?, count: Int?, zoom: ImageStatus.ZoomDetails?) {
        loadViewIfNeeded()
        self.count = count
        errorLabel.stringValue = ""
        switch kind {
        case .zoom:
            heading.stringValue = "Zoom, %"
            input.stringValue = String(format: "%.2f", (zoom?.scale ?? 1) * 100)
            input.setAccessibilityLabel("Zoom percentage")
            keep.state = zoom?.keepingZoom == true ? .on : .off
            applyButton.title = "Apply"
            applyButton.isEnabled = zoom != nil
        case .position:
            heading.stringValue = count.map { "Photo number · 1–\($0)" } ?? "Counting photos…"
            input.stringValue = String((index ?? 0) + 1)
            input.setAccessibilityLabel("Photo number")
            applyButton.title = "Go"
            applyButton.isEnabled = count != nil && (count ?? 0) > 0
        }
    }

    /// Validation belongs to the actual command path, not just the text field formatter.
    @discardableResult func applyValue(_ text: String) -> Bool {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")),
              value.isFinite else { return invalid() }
        switch kind {
        case .zoom:
            guard value > 0, value <= 6400 else { return invalid() }
            onAction?(.zoomPercent(value))
        case .position:
            guard let count, let number = Int(exactly: value), number >= 1, number <= count else { return invalid() }
            onAction?(.position(number - 1))
        }
        return true
    }
    private func invalid() -> Bool {
        errorLabel.stringValue = kind == .zoom ? "Enter a percentage above 0 and up to 6400."
            : "Enter a whole photo number in the shown range."
        return false
    }
    @objc private func applyClicked() { applyValue(input.stringValue) }
    @objc private func presetClicked(_ sender: NSButton) {
        guard Self.presets.indices.contains(sender.tag) else { return }
        onAction?(.key(Self.presets[sender.tag].1))
    }
    @objc private func keepClicked() { onAction?(.key(.toggleKeepZoom)) }
}
