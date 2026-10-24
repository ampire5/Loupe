import AppKit
import HomeChrome
import LoupeCore

/// The stats line (spec §10): one line on a rounded glass bar, shown or hidden (M4a spec §3.5: the timings, cache,
/// memory and GPU frame times of the former second line are the info panel's Diagnostics now). It is a separate view
/// from the Metal surface, so a text change never wakes the render loop. Windowed it sits under the toolbar and the
/// viewer starts below it; in full screen the window controller floats it over the top of the viewer.
///
/// Task 17b (user, Build 2 trial): the glass is filled from the left up to the folder position (`stats-progress`),
/// darker than the rest of the bar (`stats-progress-opacity`; the rest's own darkness is `stats-bar-opacity`), and
/// the open folder's name sits in the middle in the stats text's font (`stats-folder-name`), never over the stats
/// text: it truncates in the middle, and goes away when there is no room. They are placed again only when the
/// position, the folder, the line's text or the bar's size changes, never per frame.
@MainActor final class StatsBar: NSView {
    static let compactHeight: CGFloat = 30
    /// The gap between the bar and the edges of the window, and between the bar and what is below it.
    static let margin: CGFloat = 10
    /// The stats text's distance from the bar's edges.
    private static let inset: CGFloat = Chrome.Space.m + Chrome.Space.xxs
    /// Between the folder name and the stats text.
    private static let nameGap: CGFloat = Chrome.Space.xl
    /// Narrower than this the name is not worth showing ("A…Z" and little more).
    private static let nameMinimumWidth: CGFloat = 40
    private let glass = ChromeGlass(style: .overMedia(.regular), cornerRadius: compactHeight / 2)
    private let label = NSTextField(labelWithString: "")
    /// The progress fill: a plain layer-backed view on the glass, behind the labels (a sublayer of the glass's own layer
    /// would be AppKit's to reorder).
    private let fill = NSView()
    private let folderLabel = NSTextField(labelWithString: "")
    /// `(index + 1) / count` of the photo the text speaks of.
    private var progress = 0.0
    /// The text's width, measured once per text change.
    private var textWidth: CGFloat = 0
    /// The line as `StatsLine` wrote it, of which the label shows the styled form.
    private var shownText = ""
    /// The folder `folderLabel` names, so a step within it costs no name lookup.
    private var namedFolder: URL?
    /// `stats-progress-opacity`.
    private var progressOpacity = Config().statsProgressOpacity
    /// `stats-bar-opacity`.
    private var barOpacity = Config().statsBarOpacity
    /// The name's untruncated size, measured once per name.
    private var nameSize = NSSize.zero
    /// `stats-icons`, `stats-monochrome`: how the line is styled.
    private var icons = Config().statsIcons
    private var monochrome = Config().statsMonochrome
    /// `stats-bar-clear`.
    private var clear = Config().statsBarClear
    /// `stats-modified`, and the date of the photo on screen (read off the main thread, once per photo).
    private var showsModified = Config().statsModified
    private var modified: Date?
    private var modifiedURL: URL?
    /// The photo whose line is shown, nil for a message.
    private var loadedURL: URL?
    /// `stats-bar-autohide`: the delay, nil when off.
    private var autohideDelay: TimeInterval?
    private var hideTimer: Timer?

    /// `stats-progress`.
    var showsProgress = true {
        didSet { if showsProgress != oldValue { needsLayout = true } }
    }
    /// `stats-folder-name`.
    var showsFolderName = true {
        didSet { if showsFolderName != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        let content = glass.contentView
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.compactHeight / 2   // the fill's left end follows the bar's round end
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        fill.wantsLayer = true
        content.addSubview(fill)   // first: under the text
        label.font = Chrome.Text.digits(.label)   // digits do not jitter while zooming
        label.textColor = Chrome.Palette.overMedia.text
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.inset),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.compactHeight),
        ])
        // Placed by `layout()`: centred and as wide as the room beside the text allows.
        // The stats text's weight, a little larger (user, M3a): the name reads first, but stays a quiet label.
        folderLabel.font = Chrome.Text.font(.body)
        folderLabel.textColor = label.textColor
        folderLabel.alignment = .center
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.isHidden = true
        content.addSubview(folderLabel)
        applyBackground()
    }

    /// The stats bar keys of `config` (on every reload).
    func apply(_ config: Config) {
        showsProgress = config.statsProgress
        showsFolderName = config.statsFolderName
        showsModified = config.statsModified
        let delay = config.statsBarAutohide ? TimeInterval(config.statsBarHideDelayMilliseconds) / 1000 : nil
        if delay != autohideDelay {
            autohideDelay = delay
            reveal()
        }
        if progressOpacity != config.statsProgressOpacity || barOpacity != config.statsBarOpacity
            || clear != config.statsBarClear {
            progressOpacity = config.statsProgressOpacity
            barOpacity = config.statsBarOpacity
            clear = config.statsBarClear
            applyBackground()
        }
        if icons != config.statsIcons || monochrome != config.statsMonochrome {
            icons = config.statsIcons
            monochrome = config.statsMonochrome
            restyle()
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

    private static let dateSeparator = "   "

    /// The date of `url` is read in the background; the line gets it when it is in.
    private func loadModified(of url: URL) {
        guard modifiedURL != url else { return }
        modifiedURL = url
        modified = nil
        Task { [weak self] in
            let date = await Task.detached(priority: .utility) {
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }.value
            guard let self, self.modifiedURL == url, let date else { return }
            self.modified = date
            guard self.showsModified, self.loadedURL == url else { return }
            self.shownText += Self.dateSeparator + InfoPanelContent.dateText(date)
            self.restyle()
        }
    }

    private func restyle() {
        label.attributedStringValue = Self.styled(shownText, icons: icons, monochrome: monochrome)
        textWidth = ceil(label.attributedStringValue.size().width)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fill.isHidden = !showsProgress || progress <= 0
        if !fill.isHidden {
            fill.frame = backingAlignedRect(NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height),
                                            options: .alignAllEdgesNearest)
        }
        placeFolderName()
    }

    /// Centred on the line, as wide as the room between the text's end and the bar's middle allows on both
    /// sides (`StatsLine.folderNameWidth`), hidden without that room.
    private func placeFolderName() {
        let name = folderLabel.stringValue
        let textEnd = shownText.isEmpty ? 0 : label.frame.minX + min(textWidth, label.frame.width)
        let size = nameSize
        guard showsFolderName, !name.isEmpty,
              let width = StatsLine.folderNameWidth(barWidth: Double(bounds.width), textEnd: Double(textEnd),
                                                    nameWidth: Double(ceil(size.width)), gap: Double(Self.nameGap),
                                                    inset: Double(Self.inset), minimum: Double(Self.nameMinimumWidth))
        else {
            folderLabel.isHidden = true
            return
        }
        let w = CGFloat(width), h = ceil(size.height)
        folderLabel.frame = backingAlignedRect(NSRect(x: (bounds.width - w) / 2, y: label.frame.midY - h / 2,
                                                      width: w, height: h),
                                               options: [.alignMinXNearest, .alignMinYNearest, .alignWidthOutward,
                                                         .alignHeightOutward])
        folderLabel.isHidden = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Purely visual: in full screen the bar covers the top of the viewer, and every click, scroll and
    /// pinch there must still reach the viewer underneath (the label never takes events either, since
    /// hit testing starts here).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The line in the style of a camera's screen: the name on top of the lit numbers (position, size), the file's weight
    /// quiet, and the parameters one changes (format, zoom) in the HUD yellow, with hairlines between; a message
    /// (loading, an error) stays plain. A shadow keeps it readable on a clear glass over any picture.
    /// `icons`: a small symbol in front of each field; `monochrome`: the parameters in white too, not the HUD yellow.
    static func styled(_ text: String, icons: Bool = true, monochrome: Bool = false) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        let size: CGFloat = 11.5
        let fields = text.components(separatedBy: "   ")
        let result = NSMutableAttributedString()
        func add(_ piece: NSAttributedString) { result.append(piece) }
        func plain(_ string: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .shadow: shadow])
        }
        guard fields.count > 2 else { return plain(text, .systemFont(ofSize: 12, weight: .semibold), ProCameraStyle.primary) }
        let parameter = monochrome ? ProCameraStyle.primary : ProCameraStyle.yellow
        func icon(_ symbol: String, _ color: NSColor) -> NSAttributedString {
            guard icons, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) else { return NSAttributedString() }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2.5, width: image.size.width, height: image.size.height)
            let result = NSMutableAttributedString(attachment: attachment)
            result.append(plain(" ", ProCameraStyle.font(size), color))
            return result
        }
        for (index, field) in fields.enumerated() {
            if index > 0 { add(plain("   │   ", ProCameraStyle.font(size, .regular), ProCameraStyle.separator)) }
            let piece: NSAttributedString
            let symbol: String, tint: NSColor
            if index == 0 {
                piece = plain(field, .systemFont(ofSize: 12, weight: .semibold), ProCameraStyle.primary)
                symbol = "photo"; tint = ProCameraStyle.primary
            } else if field.contains(" / ") {
                let styled = NSMutableAttributedString(attributedString: ProCameraStyle.position(field, size: size))
                styled.addAttribute(.shadow, value: shadow, range: NSRange(location: 0, length: styled.length))
                piece = styled
                symbol = "square.stack"; tint = ProCameraStyle.primary
            } else if field.contains("×") {
                piece = plain(field, ProCameraStyle.font(size), ProCameraStyle.primary)
                symbol = "arrow.up.left.and.arrow.down.right"; tint = ProCameraStyle.primary
            } else if field.count == 16, field.dropFirst(4).first == "-", field.contains(":") {
                piece = plain(field, ProCameraStyle.font(size), ProCameraStyle.secondary)
                symbol = "calendar"; tint = ProCameraStyle.secondary
            } else if field.hasPrefix("decode") || ["KB", "MB", "GB", "bytes"].contains(where: field.hasSuffix) {
                piece = plain(field, ProCameraStyle.font(size, .medium), ProCameraStyle.secondary)
                symbol = field.hasPrefix("decode") ? "timer" : "externaldrive"; tint = ProCameraStyle.secondary
            } else {
                piece = plain(field, ProCameraStyle.font(size), parameter)
                symbol = field.contains("%") ? "magnifyingglass" : "doc.richtext"; tint = parameter
            }
            add(icon(symbol, tint))
            add(piece)
        }
        return result
    }

    /// What the toast shows for a move: the photo moved to, its folder and place, how far along the folder it is.
    struct Snapshot {
        let title: String
        let folder: String
        let position: String
        let progress: Double
        /// Changes with a move to another photo (or folder), not with a load, a zoom or a pan.
        let navigationKey: String
    }

    /// What the session shows right now: a load in progress wins over a stale picture, an error over both.
    @discardableResult
    func update(from session: ViewerSession) -> Snapshot? {
        var text: String
        loadedURL = nil
        // The position the fill shows: the one the text gives (a pair's last page), the current photo's where the text
        // gives none.
        var index = session.playlist?.index ?? 0
        var fillIndex: Int?
        if let message = session.folderMessage {
            text = message
        } else if let loading = session.loadingName {
            // A pair: its range (spread spec, «Положение»).
            let pages = session.currentPages
            let position = session.playlist.map { (index: pages?.first ?? $0.index, count: $0.files.count) }
            fillIndex = pages?.second
            text = StatsLine.loading(name: loading, position: position, companion: pages?.second,
                                     counted: session.folderCounted)
        } else if let error = session.error {
            text = error
        } else if let entry = session.entry, let info = entry.info, let list = session.playlist {
            // The photo on screen, which is the previous one until the cache answers for a new current photo.
            loadedURL = entry.url
            index = entry.url == list.current ? list.index : list.files.firstIndex(of: entry.url) ?? list.index
            // The current pair on screen: both names and the range, in reading order (spread spec, «Положение»).
            var name = ArchivePath.shortName(entry.url), companion: Int?
            var facts = (info: info, timings: entry.timings)
            if entry.url == list.current, session.shownLayout != nil, let pages = session.currentPages,
               let second = pages.second {
                index = pages.first
                companion = second
                fillIndex = second
                name = ArchivePath.shortName(list.files[pages.first]) + " · " + ArchivePath.shortName(list.files[second])
                // The first page's facts in reading order, whichever page is current.
                if let other = session.shownCompanion, let otherInfo = other.info,
                   StatsLine.factsOfCompanion(current: list.index, first: pages.first,
                                              companionRead: other.failure == nil) {
                    facts = (otherInfo, other.timings)
                }
            }
            text = StatsLine.loaded(name: name, index: index, companion: companion, count: list.files.count,
                                    counted: session.folderCounted,
                                    info: facts.info, applyingOrientation: session.appliesOrientation,
                                    transform: session.zoomTarget ?? session.transform,   // a zoom animation's target
                                    decodeMs: facts.timings.fullMs ?? facts.timings.previewMs)
        } else {
            text = ""
        }
        if showsModified, let url = loadedURL {
            loadModified(of: url)
            if modifiedURL == url, let modified { text += Self.dateSeparator + InfoPanelContent.dateText(modified) }
        }
        if shownText != text {   // a pan changes nothing here; skip the relayout
            shownText = text
            restyle()
        }
        // An uncounted folder's interim `1 / 1` would fill the whole bar.
        let filled = fillIndex ?? index
        let fraction = session.folderCounted ? session.playlist.map { StatsLine.progress(index: filled, count: $0.files.count) } ?? 0 : 0
        if fraction != progress {
            progress = fraction
            needsLayout = true
        }
        let folder = session.playlist?.current.deletingLastPathComponent()
        if folder != namedFolder {
            namedFolder = folder
            folderLabel.stringValue = folder.map { StatsLine.folderName(of: $0, volumeName: Self.volumeName(ofRoot: $0)) } ?? ""
            // The cell's own size: the field's intrinsic width is a few points short of what it draws untruncated.
            nameSize = folderLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude,
                                                                    height: CGFloat.greatestFiniteMagnitude))
                ?? folderLabel.intrinsicContentSize
            needsLayout = true
        }
        guard let list = session.playlist, list.files.indices.contains(session.currentPages?.first ?? list.index) else {
            return nil
        }
        let target = session.currentPages?.first ?? list.index
        let companion = session.currentPages?.second
        return Snapshot(title: ArchivePath.shortName(list.files[target]),
                        folder: StatsLine.folderName(of: list.current.deletingLastPathComponent(),
                                                     volumeName: Self.volumeName(ofRoot: list.current.deletingLastPathComponent())),
                        position: StatsLine.position(index: target, companion: companion, count: list.files.count,
                                                     counted: session.folderCounted),
                        progress: fraction,
                        navigationKey: "\(list.current.deletingLastPathComponent().standardizedFileURL.path)|\(target)|\(companion ?? -1)")
    }

    /// The startup volume's name for "/", which has no name of its own. Nothing is looked up elsewhere: a share's
    /// mount point under /Volumes already carries the share's name, and asking a server that stopped answering
    /// would block the main thread.
    static func volumeName(ofRoot folder: URL) -> String? {
        guard folder.standardizedFileURL.path == "/" else { return nil }
        return startupVolumeName
    }

    private static let startupVolumeName: String? =
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName

    /// The glass is tinted at `stats-bar-opacity`; the fill darkens it with black at `stats-progress-opacity`
    /// (default 0.15): no new hue, visible at a glance, over a picture or the window's own background.
    private func applyBackground() {
        glass.tintOpacity = barOpacity
        glass.setClear(clear)
        fill.layer?.backgroundColor = NSColor(white: 0, alpha: progressOpacity).cgColor
    }
}

extension ChromeGlass {
    /// The glass without the system's frosting (`NSGlassEffectView.Style.clear`): the tint is then all there is between
    /// the picture and the text. The kit keeps its glass view to itself, so it is found among the subviews.
    func setClear(_ clear: Bool) {
        (subviews.first { $0 is NSGlassEffectView } as? NSGlassEffectView)?.style = clear ? .clear : .regular
    }
}

/// The full-screen progress toast (`stats-toast`): on glass at the bottom edge for a move to another photo: its name,
/// its folder and place, and a thin track filled up to the folder position. The glass is tinted at
/// `stats-toast-opacity`. It fades in and out, takes no events, and does nothing between two moves.
@MainActor final class StatsProgressToastView: NSView {
    private let glass = ChromeGlass(style: .overMedia(.regular), cornerRadius: 14)
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var hideTimer: Timer?
    private var fraction = 0.0
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0
        isHidden = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        let content = glass.contentView

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Chrome.Palette.overMedia.text
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        detail.textColor = Chrome.Palette.overMedia.text.withAlphaComponent(0.74)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A clear glass lets the picture through: a soft shadow keeps the text readable on anything.
        for label in [title, detail] {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            label.wantsLayer = true
            label.shadow = shadow
        }
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for bar in [progressTrack, progressFill] {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(bar)
        }
        progressTrack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        progressFill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.82).cgColor
        // A fixed width, so the track does not change its length from one photo name to the next.
        let preferredWidth = widthAnchor.constraint(equalToConstant: 360)
        preferredWidth.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            preferredWidth,
            heightAnchor.constraint(equalToConstant: 62),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            progressTrack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            progressTrack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            progressTrack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            progressTrack.heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ snapshot: StatsBar.Snapshot) {
        guard snapshot.progress > 0 else { return }
        generation += 1
        let currentGeneration = generation
        hideTimer?.invalidate()
        glass.tintOpacity = Settings.shared.config.statsToastOpacity
        glass.setClear(Settings.shared.config.statsToastClear)
        title.stringValue = snapshot.title
        detail.stringValue = "\(snapshot.folder)  ·  \(snapshot.position)"
        fraction = min(1, max(0, snapshot.progress))
        needsLayout = true
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = 1
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(Settings.shared.config.toastDurationMilliseconds) / 1000,
                                         repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(generation: currentGeneration) }
        }
    }

    private func hide(generation currentGeneration: Int) {
        guard generation == currentGeneration else { return }
        hideTimer?.invalidate()
        hideTimer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.generation == currentGeneration else { return }
                self?.isHidden = true
            }
        })
    }

    override func layout() {
        super.layout()
        progressFill.frame = backingAlignedRect(NSRect(x: progressTrack.frame.minX, y: progressTrack.frame.minY,
                                                       width: progressTrack.frame.width * fraction,
                                                       height: progressTrack.frame.height),
                                                options: .alignAllEdgesNearest)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
