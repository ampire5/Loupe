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
/// Slots reserve the width of their usual values. Upscale adds the result dimensions, a zoom indicator and, when
/// freshly computed, its own timing. `ImageStatus` keeps the original facts and the decode time through a load, the exposure while the EXIF is
/// read, and the date stays until the new photo's is in. The photo before's are greyed only when the load is felt. The darkness is `stats-bar-opacity`; the strip is lightened, up to the photo's place in the
/// folder, by `stats-progress-opacity` of white (`stats-progress`). Laid out by frames, not constraints, and only what
/// changed.
@MainActor final class StatsBar: NSView {
    /// The strip's height: two rows of text, or one.
    static func height(rows: Int) -> CGFloat { rows == 1 ? 26 : 42 }
    private static let inset: CGFloat = 12
    private static let columnGap: CGFloat = 16
    /// The room the names keep in the middle of one row before the ends give up slots.
    private static let namesRoom: CGFloat = 240
    /// Keep the filename visible on the single-row bar, even when that means dropping a fact.
    private static let compactNamesRoom: CGFloat = 112
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
    private let nameSeparator = NSTextField(labelWithString: "")
    private let folderLabel = NSTextField(labelWithString: "")
    private static let nameSeparatorWidth: CGFloat = 16
    private var titleWidth: CGFloat = 0
    private var folderWidth: CGFloat = 0
    private var fullZoomWidth: CGFloat = 0
    private var usesCompactZoom = false

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
        factsRow = FactsRowView(style: .init(options: options, hairlines: false, alignment: .left), kinds: Self.leftKinds,
                               priority: [.position, .size, .exposure, .megapixels])
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
        for label in [titleLabel, nameSeparator, folderLabel, dateLabel, decodeLabel] {
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        nameSeparator.attributedStringValue = Self.aligned(ProCameraStyle.name("·", size: 12, weight: .medium,
                                                                                color: ProCameraStyle.secondary), .center)
        nameSeparator.setAccessibilityElement(false)
        nameSeparator.isHidden = true
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
            measureFullZoom()
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
        setPresentationAlpha(1)
        guard let delay = autohideDelay else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideTimer = nil
                self?.setPresentationAlpha(0)
            }
        }
    }

    private func setPresentationAlpha(_ value: CGFloat) {
        guard alphaValue != value else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = value
        } else {
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.15
                $0.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = value
            }
        }
    }

    /// The status to show. A pan or anything else that does not change it costs nothing.
    func update(_ new: ImageStatus) {
        guard new != status else { return }
        let old = status
        status = new
        if new.title != old.title || new.titleTone != old.titleTone || new.folder != old.folder
            || new.note != old.note || new.noteTone != old.noteTone { refreshNames() }
        if new.value(.zoom) != old.value(.zoom) { measureFullZoom() }
        if new.facts != old.facts || new.upscale != old.upscale || new.compactZoom != old.compactZoom
            || new.pending != old.pending || new.stale != old.stale {
            let facts = displayFacts(new)
            factsRow.update(facts, stale: new.stale, pending: new.pending)
            rightFactsRow.update(facts, stale: new.stale, pending: new.pending)
            needsLayout = true
        }
        if new.progress != old.progress { needsLayout = true }
        if new.photo != old.photo { loadModified() }
        if new.decodeMilliseconds != old.decodeMilliseconds || new.upscale?.milliseconds != old.upscale?.milliseconds {
            refreshDetail()
            needsLayout = true
        }
    }

    // MARK: Texts

    private func measureFullZoom() {
        let zoom = status.facts.first { $0.kind == .zoom }
        fullZoomWidth = zoom.map { ceil(ProCameraStyle.text($0, options).size().width) + 8 } ?? 0
    }

    private func displayFacts(_ status: ImageStatus) -> [ImageStatus.Fact] {
        guard usesCompactZoom || status.upscale != nil else { return status.facts }
        return status.facts.map { fact in
            if status.upscale != nil, fact.kind == .size, let size = status.resolutionText {
                return .init(.size, size, tone: fact.tone)
            }
            if fact.kind == .zoom {
                let zoom = status.compactZoom ?? fact.value
                let value = status.upscale.map { "\(zoom) · \($0.indicator)" } ?? zoom
                return .init(.zoom, value, tone: fact.tone)
            }
            return fact
        }
    }

    /// The folder's name, or the news about the folder in its place.
    private var folderText: (text: String, color: NSColor) {
        if let note = status.note {
            return (note, ProCameraStyle.color(status.noteTone, monochrome: options.monochrome))
        }
        return (showsFolderName ? status.folder.map(FolderLabel.name(of:)) ?? "" : "", ProCameraStyle.secondary)
    }

    /// Give each name its own truncation so that a long path cannot consume the filename or a folder notice.
    private func refreshNames() {
        let titleColor = ProCameraStyle.color(status.titleTone, monochrome: options.monochrome)
        let folder = folderText
        titleLabel.attributedStringValue = Self.aligned(
            ProCameraStyle.name(status.title, size: 12, weight: .medium, color: titleColor), .left, .byTruncatingMiddle)
        titleLabel.toolTip = status.title.isEmpty ? nil : status.title
        folderLabel.attributedStringValue = Self.aligned(
            ProCameraStyle.name(folder.text, size: 12, weight: .regular, color: folder.color),
            rows == 1 ? .left : .right, .byTruncatingMiddle)
        folderLabel.toolTip = folder.text.isEmpty ? nil : (status.note ?? status.folder?.path)
        titleWidth = status.title.isEmpty ? 0 : ceil(titleLabel.cell!.cellSize.width)
        folderWidth = folder.text.isEmpty ? 0 : ceil(folderLabel.cell!.cellSize.width)
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
        let timing = NSMutableAttributedString()
        if let ms = status.decodeMilliseconds {
            let tone = factsRow.greyed ? .quiet : ImageStatus.decodeTone(milliseconds: ms)
            timing.append(ProCameraStyle.detail(ProCameraStyle.decodeSymbol, Self.decodeText(ms), tone: tone, options))
        }
        if let ms = status.upscale?.milliseconds {
            let text = "\(timing.length > 0 ? " · " : "")Upscale \(ms) ms"
            timing.append(ProCameraStyle.plain(text, options.size, .medium, ProCameraStyle.secondary, options))
        }
        decodeLabel.attributedStringValue = Self.aligned(timing, .right)
    }

    private static func decodeText(_ ms: Int) -> String { "Decode \(ms) ms" }

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
        let hasZoom = fullZoomWidth > 0
        let hasNames = titleWidth > 0 || folderWidth > 0
        let inlineWidth = titleWidth + Self.nameSeparatorWidth + folderWidth
        let shortNamesRoom = folderWidth > 0 && inlineWidth <= 160 ? inlineWidth : 0
        let noticeRoom = status.note == nil ? 0 : min(Self.namesRoom, folderWidth + 64)
        let namesBudget = rows == 1 && hasNames
            ? min(Self.namesRoom, max(Self.compactNamesRoom, available * 0.24, shortNamesRoom, noticeRoom)) : 0
        let gaps = namesBudget > 0 ? 2 * Self.columnGap : Self.columnGap
        let factsRoom = max(0, available - namesBudget - gaps)
        let side = floor(factsRoom / 2)
        let compactZoom = status.upscale == nil && status.compactZoom != nil && fullZoomWidth > side
        if usesCompactZoom != compactZoom {
            usesCompactZoom = compactZoom
            rightFactsRow.update(displayFacts(status), stale: status.stale, pending: status.pending)
        }

        // Give zoom first claim on the right. Diagnostics yield as the window narrows.
        let zoomWidth = hasZoom ? rightFactsRow.width(for: [.zoom]) - 12 : 0
        let leftTarget = status.upscale == nil ? side : max(side, factsRow.width(for: [.position, .size]) - 12)
        let leftRoom = min(factsRow.naturalWidth - 12, leftTarget, max(0, factsRoom - zoomWidth))
        let rightRoom = max(0, factsRoom - leftRoom)
        let detailRoom = max(0, rightRoom - zoomWidth - Self.columnGap)
        let slots = detailSlots
        let timingWidth = status.upscale?.milliseconds == nil ? slots.decode
            : max(slots.decode, ceil(decodeLabel.attributedStringValue.size().width) + 8)
        let decode = timingWidth <= detailRoom ? timingWidth : 0
        let dateRoom = detailRoom - decode - (decode > 0 ? Self.detailGap : 0)
        let date = showsModified && status.photo != nil && slots.date <= dateRoom ? slots.date : 0
        dateLabel.isHidden = date == 0
        decodeLabel.isHidden = decode == 0
        let detail = date + (date > 0 && decode > 0 ? Self.detailGap : 0) + decode
        let rightFactRoom = max(0, rightRoom - detail - (detail > 0 ? Self.columnGap : 0))
        // The rows reserve a few points around each fact. Return unused slot space to the names.
        let left = max(0, factsRow.fittingWidth(in: leftRoom + 12) - 12)
        let rightFacts = max(0, rightFactsRow.fittingWidth(in: rightFactRoom + 12) - 12)
        let rightEnd = detail + rightFacts + (detail > 0 && rightFacts > 0 ? Self.columnGap : 0)
        let heights = Self.rowHeights
        let padding = (Self.height(rows: 2) - heights.top - heights.bottom) / 2
        let y = rows == 1 ? (Self.height(rows: 1) - rowHeight) / 2 : padding + heights.bottom
        let height = rows == 1 ? rowHeight : heights.top
        factsRow.isHidden = left <= 0
        rightFactsRow.isHidden = rightFacts <= 0
        factsRow.frame = backingAlignedRect(NSRect(x: Self.inset - 6, y: y, width: left + 12, height: height),
                                            options: .alignAllEdgesNearest)
        rightFactsRow.frame = backingAlignedRect(NSRect(x: bounds.width - Self.inset - rightEnd - 6, y: y,
                                                        width: rightFacts + 12, height: height),
                                                 options: .alignAllEdgesNearest)
        placeDetail(y: y, height: height, date: date, decode: decode)
        if rows == 1 {
            let middleStart = Self.inset + (left > 0 ? left + Self.columnGap : 0)
            let middleEnd = bounds.width - Self.inset - rightEnd - (rightEnd > 0 ? Self.columnGap : 0)
            layoutInlineNames(x: middleStart, y: y, room: max(0, middleEnd - middleStart), height: rowHeight)
        } else {
            nameSeparator.isHidden = true
            let namesGap = titleWidth > 0 && folderWidth > 0 ? Self.columnGap : 0
            let folderRoom = titleWidth > 0 ? min(folderWidth, max(0, (available - namesGap) * 0.45)) : available
            let titleRoom = available - folderRoom - namesGap
            titleLabel.isHidden = titleWidth == 0 || titleRoom <= 0
            folderLabel.isHidden = folderWidth == 0 || folderRoom <= 0
            place(titleLabel, x: Self.inset, y: padding, width: max(0, titleRoom), height: heights.bottom)
            place(folderLabel, x: bounds.width - Self.inset - folderRoom, y: padding, width: folderRoom, height: heights.bottom)
        }
    }

    private func layoutInlineNames(x: CGFloat, y: CGFloat, room: CGFloat, height: CGFloat) {
        let separator = Self.nameSeparatorWidth
        let namesFit = titleWidth + separator + folderWidth <= room
        let keepsFolder = folderWidth > 0 && (titleWidth == 0 || status.note != nil || namesFit || room >= 140)
        let gap = keepsFolder && titleWidth > 0 ? separator : 0
        let textRoom = max(0, room - gap)
        // A folder notice needs to survive while the user is waiting. Ordinary folder names yield to the filename.
        let folderLimit = titleWidth == 0 ? textRoom : max(textRoom * (status.note == nil ? 0.4 : 0.6), textRoom - titleWidth)
        let folder = keepsFolder ? min(folderWidth, floor(folderLimit)) : 0
        let title = min(titleWidth, textRoom - folder)
        let groupWidth = title + gap + folder
        let start = min(max(x, bounds.midX - groupWidth / 2), x + max(0, room - groupWidth))
        titleLabel.isHidden = title <= 0
        nameSeparator.isHidden = title <= 0 || folder <= 0
        folderLabel.isHidden = folder <= 0
        place(titleLabel, x: start, y: y, width: title, height: height)
        place(nameSeparator, x: start + title, y: y, width: gap, height: height)
        place(folderLabel, x: start + title + gap, y: y, width: folder, height: height)
    }

    /// The decode time at the right end, the date before it; a cell's inset is given back at the edge.
    private func placeDetail(y: CGFloat, height: CGFloat, date: CGFloat, decode: CGFloat) {
        let end = bounds.width - Self.inset + 4
        place(decodeLabel, x: end - decode, y: y, width: decode, height: height)
        place(dateLabel, x: end - decode - (decode > 0 ? Self.detailGap : 0) - date, y: y, width: date, height: height)
    }

    private func place(_ label: NSTextField, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        label.frame = backingAlignedRect(NSRect(x: x, y: y, width: width, height: height), options: .alignAllEdgesNearest)
    }
}
