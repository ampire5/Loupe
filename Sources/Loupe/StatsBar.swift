import AppKit
import HomeChrome
import LoupeCore

/// The stats bar (spec §10): the photo's status over the picture, shown or hidden. A dark strip along the window's top
/// or bottom edge, blurred and tinted, both fading out at its inner edge, so it reads on any photo and has no line to
/// stand out by. Two rows. The first is the facts, which carry the most text: on the left each fact in a slot of its
/// own (`FactsRowView`), at the right end, aligned to it, the file's date and the decode time. The second is the names:
/// the file's on the left, the folder's at the right end, where the news about the folder (`Loading folder…`) also
/// stands. It is a separate view from the Metal surface, so a text change never wakes the render loop.
///
/// Nothing in it changes size or appears and goes with a status: the two columns have widths of their own that depend
/// on the bar alone, every slot is as wide as its longest value, and a step only changes texts (`ImageStatus` keeps the
/// facts through a load). The darkness is `stats-bar-opacity`; the strip is lightened, up to the photo's place in the
/// folder, by `stats-progress-opacity` of white (`stats-progress`). Laid out by frames, not constraints, and only what
/// changed.
@MainActor final class StatsBar: NSView {
    /// The strip's solid part (two rows of text) and the fade below it.
    static let contentHeight: CGFloat = 42
    static let fadeHeight: CGFloat = 56
    static var height: CGFloat { contentHeight + fadeHeight }
    private static let inset: CGFloat = 14
    private static let columnGap: CGFloat = 20
    /// The right column's share of the bar and its limits: fixed by the bar's width, never by what it says.
    private static let rightShare: CGFloat = 0.32
    private static let rightWidths: ClosedRange<CGFloat> = 150...360
    /// A bar narrower than this has the left column only.
    private static let narrowest: CGFloat = 520
    private static let rowHeights: (top: CGFloat, bottom: CGFloat) = (16, 17)

    /// The strip itself: blur and tint fading out at the inner edge (`EdgeEffectView`), the progress fill on the tint. The
    /// text is not in it.
    private let effect = EdgeEffectView(solidHeight: StatsBar.contentHeight, softFadeHeight: StatsBar.fadeHeight)
    private let fill = NSView()
    private let factsRow: FactsRowView
    private let detailLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let folderLabel = NSTextField(labelWithString: "")

    private var status = ImageStatus()
    private var options: ProCameraStyle.Options
    private var progressOpacity = Config().statsProgressOpacity
    private var barOpacity = Config().statsBarOpacity
    /// `stats-bar-autohide`: the delay, nil when off.
    private var autohideDelay: TimeInterval?
    private var hideTimer: Timer?
    /// `stats-modified`, and the date of the photo on screen (read off the main thread, once per photo).
    private var showsModified = Config().statsModified
    private var modified: Date?
    private var modifiedURL: URL?
    /// The strip is on the window's bottom edge (above the filmstrip), the fade above it.
    var atBottom = false {
        didSet {
            effect.atBottom = atBottom
            if atBottom != oldValue { needsLayout = true }
        }
    }
    /// `stats-bar-blur`.
    var showsBlur = true {
        didSet { effect.blurs = showsBlur }
    }
    /// `stats-bar-edge`.
    var edgeStyle = StatsBarEdge.soft {
        didSet {
            effect.style = edgeStyle == .soft ? .soft : .hard
            needsLayout = true
        }
    }
    /// `stats-progress`.
    var showsProgress = true {
        didSet { if showsProgress != oldValue { needsLayout = true } }
    }
    /// `stats-folder-name`.
    var showsFolderName = true {
        didSet { if showsFolderName != oldValue { refreshFolder() } }
    }

    override init(frame: NSRect) {
        let config = Config()
        options = ProCameraStyle.Options(size: 11.5, icons: config.statsIcons, monochrome: config.statsMonochrome, shadow: true)
        factsRow = FactsRowView(style: .init(options: options, hairlines: false, alignment: .left))
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        effect.tintView.addSubview(fill)
        fill.wantsLayer = true
        addSubview(effect)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, folderLabel, detailLabel] {
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        folderLabel.alignment = .right
        detailLabel.alignment = .right
        addSubview(factsRow)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        applyBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Purely visual: in full screen the bar covers the top of the viewer, and every click, scroll and pinch there must
    /// still reach the viewer underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The part of the frame the text stands on: what the info panel and the other overlays keep clear of.
    var occupiedFrame: NSRect {
        atBottom ? NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: Self.contentHeight)
                 : NSRect(x: frame.minX, y: frame.maxY - Self.contentHeight, width: frame.width, height: Self.contentHeight)
    }

    /// The stats bar keys of `config` (on every reload).
    func apply(_ config: Config) {
        showsProgress = config.statsProgress
        showsBlur = config.statsBarBlur
        edgeStyle = config.statsBarEdge
        showsFolderName = config.statsFolderName
        let delay = config.statsBarAutohide ? TimeInterval(config.statsBarHideDelayMilliseconds) / 1000 : nil
        if delay != autohideDelay {
            autohideDelay = delay
            reveal()
        }
        if progressOpacity != config.statsProgressOpacity || barOpacity != config.statsBarOpacity {
            progressOpacity = config.statsProgressOpacity
            barOpacity = config.statsBarOpacity
            applyBackground()
        }
        if options.icons != config.statsIcons || options.monochrome != config.statsMonochrome {
            options.icons = config.statsIcons
            options.monochrome = config.statsMonochrome
            factsRow.style.options = options
            refreshTitle()
            refreshFolder()
            refreshDetail()
        }
        if showsModified != config.statsModified {
            showsModified = config.statsModified
            loadModified()
        }
    }

    /// Shown now; with `stats-bar-autohide` it fades out again after the delay. Nothing runs at rest.
    func reveal() {
        hideTimer?.invalidate()
        hideTimer = nil
        if alphaValue != 1 { NSAnimationContext.runAnimationGroup { $0.duration = 0.14; animator().alphaValue = 1 } }
        guard let delay = autohideDelay else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self?.animator().alphaValue = 0 }
            }
        }
    }

    /// The status to show. A pan or anything else that does not change it costs nothing.
    func update(_ new: ImageStatus) {
        guard new != status else { return }
        let old = status
        status = new
        if new.title != old.title || new.titleTone != old.titleTone { refreshTitle() }
        factsRow.update(new.facts)
        if new.progress != old.progress { needsLayout = true }
        if new.folder != old.folder || new.note != old.note || new.noteTone != old.noteTone { refreshFolder() }
        if new.photo != old.photo { loadModified() }
        if new.decodeMilliseconds != old.decodeMilliseconds { refreshDetail() }
    }

    // MARK: Texts

    private func refreshTitle() {
        titleLabel.attributedStringValue = ProCameraStyle.name(
            status.title, size: 12, weight: .semibold,
            color: ProCameraStyle.color(status.titleTone, monochrome: options.monochrome))
        titleLabel.toolTip = status.title
    }

    /// The folder's name, or the news about the folder in its place.
    private func refreshFolder() {
        let text: String, color: NSColor
        if let note = status.note {
            text = note
            color = ProCameraStyle.color(status.noteTone, monochrome: options.monochrome)
        } else {
            text = showsFolderName ? status.folder.map(FolderLabel.name(of:)) ?? "" : ""
            color = ProCameraStyle.primary
        }
        folderLabel.attributedStringValue = text.isEmpty ? NSAttributedString()
            : ProCameraStyle.name(text, size: 12, weight: .regular, color: color)
        folderLabel.toolTip = status.note ?? status.folder?.path
    }

    /// The first row's right end: the date, then the decode time.
    private func refreshDetail() {
        let detail = NSMutableAttributedString()
        func add(_ piece: NSAttributedString) {
            if detail.length > 0 { detail.append(ProCameraStyle.plain("   ", options.size, .regular, ProCameraStyle.secondary, options)) }
            detail.append(piece)
        }
        if showsModified, let modified, modifiedURL == status.photo {
            add(ProCameraStyle.detail(ProCameraStyle.dateSymbol, InfoPanelContent.dateText(modified), tone: .quiet, options))
        }
        if let ms = status.decodeMilliseconds {
            add(ProCameraStyle.detail(ProCameraStyle.decodeSymbol, "decode \(ms) ms",
                                      tone: ImageStatus.decodeTone(milliseconds: ms), options))
        }
        detailLabel.attributedStringValue = detail
    }

    /// The date of the photo on screen is read in the background; the row gets it when it is in.
    private func loadModified() {
        guard showsModified, let url = status.photo else {
            modified = nil
            modifiedURL = nil
            refreshDetail()
            return
        }
        guard modifiedURL != url else { return }
        modifiedURL = url
        modified = nil
        refreshDetail()
        Task { [weak self] in
            let date = await Task.detached(priority: .utility) {
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }.value
            guard let self, self.modifiedURL == url, let date else { return }
            self.modified = date
            self.refreshDetail()
        }
    }

    // MARK: Look

    /// The strip's tint at `stats-bar-opacity`, in the dark of the over-media palette; the fill lightens it with white at
    /// `stats-progress-opacity`: no new hue, visible at a glance, over a picture or the window's own background.
    private func applyBackground() {
        effect.tintOpacity = barOpacity
        fill.layer?.backgroundColor = NSColor(white: 1, alpha: progressOpacity).cgColor
    }

    override func layout() {
        super.layout()
        // The effect lies on the edge the bar is on, as tall as its style makes it.
        let effectHeight = effect.height
        effect.frame = NSRect(x: 0, y: atBottom ? 0 : bounds.height - effectHeight, width: bounds.width, height: effectHeight)
        fill.isHidden = !showsProgress || status.progress <= 0
        if !fill.isHidden {
            fill.frame = backingAlignedRect(NSRect(x: 0, y: 0, width: bounds.width * status.progress, height: effectHeight),
                                            options: .alignAllEdgesNearest)
        }
        // The two rows stand on the solid part, at the edge the bar is on: the facts above, the names below.
        let rows = Self.rowHeights
        let contentBottom = atBottom ? 0 : bounds.height - Self.contentHeight
        let padding = (Self.contentHeight - rows.top - rows.bottom) / 2
        let topRowY = contentBottom + padding + rows.bottom
        let bottomRowY = contentBottom + padding
        let available = max(0, bounds.width - 2 * Self.inset)
        let showsRight = bounds.width >= Self.narrowest
        let right = showsRight ? min(max(available * Self.rightShare, Self.rightWidths.lowerBound), Self.rightWidths.upperBound) : 0
        let left = max(0, available - right - (showsRight ? Self.columnGap : 0))
        // The slots carry their own padding, which the text's left edge gives back.
        factsRow.frame = backingAlignedRect(NSRect(x: Self.inset - 6, y: topRowY, width: left + 12, height: rows.top),
                                            options: .alignAllEdgesNearest)
        place(titleLabel, x: Self.inset, y: bottomRowY, width: left, height: rows.bottom)
        detailLabel.isHidden = !showsRight
        folderLabel.isHidden = !showsRight
        place(detailLabel, x: bounds.width - Self.inset - right, y: topRowY, width: right, height: rows.top)
        place(folderLabel, x: bounds.width - Self.inset - right, y: bottomRowY, width: right, height: rows.bottom)
    }

    private func place(_ label: NSTextField, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        label.frame = backingAlignedRect(NSRect(x: x, y: y, width: width, height: height), options: .alignAllEdgesNearest)
    }
}
