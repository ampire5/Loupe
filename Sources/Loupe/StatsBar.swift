import AppKit
import HomeChrome
import LoupeCore

/// The stats bar (spec §10): the photo's status over the picture, shown or hidden. A strip along the window's top or
/// bottom edge, as wide as the window, in the dark of the over-media palette (`stats-bar-opacity`): square, without blur,
/// so the white text reads on any photo. The facts are split between the two ends so that both weigh about the same:
/// the photo's own (its place, size, megapixels, exposure) on the left, each in a slot of its own (`FactsRowView`); the
/// zoom, the file's size and format, its date and the decode time on the right, aligned to the right edge. Two rows: the
/// facts above, the names below (the file's on the left, the folder's at the right end, where the news about the folder,
/// `Loading folder…`, also stands). With `stats-bar-rows` 1 it is one row: the file's name, a dot and the folder's name in
/// the middle of the bar between the two ends. It is a separate view from the Metal surface, so a text change never wakes
/// the render loop.
///
/// Nothing in it changes size or appears and goes with a status: the two columns have widths of their own that depend
/// on the bar alone, every slot (the date's and the decode time's too) is as wide as its longest value, and a step only
/// changes texts: `ImageStatus` keeps the facts and the decode time through a load, the exposure while the EXIF is
/// read, and the date stays until the new photo's is in. The photo before's are greyed only when the load is felt. The darkness is `stats-bar-opacity`; the strip is lightened, up to the photo's place in the
/// folder, by `stats-progress-opacity` of white (`stats-progress`). Laid out by frames, not constraints, and only what
/// changed.
@MainActor final class StatsBar: NSView {
    /// The strip's height: two rows of text, or one.
    static func height(rows: Int) -> CGFloat { rows == 1 ? 26 : 42 }
    private static let inset: CGFloat = 14
    private static let columnGap: CGFloat = 20
    /// The room the names keep in the middle of one row before the ends give up slots.
    private static let namesRoom: CGFloat = 240
    /// A bar narrower than this has the left end only.
    private static let narrowest: CGFloat = 520
    /// The kinds at each end.
    private static let leftKinds: [ImageStatus.Kind] = [.position, .size, .megapixels, .exposure]
    private static let rightKinds: [ImageStatus.Kind] = [.zoom, .fileSize, .format]
    private static let rowHeights: (top: CGFloat, bottom: CGFloat) = (16, 17)

    /// The strip itself (the tint) and the progress fill on it. The text is not in it.
    private let tint = NSView()
    private let fill = NSView()
    /// The facts at the left end and at the right one (`factsRow` also tells when the facts are greyed).
    private let factsRow: FactsRowView
    private let rightFactsRow: FactsRowView
    private let dateLabel = NSTextField(labelWithString: "")
    private let decodeLabel = NSTextField(labelWithString: "")
    /// The date's and the decode time's slots, as wide as their longest values (with the options they were measured for).
    private var detailWidths: (date: CGFloat, decode: CGFloat, options: ProCameraStyle.Options)?
    private static let detailGap: CGFloat = 16
    private let titleLabel = NSTextField(labelWithString: "")
    private let folderLabel = NSTextField(labelWithString: "")

    private var status = ImageStatus()
    private var heightConstraint: NSLayoutConstraint!
    /// `stats-bar-rows`.
    private var rows = Config().statsBarRows
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
    /// `stats-progress`.
    var showsProgress = true {
        didSet { if showsProgress != oldValue { needsLayout = true } }
    }
    /// `stats-folder-name`.
    var showsFolderName = true {
        didSet { if showsFolderName != oldValue { refreshNames() } }
    }

    override init(frame: NSRect) {
        let config = Config()
        options = ProCameraStyle.Options(size: 11.5, icons: config.statsIcons, monochrome: config.statsMonochrome, shadow: true)
        factsRow = FactsRowView(style: .init(options: options, hairlines: false, alignment: .left), kinds: Self.leftKinds)
        rightFactsRow = FactsRowView(style: .init(options: options, hairlines: false, alignment: .right),
                                     kinds: Self.rightKinds)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        tint.wantsLayer = true
        fill.wantsLayer = true
        addSubview(tint)
        tint.addSubview(fill)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.lineBreakMode = .byTruncatingMiddle
        for label in [dateLabel, decodeLabel] { label.lineBreakMode = .byTruncatingTail }
        for label in [titleLabel, folderLabel, dateLabel, decodeLabel] {
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        addSubview(factsRow)
        addSubview(rightFactsRow)
        factsRow.onGreyedChange = { [weak self] in self?.refreshDetail() }
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height(rows: rows))
        heightConstraint.isActive = true
        applyBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Purely visual: in full screen the bar covers the top of the viewer, and every click, scroll and pinch there must
    /// still reach the viewer underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The stats bar keys of `config` (on every reload).
    func apply(_ config: Config) {
        showsProgress = config.statsProgress
        showsFolderName = config.statsFolderName
        if rows != config.statsBarRows {
            rows = config.statsBarRows
            heightConstraint.constant = Self.height(rows: rows)
            refreshNames()
            needsLayout = true
        }
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
            rightFactsRow.style.options = options
            refreshNames()
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
        if new.title != old.title || new.titleTone != old.titleTone { refreshNames() }
        factsRow.update(new.facts, stale: new.stale, pending: new.pending)
        rightFactsRow.update(new.facts, stale: new.stale, pending: new.pending)
        if new.progress != old.progress { needsLayout = true }
        if new.folder != old.folder || new.note != old.note || new.noteTone != old.noteTone { refreshNames() }
        if new.photo != old.photo { loadModified() }
        if new.decodeMilliseconds != old.decodeMilliseconds { refreshDetail() }
    }

    // MARK: Texts

    /// The folder's name, or the news about the folder in its place.
    private var folderText: (text: String, color: NSColor) {
        if let note = status.note {
            return (note, ProCameraStyle.color(status.noteTone, monochrome: options.monochrome))
        }
        return (showsFolderName ? status.folder.map(FolderLabel.name(of:)) ?? "" : "", ProCameraStyle.primary)
    }

    /// The names: in two rows the file's under the facts and the folder's at the right end; in one row both in the middle,
    /// the file, a dot with room round it, the folder.
    private func refreshNames() {
        let titleColor = ProCameraStyle.color(status.titleTone, monochrome: options.monochrome)
        let folder = folderText
        if rows == 1 {
            let line = NSMutableAttributedString(attributedString: ProCameraStyle.name(
                status.title, size: 12, weight: .semibold, color: titleColor))
            if !folder.text.isEmpty {
                line.append(ProCameraStyle.name("  ·  ", size: 12, weight: .regular, color: ProCameraStyle.secondary))
                line.append(ProCameraStyle.name(folder.text, size: 12, weight: .regular, color: folder.color))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            titleLabel.attributedStringValue = line
            titleLabel.toolTip = [status.title, status.note ?? status.folder?.path].compactMap { $0 }.joined(separator: "\n")
            folderLabel.attributedStringValue = NSAttributedString()
            folderLabel.toolTip = nil
        } else {
            titleLabel.attributedStringValue = ProCameraStyle.name(status.title, size: 12, weight: .semibold, color: titleColor)
            titleLabel.toolTip = status.title
            folderLabel.attributedStringValue = folder.text.isEmpty ? NSAttributedString()
                : Self.aligned(ProCameraStyle.name(folder.text, size: 12, weight: .regular, color: folder.color), .right,
                               .byTruncatingMiddle)
            folderLabel.toolTip = status.note ?? status.folder?.path
        }
        needsLayout = true
    }

    /// The first row's right end: the date, then the decode time, each right-aligned in its own slot. The decode time
    /// is the photo before's while the new one loads, grey with its facts.
    private func refreshDetail() {
        if showsModified, let modified {
            dateLabel.attributedStringValue = Self.aligned(ProCameraStyle.detail(
                ProCameraStyle.dateSymbol, InfoPanelContent.dateText(modified), tone: .quiet, options), .right)
        } else {
            dateLabel.attributedStringValue = NSAttributedString()
        }
        if let ms = status.decodeMilliseconds {
            let tone = factsRow.greyed ? .quiet : ImageStatus.decodeTone(milliseconds: ms)
            decodeLabel.attributedStringValue = Self.aligned(ProCameraStyle.detail(
                ProCameraStyle.decodeSymbol, Self.decodeText(ms), tone: tone, options), .right)
        } else {
            decodeLabel.attributedStringValue = NSAttributedString()
        }
    }

    private static func decodeText(_ ms: Int) -> String { "decode \(ms) ms" }

    /// A text with its own paragraph style: a label takes the alignment from there, not from `alignment`.
    private static func aligned(_ text: NSAttributedString, _ alignment: NSTextAlignment,
                                _ lineBreak: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreak
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// The date's and the decode time's slots, from their longest values.
    private var detailSlots: (date: CGFloat, decode: CGFloat) {
        if let widths = detailWidths, widths.options == options { return (widths.date, widths.decode) }
        let cellInset: CGFloat = 8
        let date = ceil(ProCameraStyle.detail(ProCameraStyle.dateSymbol, InfoPanelContent.dateText(Self.sampleDate),
                                              tone: .quiet, options).size().width) + cellInset
        let decode = ceil(ProCameraStyle.detail(ProCameraStyle.decodeSymbol, Self.decodeText(99_999), tone: .quiet,
                                                options).size().width) + cellInset
        detailWidths = (date, decode, options)
        return (date, decode)
    }

    /// A date with every field at two digits, for the slot's width.
    private static let sampleDate = DateComponents(calendar: .current, year: 2028, month: 12, day: 28, hour: 23, minute: 58).date
        ?? Date()

    /// The date of the photo is read in the background; the date before stays until it is in, so the slot never empties
    /// for a step.
    private func loadModified() {
        guard showsModified, let url = status.photo else {
            modified = nil
            modifiedURL = nil
            refreshDetail()
            return
        }
        guard modifiedURL != url else { return }
        modifiedURL = url
        Task { [weak self] in
            let date = await Task.detached(priority: .utility) {
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }.value
            guard let self, self.modifiedURL == url else { return }
            self.modified = date
            self.refreshDetail()
        }
    }

    // MARK: Look

    /// The strip's tint at `stats-bar-opacity`, in the dark of the over-media palette; the fill lightens it with white at
    /// `stats-progress-opacity`: no new hue, visible at a glance, over a picture or the window's own background.
    private func applyBackground() {
        tint.layer?.backgroundColor = Chrome.Palette.overMedia.glassTint.withAlphaComponent(barOpacity).cgColor
        fill.layer?.backgroundColor = NSColor(white: 1, alpha: progressOpacity).cgColor
    }

    override func layout() {
        super.layout()
        tint.frame = bounds
        fill.isHidden = !showsProgress || status.progress <= 0
        if !fill.isHidden {
            fill.frame = backingAlignedRect(NSRect(x: 0, y: 0, width: bounds.width * status.progress, height: bounds.height),
                                            options: .alignAllEdgesNearest)
        }
        let rowHeight: CGFloat = 16
        let available = max(0, bounds.width - 2 * Self.inset)
        let showsRight = bounds.width >= Self.narrowest
        let slots = detailSlots
        let detail = showsRight ? slots.date + Self.detailGap + slots.decode : 0
        dateLabel.isHidden = !showsRight
        decodeLabel.isHidden = !showsRight
        rightFactsRow.isHidden = !showsRight
        // Each end gets at most half of what the names leave (one row) or of the bar (two rows); a row that does not fit
        // gives up slots by its priority. The slots carry their own padding (6 a side), which the edges give back.
        let side = max(0, (available - (rows == 1 ? Self.namesRoom : Self.columnGap)) / 2)
        let left = min(factsRow.naturalWidth - 12, showsRight ? side : available)
        let rightFacts = showsRight ? min(rightFactsRow.naturalWidth - 12, max(0, side - detail - Self.columnGap)) : 0
        let rightEnd = showsRight ? detail + (rightFacts > 0 ? Self.columnGap + rightFacts : 0) : 0
        let heights = Self.rowHeights
        let padding = (Self.height(rows: 2) - heights.top - heights.bottom) / 2
        let y = rows == 1 ? (Self.height(rows: 1) - rowHeight) / 2 : padding + heights.bottom
        let height = rows == 1 ? rowHeight : heights.top
        factsRow.frame = backingAlignedRect(NSRect(x: Self.inset - 6, y: y, width: left + 12, height: height),
                                            options: .alignAllEdgesNearest)
        rightFactsRow.frame = backingAlignedRect(NSRect(x: bounds.width - Self.inset - rightEnd - 6, y: y,
                                                        width: rightFacts + 12, height: height),
                                                 options: .alignAllEdgesNearest)
        placeDetail(y: y, height: height)
        if rows == 1 {
            // The names in the middle of the bar, as wide as the room on its narrower side allows (in what is left
            // between the ends when that is too little).
            let middleStart = Self.inset + left + Self.columnGap
            let middleEnd = bounds.width - Self.inset - rightEnd - (showsRight ? Self.columnGap : 0)
            let half = min(bounds.midX - middleStart, middleEnd - bounds.midX)
            let (start, room) = half * 2 >= Self.namesRoom ? (bounds.midX - half, half * 2)
                : (middleStart, middleEnd - middleStart)
            titleLabel.isHidden = room < 80
            folderLabel.isHidden = true
            place(titleLabel, x: start, y: y, width: max(0, room), height: rowHeight)
            return
        }
        // Two rows: the names below, the file's on the left half, the folder's on the right one.
        let half = max(0, (available - Self.columnGap) / 2)
        titleLabel.isHidden = false
        place(titleLabel, x: Self.inset, y: padding, width: showsRight ? half : available, height: heights.bottom)
        folderLabel.isHidden = !showsRight
        place(folderLabel, x: bounds.width - Self.inset - half, y: padding, width: half, height: heights.bottom)
    }

    /// The decode time at the right end, the date before it; a cell's inset is given back at the edge.
    private func placeDetail(y: CGFloat, height: CGFloat) {
        let slots = detailSlots
        let end = bounds.width - Self.inset + 4
        place(decodeLabel, x: end - slots.decode, y: y, width: slots.decode, height: height)
        place(dateLabel, x: end - slots.decode - Self.detailGap - slots.date, y: y, width: slots.date, height: height)
    }

    private func place(_ label: NSTextField, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        label.frame = backingAlignedRect(NSRect(x: x, y: y, width: width, height: height), options: .alignAllEdgesNearest)
    }
}
