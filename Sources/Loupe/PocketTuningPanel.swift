import AppKit

/// View › Pocket Tuning…: every knob of the pocket bar prototype (`PocketTuning`) in one floating panel, applied as it is
/// moved, so one build is enough to find a look. The state of the bar and a dump of what the system's pocket is made of
/// (to read what it does, or to send) are here too.
@MainActor final class PocketTuningPanel: NSPanel {
    static let shared = PocketTuningPanel()
    /// Gives the key window's bar state and pocket dump; set by whoever opens the panel.
    var dump: (() -> String)?
    var barState: (() -> PocketBarState)?
    var setBarState: ((PocketBarState) -> Void)?

    private let output = NSTextView()
    private var controls: [() -> Void] = []   // each re-reads its value
    private var stateControl: NSSegmentedControl?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 720), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "Pocket Tuning"
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        setFrameAutosaveName("PocketTuningPanel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(10, after: stack.arrangedSubviews[max(0, stack.arrangedSubviews.count - 2)])
        }
        func row(_ title: String, _ control: NSView) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.widthAnchor.constraint(equalToConstant: 142).isActive = true
            let line = NSStackView(views: [label, control])
            line.spacing = 8
            line.alignment = .centerY
            stack.addArrangedSubview(line)
        }
        func popup(_ title: String, _ path: WritableKeyPath<PocketTuning.Values, Int>, _ options: [String]) {
            let button = NSPopUpButton(frame: .zero, pullsDown: false)
            button.controlSize = .small
            button.addItems(withTitles: options)
            let handler = ClosureTarget { PocketTuning.shared.values[keyPath: path] = button.indexOfSelectedItem }
            button.target = handler
            button.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(button, Unmanaged.passUnretained(self).toOpaque(), handler, .OBJC_ASSOCIATION_RETAIN)
            controls.append { button.selectItem(at: min(max(PocketTuning.shared.values[keyPath: path], 0), options.count - 1)) }
            row(title, button)
        }
        func check(_ title: String, _ path: WritableKeyPath<PocketTuning.Values, Bool>) {
            let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            let handler = ClosureTarget { PocketTuning.shared.values[keyPath: path] = box.state == .on }
            box.target = handler
            box.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(box, Unmanaged.passUnretained(self).toOpaque(), handler, .OBJC_ASSOCIATION_RETAIN)
            controls.append { box.state = PocketTuning.shared.values[keyPath: path] ? .on : .off }
            row(title, box)
        }
        func slider(_ title: String, _ path: WritableKeyPath<PocketTuning.Values, Double>, _ range: ClosedRange<Double>) {
            let slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
            slider.controlSize = .small
            slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let handler = ClosureTarget {
                PocketTuning.shared.values[keyPath: path] = (slider.doubleValue * 100).rounded() / 100
                value.stringValue = String(format: "%.2f", slider.doubleValue)
            }
            slider.target = handler
            slider.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(slider, Unmanaged.passUnretained(self).toOpaque(), handler, .OBJC_ASSOCIATION_RETAIN)
            controls.append {
                slider.doubleValue = PocketTuning.shared.values[keyPath: path]
                value.stringValue = String(format: "%.2f", slider.doubleValue)
            }
            row(title, NSStackView(views: [slider, value]))
        }

        heading("Bar")
        let state = NSSegmentedControl(labels: PocketBarState.allCases.map { $0.title }, trackingMode: .selectOne, target: nil, action: nil)
        state.controlSize = .small
        let stateHandler = ClosureTarget { [weak self] in
            self?.setBarState?(PocketBarState(rawValue: state.selectedSegment) ?? .full)
        }
        state.target = stateHandler
        state.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(state, Unmanaged.passUnretained(self).toOpaque(), stateHandler, .OBJC_ASSOCIATION_RETAIN)
        stateControl = state
        stack.addArrangedSubview(state)
        popup("Behind the text", \.backdrop, PocketTuning.Backdrop.allCases.map(\.title))
        slider("Row height", \.rowHeight, 28...90)
        slider("Reach below the row", \.fadeBelow, 0...140)
        slider("Side inset", \.sideInset, 0...40)
        check("Row in the title bar", \.rowInTitlebar)
        slider("Left inset (traffic lights)", \.windowedLeftInset, 0...120)
        slider("Info text size", \.infoSize, 9...16)
        slider("Info gap to buttons", \.infoGap, 0...60)
        slider("Button size", \.buttonSize, 11...26)
        popup("Button glass", \.buttonGlass, ["None", "Glass pills", "Clear glass pills", "Glass bezel on each"])
        slider("Gap between groups", \.buttonGap, 0...30)
        slider("Pill padding", \.pillPadding, 0...10)
        slider("Button opacity", \.buttonOpacity, 0.3...1)

        heading("System pocket (NSScrollPocket)")
        popup("Style", \.nativeStyle, ["0", "1", "2", "3"])
        popup("Appearance", \.appearance, ["System", "Light", "Dark"])
        check("Solid colour hard pocket", \.solidHard)
        check("Colour scheme adaptivity", \.adaptivity)
        check("Separators on hard pocket", \.separators)
        popup("Capture colour", \.captureColor, ["None", "Black", "White", "Grey"])
        popup("Portal shows", \.portalSource, ["Nothing", "The picture", "The whole window"])
        check("Portal matches position", \.portalMatchesPosition)
        check("Portal matches transform", \.portalMatchesTransform)
        check("Keep the blur view shown", \.forceBlur)

        heading("Own blur and tint")
        slider("Tint", \.customTint, 0...1)
        check("Blur", \.customBlur)
        check("Hard edge", \.customHard)

        let reset = NSButton(title: "Reset", target: nil, action: nil)
        reset.controlSize = .small
        let resetHandler = ClosureTarget { PocketTuning.shared.reset() }
        reset.target = resetHandler
        reset.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(reset, Unmanaged.passUnretained(self).toOpaque(), resetHandler, .OBJC_ASSOCIATION_RETAIN)
        let dumpButton = NSButton(title: "Dump the pocket", target: nil, action: nil)
        dumpButton.controlSize = .small
        let dumpHandler = ClosureTarget { [weak self] in
            guard let self else { return }
            self.output.string = self.dump?() ?? "No pocket bar in the front window (viewer-chrome=pocket)."
        }
        dumpButton.target = dumpHandler
        dumpButton.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(dumpButton, Unmanaged.passUnretained(self).toOpaque(), dumpHandler, .OBJC_ASSOCIATION_RETAIN)
        let copyButton = NSButton(title: "Copy values", target: nil, action: nil)
        copyButton.controlSize = .small
        let copyHandler = ClosureTarget {
            let data = (try? JSONEncoder().encode(PocketTuning.shared.values)) ?? Data()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        }
        copyButton.target = copyHandler
        copyButton.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(copyButton, Unmanaged.passUnretained(self).toOpaque(), copyHandler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(NSStackView(views: [reset, dumpButton, copyButton]))
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        output.string = "Dump the pocket to see what it is made of."
        let outputScroll = NSScrollView()
        outputScroll.documentView = output
        outputScroll.hasVerticalScroller = true
        outputScroll.translatesAutoresizingMaskIntoConstraints = false
        outputScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        outputScroll.widthAnchor.constraint(equalToConstant: 370).isActive = true
        stack.addArrangedSubview(outputScroll)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        contentView = scroll
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        NotificationCenter.default.addObserver(forName: .pocketTuningChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Reads every control from the values (a reset, another window's change).
    func refresh() {
        for control in controls { control() }
        stateControl?.selectedSegment = (barState?() ?? PocketBarState.stored).rawValue
    }

    func show(dump: @escaping () -> String, state: @escaping () -> PocketBarState,
              setState: @escaping (PocketBarState) -> Void) {
        self.dump = dump
        barState = state
        setBarState = setState
        refresh()
        makeKeyAndOrderFront(nil)
    }
}

/// A target that runs a closure (the panel's controls are made from a table, not from selectors).
private final class ClosureTarget: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
