import AppKit
import HomeScreenModel
import LoupeCore

/// The photo's facts in a row of slots, one per kind, each as wide as the longest value of its kind, so a new photo or a
/// zoom step changes the text of a label and moves nothing. Built once; an update touches only the labels whose value
/// changed. Laid out by frames, never by constraints: the row holds the slots that fit its width, in the order of
/// `priority`, and the rest stay out of sight (a narrow window keeps the position and the zoom longest).
@MainActor final class FactsRowView: NSView {
    struct Style: Equatable {
        var options: ProCameraStyle.Options
        /// A hairline between the facts that are shown.
        var hairlines = true
        /// An outline round the format, as a camera marks RAW or JPG.
        var formatBadge = false
        var alignment = NSTextAlignment.center
    }

    /// The longest value of each kind, for the width of its slot.
    private static func sample(_ kind: ImageStatus.Kind) -> ImageStatus.Fact {
        if kind == .exposure, let fact = ImageStatus.exposureFact(FileFacts(exposure: 1.0 / 8000, aperture: 22, iso: 25600,
                                                                            focalLength: 600, exposureBias: -0.3)) {
            return fact
        }
        return ImageStatus.Fact(kind, sampleText(kind))
    }

    private static func sampleText(_ kind: ImageStatus.Kind) -> String {
        switch kind {
        case .position: "999–999 / 9999"
        case .size: "99999×99999"
        case .megapixels: "999 MP"
        case .exposure: "1/8000  f/22  ISO 25600  600 mm  −0.3 EV"
        case .fileSize: "999.9 MB"
        case .format: "AVIF "
        case .zoom: "Fit height 100 %"
        }
    }

    /// Which slots stay when there is no room for all: first the position, then the zoom, the size, the weight, the format.
    private static let priority: [ImageStatus.Kind] = [.position, .zoom, .exposure, .size, .megapixels, .fileSize, .format]
    private static let slotPadding: CGFloat = 12
    /// What a text field's cell takes round its text (4 points a side): a field narrower than its text and this cuts the
    /// text short ("JP…" for "JPEG"), so every width here is the text's and this.
    private static let cellInset: CGFloat = 8
    private static let hairlineSpace: CGFloat = 1

    private struct Slot {
        let kind: ImageStatus.Kind
        let label = NSTextField(labelWithString: "")
        let hairline = NSView()
        let badge = NSView()
    }

    /// The kinds this row shows, in their order (every kind, or one side's of the stats bar).
    private let kinds: [ImageStatus.Kind]
    private let slots: [Slot]
    private var shown: [ImageStatus.Kind: ImageStatus.Fact] = [:]
    private var widths: [ImageStatus.Kind: CGFloat] = [:]
    /// What the value on show needs, for a value wider than the longest the kind's sample stands for (a format named by
    /// its type identifier, not by a short word): the slot grows to it, and nothing is cut to "JP…".
    private var valueWidths: [ImageStatus.Kind: CGFloat] = [:]

    var style: Style {
        didSet {
            guard style != oldValue else { return }
            widths = [:]
            valueWidths = [:]
            for slot in slots { render(slot) }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(style: Style, kinds: [ImageStatus.Kind] = ImageStatus.Kind.allCases) {
        self.style = style
        self.kinds = kinds
        slots = kinds.map { Slot(kind: $0) }
        super.init(frame: .zero)
        for slot in slots {
            slot.label.lineBreakMode = .byTruncatingTail
            slot.label.maximumNumberOfLines = 1
            slot.label.isHidden = true
            slot.hairline.wantsLayer = true
            slot.hairline.layer?.backgroundColor = ProCameraStyle.separator.cgColor
            slot.hairline.isHidden = true
            slot.badge.wantsLayer = true
            slot.badge.layer?.borderWidth = 1
            slot.badge.layer?.cornerRadius = 4
            slot.badge.layer?.cornerCurve = .continuous
            slot.badge.isHidden = true
            addSubview(slot.badge)
            addSubview(slot.hairline)
            addSubview(slot.label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// How long a load must last before the facts of the photo before turn grey: a photo that comes sooner changes the
    /// text only, without a grey frame in between.
    static let staleDelay: TimeInterval = 0.15

    /// The facts are greyed (`ImageStatus.stale` for longer than `staleDelay`); the owner greys what it shows beside them.
    private(set) var greyed = false {
        didSet { if greyed != oldValue { onGreyedChange?() } }
    }
    var onGreyedChange: (() -> Void)?
    private var stale = false
    private var staleTimer: Timer?

    /// The facts to show; a kind that is not among them leaves its slot empty, unless it is `pending` (still being read),
    /// which keeps the value on show until it is in. `stale` facts are the photo's before: grey once the load is felt.
    func update(_ facts: [ImageStatus.Fact], stale: Bool = false, pending: Set<ImageStatus.Kind> = []) {
        var changed = false
        for slot in slots {
            let fact = facts.first { $0.kind == slot.kind }
            if fact == nil, pending.contains(slot.kind) { continue }
            guard shown[slot.kind] != fact else { continue }
            shown[slot.kind] = fact
            slot.label.toolTip = fact == nil ? nil : slot.kind.tip
            render(slot)
            changed = true
        }
        setStale(stale)
        if changed { needsLayout = true }
    }

    private func setStale(_ new: Bool) {
        guard new != stale else { return }
        stale = new
        staleTimer?.invalidate()
        staleTimer = nil
        if new {
            staleTimer = Timer.scheduledTimer(withTimeInterval: Self.staleDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setGreyed(true) }
            }
        } else {
            setGreyed(false)
        }
    }

    private func setGreyed(_ new: Bool) {
        guard new != greyed else { return }
        greyed = new
        for slot in slots where shown[slot.kind] != nil { render(slot) }
    }

    private func render(_ slot: Slot) {
        guard var fact = shown[slot.kind] else {
            slot.label.isHidden = true
            valueWidths[slot.kind] = nil
            return
        }
        // The place and the zoom are the viewer's own, never the photo's before.
        if greyed, slot.kind != .position, slot.kind != .zoom {
            fact = ImageStatus.Fact(fact.kind, fact.value, tone: .quiet, parts: fact.parts)
        }
        // The alignment is the text's own paragraph style: a field takes it from there, not from `alignment`.
        let text = NSMutableAttributedString(attributedString: ProCameraStyle.text(fact, style.options))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        slot.label.attributedStringValue = text
        let needed = ceil(text.size().width) + Self.cellInset + Self.slotPadding
        if valueWidths[slot.kind] != needed {
            valueWidths[slot.kind] = needed
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        slot.badge.layer?.borderColor = ProCameraStyle.color(fact.tone, monochrome: style.options.monochrome)
            .withAlphaComponent(0.7).cgColor
        slot.label.isHidden = false
    }

    private func width(of kind: ImageStatus.Kind) -> CGFloat {
        let sample: CGFloat
        if let width = widths[kind] {
            sample = width
        } else {
            sample = ceil(ProCameraStyle.text(Self.sample(kind), style.options).size().width)
                + Self.cellInset + Self.slotPadding
            widths[kind] = sample
        }
        return max(sample, valueWidths[kind] ?? 0)
    }

    /// The row's width with every slot in it.
    var naturalWidth: CGFloat { width(for: kinds) }

    private func width(for kinds: [ImageStatus.Kind]) -> CGFloat {
        kinds.reduce(0) { $0 + width(of: $1) } + CGFloat(max(0, kinds.count - 1)) * Self.hairlineSpace
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: naturalWidth, height: ceil(ProCameraStyle.font(style.options.size).boundingRectForFont.height))
    }

    override func layout() {
        super.layout()
        // The slots that fit, taken in order of priority, are laid out in their own order.
        var kept: [ImageStatus.Kind] = []
        for kind in Self.priority where kinds.contains(kind) {
            let candidate = kinds.filter { kept.contains($0) || $0 == kind }
            guard width(for: candidate) <= bounds.width + 0.5 else { break }
            kept = candidate
        }
        var x: CGFloat = 0
        var anyShown = false
        for slot in slots {
            let visible = kept.contains(slot.kind)
            let slotWidth = width(of: slot.kind)
            let present = visible && shown[slot.kind] != nil
            slot.label.isHidden = !present
            slot.hairline.isHidden = !(present && anyShown && style.hairlines)
            slot.badge.isHidden = !(present && slot.kind == .format && style.formatBadge)
            guard visible else { continue }
            let height = ceil(slot.label.intrinsicContentSize.height)
            let labelFrame = NSRect(x: x + Self.slotPadding / 2, y: (bounds.height - height) / 2,
                                    width: slotWidth - Self.slotPadding, height: height)
            slot.label.frame = backingAlignedRect(labelFrame, options: .alignAllEdgesNearest)
            slot.hairline.frame = NSRect(x: x - Self.hairlineSpace, y: (bounds.height - 12) / 2, width: 1, height: 12)
            slot.badge.frame = backingAlignedRect(NSRect(x: x + 4, y: (bounds.height - 16) / 2, width: slotWidth - 8, height: 16),
                                                  options: .alignAllEdgesNearest)
            if present { anyShown = true }
            x += slotWidth + Self.hairlineSpace
        }
    }
}
