import AppKit
import HomeChrome
import LoupeCore

/// The stats strip (spec §10): one line, shown or hidden (M4a spec §3.5: the timings, cache, memory and GPU frame
/// times of the former second line are the info panel's Diagnostics now). It is a separate view from the Metal
/// surface, so a text change never wakes the render loop. Windowed it is a solid strip above the viewer; in full
/// screen the window controller floats it over the top of the viewer and it turns translucent.
///
/// Task 17b (user, Build 2 trial): the background is filled from the left up to the folder position
/// (`stats-progress`), a little more opaque than the bar, and the open folder's name sits in the middle in the stats
/// text's font (`stats-folder-name`), never over the stats text: it truncates in the middle, and goes
/// away when there is no room. They are placed again only when the position, the folder, the line's text or
/// the bar's size changes, never per frame.
@MainActor final class StatsBar: NSView {
    static let compactHeight: CGFloat = 24
    /// The stats text's distance from the bar's edges.
    private static let inset: CGFloat = Chrome.Space.m + Chrome.Space.xxs
    /// Between the folder name and the stats text.
    private static let nameGap: CGFloat = Chrome.Space.xl
    /// Narrower than this the name is not worth showing ("A…Z" and little more).
    private static let nameMinimumWidth: CGFloat = 40
    private let label = NSTextField(labelWithString: "")
    /// The progress fill: a plain layer-backed view behind the labels (a sublayer of the bar's own layer would be
    /// AppKit's to reorder).
    private let fill = NSView()
    private let folderLabel = NSTextField(labelWithString: "")
    /// `(index + 1) / count` of the photo the text speaks of.
    private var progress = 0.0
    /// The text's width, measured once per text change.
    private var textWidth: CGFloat = 0
    /// The folder `folderLabel` names, so a step within it costs no name lookup.
    private var namedFolder: URL?
    /// `stats-progress-opacity`.
    private var progressOpacity = Config().statsProgressOpacity
    /// The name's untruncated size, measured once per name.
    private var nameSize = NSSize.zero
    private var overlay = false

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
        wantsLayer = true
        fill.wantsLayer = true
        addSubview(fill)   // first: under the text
        label.font = Chrome.Text.digits(.label)   // digits do not jitter while zooming
        label.textColor = Chrome.Palette.overMedia.text
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.compactHeight),
        ])
        // Placed by `layout()`: centred and as wide as the room beside the text allows.
        // The stats text's weight, a little larger (user, M3a): the name reads first, but stays a quiet label.
        folderLabel.font = Chrome.Text.font(.body)
        folderLabel.textColor = label.textColor
        folderLabel.alignment = .center
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.isHidden = true
        addSubview(folderLabel)
        applyBackground()
    }

    /// The stats bar keys of `config` (on every reload).
    func apply(_ config: Config) {
        showsProgress = config.statsProgress
        showsFolderName = config.statsFolderName
        if progressOpacity != config.statsProgressOpacity {
            progressOpacity = config.statsProgressOpacity
            applyBackground()
        }
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
        let textEnd = label.stringValue.isEmpty ? 0 : label.frame.minX + min(textWidth, label.frame.width)
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

    /// Full screen floats the bar over the picture, so the background lets it through.
    var isOverlay: Bool {
        get { overlay }
        set {
            overlay = newValue
            applyBackground()
        }
    }

    /// What the session shows right now: a load in progress wins over a stale picture, an error over both.
    func update(from session: ViewerSession) {
        let text: String
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
            index = entry.url == list.current ? list.index : list.files.firstIndex(of: entry.url) ?? list.index
            // The current pair on screen: both names and the range, in reading order (spread spec, «Положение»).
            var name = ArchivePath.shortName(entry.url), companion: Int?
            if entry.url == list.current, session.shownLayout != nil, let pages = session.currentPages,
               let second = pages.second {
                index = pages.first
                companion = second
                fillIndex = second
                name = ArchivePath.shortName(list.files[pages.first]) + " · " + ArchivePath.shortName(list.files[second])
            }
            text = StatsLine.loaded(name: name, index: index, companion: companion, count: list.files.count,
                                    counted: session.folderCounted,
                                    info: info, applyingOrientation: session.appliesOrientation,
                                    transform: session.zoomTarget ?? session.transform,   // a zoom animation's target
                                    decodeMs: entry.timings.fullMs ?? entry.timings.previewMs)
        } else {
            text = ""
        }
        if label.stringValue != text {   // a pan changes nothing here; skip the relayout
            label.stringValue = text
            textWidth = ceil(label.attributedStringValue.size().width)
            needsLayout = true
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

    /// The fill lightens the bar with white at `stats-progress-opacity` (default 0.15), the
    /// same over the picture and on the solid bar: no new hue, visible at a glance.
    private func applyBackground() {
        let tint = Chrome.Palette.overMedia.glassTint
        layer?.backgroundColor = tint.withAlphaComponent(overlay ? tint.alphaComponent : 1).cgColor
        fill.layer?.backgroundColor = NSColor(white: 1, alpha: progressOpacity).cgColor
    }
}
