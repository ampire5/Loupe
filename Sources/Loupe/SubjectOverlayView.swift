import AppKit
import LoupeCore

/// Show Subjects (`⇧G`, View › Show Subjects): what Vision found over the photo (`SubjectOverlay`) — every box thin, by
/// kind (face yellow, person blue, object green, where the eye goes purple, the custom detector's in its own colours), the chain's choice bold, a face's head
/// dashed, the frame white dashed with a cross at its centre — and a caption of the counts. Over the viewer, framed to
/// it; takes no clicks. Hidden while off, so the picture keeps its direct-to-display path. The crop check
/// (`SubjectCrop`): once a zoomed view rests, what Vision finds in the visible part alone is drawn over it in orange,
/// with a second caption line.
///
/// Drawn with layers (owner, 2026-10-28: the overlay made zoom and pan stutter): a box is a pair of shape layers, a
/// label a text layer, made when the boxes, the chain or the crop change; a frame of a zoom or pan only moves them.
/// Before, every frame drew the whole window's backing store on the CPU and laid the caption out again.
@MainActor final class SubjectOverlayView: NSView {
    /// The boxes for the photo on screen, the chain they are framed with, and what to say without them.
    struct Source: Equatable {
        var boxes: SubjectBoxes?
        var chain: [SubjectKind]
        /// Said instead of the counts: analysis off, two pages, still looking.
        var note: String?
        /// The head framing while browsing guessed on a person (`BrowseFraming`), framed instead of it.
        var guessedHead: CGRect? = nil
        /// The custom detector's mode whose chain this is, named first in the caption.
        var mode: String? = nil
        var composition: SubjectComposition? = nil
    }

    /// Asked for on every change while on (a lock and a short scan, `SubjectFinder.boxes`): the layers are made again
    /// only when what it says changed.
    var source: ((URL) -> Source)?
    /// The crop check (`SubjectCrop`): the view rested `settleDelay` on a crop of `url`; the window controller asks
    /// Vision about it and hands the boxes to `setCrop`.
    var onSettled: ((URL, ViewTransform) -> Void)?
    /// How long the view stays still before the crop is looked at: past a zoom animation (~0.25 s) and a pause between
    /// two steps of a gesture.
    static let settleDelay: TimeInterval = 0.35

    /// What Vision found on the crop last looked at, in the photo's space, and the chain it is framed with.
    private var crop: (url: URL, boxes: SubjectBoxes, chain: [SubjectKind])?
    private var settle: DispatchWorkItem?

    private var url: URL?
    private var transform = ViewTransform(imageSize: .zero, viewSize: .zero)
    /// What the layers were made for: the source, the crop's boxes and the backing scale.
    private var made: (url: URL?, source: Source?, crop: SubjectBoxes?, scale: CGFloat)?
    private let captionField = NSTextField(labelWithString: "")
    private let captionBox = NSView()
    /// The marks' layers, in points with the origin top left (flipped here if the view's layer is not).
    private let marksLayer = CALayer()
    /// One per mark of the photo's overlay, then the crop's: the dark line under, the coloured one; a label's text
    /// layer, by mark; the centre's cross.
    private var strokes: [(under: CAShapeLayer, over: CAShapeLayer)] = []
    private var labels: [CATextLayer] = []
    private var crosses: [(under: CAShapeLayer, over: CAShapeLayer)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.addSublayer(marksLayer)
        captionBox.wantsLayer = true
        captionBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        captionBox.layer?.cornerRadius = 6
        captionField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        captionField.textColor = .white
        captionField.usesSingleLineMode = false
        captionField.maximumNumberOfLines = 2   // the photo's line, the crop's
        captionBox.addSubview(captionField)
        addSubview(captionBox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        placeCaption()
        place()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()   // the text layers' scale
    }

    var isOn: Bool {
        get { !isHidden }
        set {
            isHidden = !newValue
            if newValue { refresh(); scheduleSettle() } else { settle?.cancel(); crop = nil; made = nil }
        }
    }

    /// The photo and transform the viewer just handed the render loop.
    func show(_ url: URL?, transform: ViewTransform) {
        let moved = url != self.url || transform.visibleRect != self.transform.visibleRect
        if url != self.url { crop = nil }
        self.url = url
        self.transform = transform
        guard isOn else { return }
        refresh()
        if moved { scheduleSettle() }
    }

    /// One pending look at the crop, restarted by every move; none while off.
    private func scheduleSettle() {
        settle?.cancel()
        guard let url else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, isOn, self.url == url else { return }
            onSettled?(url, transform)
        }
        settle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: item)
    }

    /// A model change invalidates crop boxes even when the viewport has not moved.
    func analysisChanged() {
        crop = nil; made = nil; refresh()
        if isOn { scheduleSettle() }
    }

    /// The crop's boxes (nil: none to show, the view is not a crop).
    func setCrop(_ url: URL, boxes: SubjectBoxes?, chain: [SubjectKind]) {
        crop = boxes.map { (url, $0, chain) }
        refresh()
    }

    /// Asks the source again (the boxes came, the chain changed, the view moved): the layers and the caption are made
    /// again when it says something else, else only moved.
    func refresh() {
        guard isOn else { return }
        let s = url.flatMap { source?($0) }
        let cropBoxes = crop.flatMap { $0.url == url ? $0.boxes : nil }
        let scale = window?.backingScaleFactor ?? 1
        if made == nil || made?.url != url || made?.source != s || made?.crop != cropBoxes || made?.scale != scale {
            made = (url, s, cropBoxes, scale)
            caption(s, cropBoxes: cropBoxes)
            makeLayers(scale: scale)
        }
        place()
    }

    /// The overlays at the transform: the photo's, then the crop's.
    private func overlays() -> [(overlay: SubjectOverlay, only: NSColor?)] {
        var result: [(SubjectOverlay, NSColor?)] = []
        if let s = made?.source, let boxes = s.boxes {
            result.append((SubjectOverlay(boxes, chain: s.chain, transform: transform, guessedHead: s.guessedHead, composition: s.composition), nil))
        }
        if let crop, crop.url == url {
            // The crop's own finds over the photo's, all in one colour.
            result.append((SubjectOverlay(crop.boxes, chain: crop.chain, transform: transform), .systemOrange))
        }
        return result
    }

    private func caption(_ s: Source?, cropBoxes: SubjectBoxes?) {
        var caption: String
        if let boxes = s?.boxes, let chain = s?.chain {
            caption = SubjectOverlay.caption(boxes, chain: chain, guessedHead: s?.guessedHead != nil, mode: s?.mode)
        } else {
            caption = s?.note ?? "No photo"
        }
        if let note = s?.note, s?.boxes != nil { caption = note + " · " + caption }
        if let crop, let cropBoxes {
            caption += "\nCrop: " + SubjectOverlay.caption(cropBoxes, chain: crop.chain)
        }
        guard caption != captionField.stringValue else { return }
        captionField.stringValue = caption
        captionField.sizeToFit()
        placeCaption()
    }

    private func placeCaption() {
        let size = captionField.frame.size
        // Bottom left: the top of the viewer is under the toolbar and the stats bar.
        captionBox.frame = CGRect(x: 12, y: bounds.height - safeAreaInsets.bottom - size.height - 8 - 12,
                                  width: size.width + 16, height: size.height + 8)
        captionField.frame.origin = CGPoint(x: 8, y: 4)
    }

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    /// The layers for the overlays as they are now: a pair of strokes per mark, a text layer per label, a cross per
    /// centre; styled here, placed by `place`.
    private func makeLayers(scale: CGFloat) {
        marksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        strokes = []
        labels = []
        crosses = []
        for (overlay, only) in overlays() {
            for mark in overlay.marks {
                let (color, width, dash): (NSColor, CGFloat, [CGFloat]) = switch mark.role {
                case .found: (Self.color(mark.kind), 1, mark.kind == .saliency ? [4, 3] : [])
                case .chosen: (Self.color(mark.kind), 2.5, [])
                case .head: (Self.color(mark.kind), 1, [3, 3])
                case .frame: (.white, 1.5, [8, 4])
                }
                strokes.append(strokePair(color: only ?? color, width: width, dash: dash))
            }
            // Each box's label over its top left corner (inside it at the view's top); a box drawn twice (found, and
            // chosen as part of a combination) once: the last mark's, drawn over the others.
            var labelled: [CGRect] = []
            for mark in overlay.marks.reversed() {
                guard let label = mark.label, !labelled.contains(mark.rect) else { continue }
                labelled.append(mark.rect)
                labels.append(textLayer(label, color: only ?? Self.color(mark.kind), scale: scale))
            }
            if overlay.centre != nil { crosses.append(strokePair(color: only ?? .white, width: 2, dash: [])) }
        }
    }

    /// A dark line under the coloured one, so a box reads on light and dark photos alike.
    private func strokePair(color: NSColor, width: CGFloat, dash: [CGFloat]) -> (under: CAShapeLayer, over: CAShapeLayer) {
        func shape(_ color: NSColor, _ width: CGFloat, _ dash: [CGFloat]) -> CAShapeLayer {
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            layer.lineDashPattern = dash.isEmpty ? nil : dash.map { NSNumber(value: Double($0)) }
            marksLayer.addSublayer(layer)
            return layer
        }
        return (shape(NSColor.black.withAlphaComponent(0.6), width + 2, []), shape(color, width, dash))
    }

    /// A label on a dark plate in the box's colour, so it reads on any photo.
    private func textLayer(_ text: String, color: NSColor, scale: CGFloat) -> CATextLayer {
        let string = NSAttributedString(string: text, attributes: [.font: Self.labelFont, .foregroundColor: color])
        let size = string.size()
        let layer = CATextLayer()
        layer.string = string
        layer.contentsScale = scale
        layer.alignmentMode = .center
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer.cornerRadius = 3
        layer.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 8, height: ceil(size.height) + 2)
        layer.anchorPoint = .zero
        marksLayer.addSublayer(layer)
        return layer
    }

    /// The layers at the transform: paths and places only, without implicit animations.
    private func place() {
        guard isOn, made != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        marksLayer.frame = bounds
        // Top-left origin for the marks, whether or not AppKit flipped the view's layer.
        marksLayer.isGeometryFlipped = layer?.contentsAreFlipped() == false
        // The transform's space is physical pixels; this view's is points, both top-left with y down.
        let k = 1 / (window?.backingScaleFactor ?? 1)
        func rect(_ r: CGRect) -> CGRect { CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k) }
        var stroke = 0, label = 0, cross = 0
        for (overlay, _) in overlays() {
            for mark in overlay.marks where stroke < strokes.count {
                let path = CGPath(rect: rect(mark.rect), transform: nil)
                strokes[stroke].under.path = path
                strokes[stroke].over.path = path
                stroke += 1
            }
            var labelled: [CGRect] = []
            for mark in overlay.marks.reversed() where label < labels.count {
                guard mark.label != nil, !labelled.contains(mark.rect) else { continue }
                labelled.append(mark.rect)
                let r = rect(mark.rect), plate = labels[label].bounds.size
                labels[label].position = CGPoint(x: r.minX, y: r.minY - plate.height >= 0 ? r.minY - plate.height : r.minY)
                label += 1
            }
            if let c = overlay.centre, cross < crosses.count {
                let p = CGPoint(x: c.x * k, y: c.y * k), r: CGFloat = 9
                let path = CGMutablePath()
                path.move(to: CGPoint(x: p.x - r, y: p.y)); path.addLine(to: CGPoint(x: p.x + r, y: p.y))
                path.move(to: CGPoint(x: p.x, y: p.y - r)); path.addLine(to: CGPoint(x: p.x, y: p.y + r))
                crosses[cross].under.path = path
                crosses[cross].over.path = path
                cross += 1
            }
        }
    }

    private static func color(_ kind: SubjectKind?) -> NSColor {
        switch kind {
        case nil: return .white
        case .face?: return .systemYellow
        case .person?: return .systemBlue
        case .object?: return .systemGreen
        case .saliency?: return .systemPurple
        case let kind?:
            // The custom detector's kinds: one colour each, by their place in detector.conf.
            let palette: [NSColor] = [.systemRed, .systemPink, .systemOrange, .systemTeal, .systemIndigo, .systemBrown, .systemMint]
            let i = SubjectFraming.detector.kinds.firstIndex(of: kind) ?? 0
            return palette[i % palette.count]
        }
    }
}
