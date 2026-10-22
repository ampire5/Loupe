import AppKit
import Filmstrip
import FilmstripModel
import LoupeCore

extension Notification.Name {
    /// Posted on the main thread with the file URL as `object` whenever the thumbnail store reports a status
    /// change (made, or could not be made): the one store handler fans out to every window's strip.
    static let thumbnailChanged = Notification.Name("local.loupe.thumbnailChanged")
    /// Posted after "Clear Thumbnail Cache": every cell's picture is gone.
    static let thumbnailsCleared = Notification.Name("local.loupe.thumbnailsCleared")
}

/// One window's thumbnail strip (spec §4, Photos' filmstrip 2026-10-21): decides when it shows, keeps `FilmstripView`
/// in step with the session's playlist and position, moves the strip under its fixed centre and fills its cells from
/// the `ThumbnailStore`.
///
/// Showing: with `strip-window=beside` (the default) the strip is a band of its own under the picture (the window
/// controller anchors the viewer to its top), shown until `T` or the chevron hides it (`stripBarHidden`). In full
/// screen, and in a window with `overlay`, it floats over the bottom of the picture and is visible while it is
/// pinned (`T`, persisted as `stripPinned`), while the mouse is within the strip's whole height of the window's
/// bottom edge, while its top edge is being dragged, while it moves, or while the cursor is over it; it hides
/// `strip-hide-delay` ms after none of these holds. While the `?` cheat sheet is open (`staysShown`) a strip on screen
/// stays too. `off` never shows it in a window. The chevron over the strip (or at the bottom edge while the strip is
/// hidden) shows while the mouse is over the bottom third of the window and does what `T` does.
///
/// At rest the current file is at the centre, expanded to its photo's proportions. A step to a neighbour (the wheel,
/// the arrows) moves the strip there with a short animation; a jump farther puts it there at once. A two-finger
/// horizontal swipe (`FilmstripScroll`, `strip-scroll-direction`; momentum included) or a mouse drag over the cells
/// moves the strip, every cell narrow: the file reaching the centre becomes current at once as its stretched thumbnail
/// (`ViewerSession.scrub(to:)`). The end of the motion (the momentum's end, a cancel, `FilmstripScroll.restDelay`
/// without scroll events, the mouse's release) settles the strip on the nearest file, expands it and ends the scrub
/// (`endScrub`: the normal plan, the only full decode). A drag resting `ViewerSession.dwellDelay` on one file ends the
/// scrub there too. A click on a cell opens that file and moves the strip to it; it also stops a momentum or a
/// settling under way.
///
/// Pictures are asked for only for the visible cells while the strip is shown, at the pixel size of the cell at
/// rest (the photo's aspect at the cell height, at most `thumb-size`); while the strip moves only for cells that
/// stayed in view `ViewerSession.dwellDelay`, so a fling decodes nothing it passes. A store notification refreshes
/// just that file. The aspects come from `StripAspects` (at most one relayout per 250 ms, none during a drag of the
/// edge); a relayout keeps the file at the centre.
///
/// Dragging the strip's top edge resizes it live (cells relaid each move, pictures asked for again only on release,
/// at the new pixel size) and saves `strip-height` through `Settings`.
@MainActor final class StripController: NSObject {
    static let pinnedKey = "stripPinned"
    static let barHiddenKey = "stripBarHidden"
    /// The chevron's gap to the strip's top, or to the window's bottom while the strip is hidden.
    private static let chevronGap: CGFloat = 6

    let view = FilmstripView()
    private let chevron = NSButton()
    private let session: ViewerSession
    private let store: ThumbnailStore
    private let aspects: StripAspects
    private var heightConstraint: NSLayoutConstraint!
    private var chevronAboveStrip: NSLayoutConstraint?
    private var chevronAtBottom: NSLayoutConstraint?

    private var mode = StripWindowMode.beside
    private var cellHeight: CGFloat = 68
    private var cellMax = 1.5
    private var hideDelay: Duration = .milliseconds(500)
    /// `strip-fade-in` / `strip-fade-out` in seconds; read at each show / hide, so a loupe.conf edit applies at the
    /// next activation.
    private var fadeIn: TimeInterval = 0.15
    private var fadeOut: TimeInterval = 0.25
    private var thumbSize = 512
    private var isFullScreen = false

    private var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pinnedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pinnedKey) }
    }

    private var barHidden: Bool {
        get { UserDefaults.standard.bool(forKey: Self.barHiddenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.barHiddenKey) }
    }

    /// The cursor is in the bottom zone (the band's height above the window's bottom edge, shown or not).
    private var mouseNearBottom = false
    /// The cursor is over the window's bottom third: the chevron shows.
    private var mouseInLowerThird = false
    /// The strip's top edge is being dragged: the pointer is above the band then, and the strip stays.
    private var resizing = false
    /// The cell height when the drag began: what a cut-off drag goes back to, and what tells a drag that
    /// ended where it began.
    private var heightBeforeResize: CGFloat = 0
    private let hoverState = StripHover()
    /// The strip's motion: a trackpad gesture with its momentum (`FilmstripScroll`), or a mouse drag (`dragging`).
    private var scroll = FilmstripScroll()
    private var scrollRest: Task<Void, Never>?
    private var dragging = false
    /// Ends the session's scrub once a drag rests on one file.
    private var dragRest: Task<Void, Never>?
    /// The session scrubs for this strip (from the first `scrub(to:)` to its `endScrub`).
    private var sessionScrubbing = false
    /// The file the strip was last put at rest on.
    private var shownCurrent: Int?
    private(set) var isShown = false
    private var hideTask: Task<Void, Never>?
    /// Set by `close()`: a settings push or a late callback must not touch the closed window's session.
    private var closed = false
    private var container: NSView?
    private var observers: [NSObjectProtocol] = []

    /// The playlist the layout was made for, and each file's index in it.
    private var files: [URL] = []
    private var indices: [URL: Int] = [:]
    /// The picture each file's cell holds for good, with the pixel size it was asked for at: asked for again while
    /// the file differs or the size is off. Pictures in flight, and when each visible file came into view.
    private var given: [Int: (url: URL, maxPixel: Int)] = [:]
    private var loads: [Int: Task<Void, Never>] = [:]
    private var inViewSince: [Int: ContinuousClock.Instant] = [:]
    private var dwellTask: Task<Void, Never>?

    /// The strip took or gave back its own space below the picture (`bar` in a window).
    var onReservesSpaceChange: (() -> Void)?
    /// `isShown` changed (at the start of a fade): the info panel ends above a strip on screen.
    var onShownChange: (() -> Void)?
    /// Whether the viewer's scroll guard says the rest of this precise scroll's gesture does nothing
    /// (`ViewerView.stripScrollIsSpent`, which also stops a glide of the photo): asked only for the strip's own scroll
    /// (`StripRoute.route`).
    var isScrollSpent: (NSEvent) -> Bool = { _ in false }

    /// Whether the viewer must end at the strip's top instead of the window's bottom.
    var reservesSpace: Bool { !isFullScreen && mode == .beside && !barHidden }

    /// The band's height: cells plus padding.
    var bandHeight: CGFloat { cellHeight + 2 * FilmstripView.padding }

    private var isMoving: Bool { scroll.isMoving || dragging }

    init(session: ViewerSession, store: ThumbnailStore) {
        self.session = session
        self.store = store
        aspects = StripAspects(fetch: { [store] urls, applies in await store.aspects(urls, applyingOrientation: applies) })
        super.init()
        aspects.onChange = { [weak self] in self?.aspectsArrived() }
        hoverState.onRest = { [weak self] in self?.rested() }
        view.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = view.heightAnchor.constraint(equalToConstant: bandHeight)
        heightConstraint.isActive = true
        view.alphaValue = 0
        view.isHidden = true
        view.onHover = { [weak self] in self?.hover($0) }
        view.onPress = { [weak self] in self?.pressed($0) }
        view.onDrag = { [weak self] in self?.dragged(by: $0) }
        view.onDragEnd = { [weak self] in self?.dragEnded() }
        view.onVisibleChange = { [weak self] in self?.visibleChanged() }
        view.onStripScroll = { [weak self] in self?.scrolled($0) }
        view.routeScroll = { [weak self] event in
            guard let self else { return .ignore }
            return StripRoute.route(precise: event.hasPreciseScrollingDeltas,
                                    held: LoupeCore.MouseButtons(rawValue: NSEvent.pressedMouseButtons),
                                    folderGesture: Settings.shared.config.folderScrollGesture,
                                    pressed: self.view.isPressed, spent: self.isScrollSpent(event))
        }
        // The middle, back and forward buttons are the viewer's bindings over the strip too (`MouseButtons`, as in
        // `ViewerView`); the left button stays the strip's own (a click, a drag, a resize).
        view.onOtherMouse = { MouseButtons.shared.otherMouse($0, down: $1) }
        view.onOtherMouseDragged = { MouseButtons.shared.moved($0) }
        view.onResize = { [weak self] in self?.relayout() }
        view.onResizeDrag = { [weak self] in self?.resize(toBandHeight: $0) }
        view.onResizeEnd = { [weak self] in self?.endResize(save: $0) }
        view.onBackingChange = { [weak self] in self?.reloadAll() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .thumbnailChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let url = note.object as? URL else { return }
                self?.thumbnailChanged(url)
            }
        })
        observers.append(center.addObserver(forName: .thumbnailsCleared, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadAll() }
        })
        apply(Settings.shared.config)
        Settings.shared.addStrip(self)
    }

    /// Mouse moves anywhere in `container` (the window's content view) tell whether the cursor is near the
    /// bottom edge; the chevron goes into it, over the strip.
    func attach(to container: NSView) {
        self.container = container
        container.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                                        .activeInKeyWindow, .inVisibleRect],
                                                 owner: self))
        chevron.isBordered = false
        chevron.title = ""
        chevron.imagePosition = .imageOnly
        chevron.imageScaling = .scaleProportionallyUpOrDown
        chevron.contentTintColor = NSColor(white: 1, alpha: 0.75)
        chevron.target = self
        chevron.action = #selector(chevronClicked)
        chevron.alphaValue = 0
        chevron.isHidden = true
        chevron.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chevron, positioned: .above, relativeTo: view)
        let above = chevron.bottomAnchor.constraint(equalTo: view.topAnchor, constant: -Self.chevronGap)
        let bottom = chevron.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.chevronGap)
        chevronAboveStrip = above
        chevronAtBottom = bottom
        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 18),
            chevron.heightAnchor.constraint(equalToConstant: 9),
        ])
        updateChevron()
    }

    /// The window closes: no timers, no more notifications.
    func close() {
        closed = true
        resizing = false   // a drag cut off by the close has nothing left to restore or save
        dragging = false
        sessionScrubbing = false   // the session closes too
        dragRest?.cancel()
        scroll.takeOver()   // nothing to commit: the session closes too
        scrollRest?.cancel()
        dwellTask?.cancel()
        hideTask?.cancel()
        hoverState.cancel()
        aspects.close()
        loads.values.forEach { $0.cancel() }
        loads = [:]
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let container {
            for area in container.trackingAreas where area.owner === self { container.removeTrackingArea(area) }
        }
    }

    // MARK: Settings and modes

    /// The strip keys of `config` (pushed by `Settings` on every reload).
    func apply(_ config: Config) {
        guard !closed else { return }
        let height = CGFloat(config.stripHeight)
        let reserved = reservesSpace
        mode = config.stripWindow
        hideDelay = .milliseconds(config.stripHideDelayMilliseconds)
        fadeIn = Double(config.stripFadeInMilliseconds) / 1000
        fadeOut = Double(config.stripFadeOutMilliseconds) / 1000
        view.cornerRadius = CGFloat(config.stripCornerRadius)   // a no-op while unchanged
        scroll.direction = config.stripScrollDirection
        if config.stripCellMax != cellMax {
            cellMax = config.stripCellMax
            relayout()
        }
        if config.thumbSize != thumbSize {
            thumbSize = config.thumbSize
            reloadAll()   // other pixel sizes
        }
        if config.exifOrientation != aspects.appliesOrientation {
            // Thumbnails are stored turned: with the key off the cells turn back to the stored layout, at the stored aspect.
            aspects.setAppliesOrientation(config.exifOrientation)
            DebugLog.log("strip exif-orientation \(config.exifOrientation ? "yes" : "no")")
            relayout()
            reloadAll()   // the cells' pictures are turned the other way
        }
        if height != cellHeight {
            setCellHeight(height)
            reloadAll()   // a new pixel size for every cell
        }
        if reservesSpace != reserved { onReservesSpaceChange?() }
        update()
    }

    private func setCellHeight(_ height: CGFloat) {
        cellHeight = height
        heightConstraint.constant = bandHeight
        relayout()
    }

    /// A drag of the top edge: the height follows the pointer within the allowed range. Layout runs now, so the
    /// strip (and, in `bar` mode, the viewer above it) is at the new height before the next drag event.
    private func resize(toBandHeight band: CGFloat) {
        guard !closed else { return }
        let height = CGFloat(Config.clampedStripHeight(Double(band - 2 * FilmstripView.padding)))
        if !resizing {
            resizing = true
            aspects.paused = true
            heightBeforeResize = cellHeight
            update()
        }
        guard height != cellHeight else { return }
        setCellHeight(height)
        container?.layoutSubtreeIfNeeded()
    }

    /// Release (`save`): the pictures are asked for at the new pixel size, and the height is saved (the file's
    /// `strip-height`, then every strip). A drag that ended where it began changes and saves nothing, and a
    /// cut-off one (`save` false) goes back to where it began without saving.
    private func endResize(save: Bool) {
        guard resizing else { return }
        resizing = false
        DebugLog.log("strip resize \(save ? "end" : "cancelled"): \(Int(heightBeforeResize)) -> \(Int(cellHeight))")
        if !save, cellHeight != heightBeforeResize {
            setCellHeight(heightBeforeResize)
            container?.layoutSubtreeIfNeeded()
        }
        if save, cellHeight != heightBeforeResize {
            reloadAll()
            Settings.shared.setStripHeight(Int(cellHeight))
        } else {
            loadVisible()   // the cells the drag skipped
        }
        aspects.paused = false   // what arrived during the drag
        update()
    }

    func setFullScreen(_ on: Bool) {
        guard on != isFullScreen else { return }
        let reserved = reservesSpace
        view.cancelResize()
        endMotion()
        isFullScreen = on
        mouseNearBottom = false
        if reservesSpace != reserved { onReservesSpaceChange?() }
        update()
    }

    /// `T`, View › Thumbnail Strip and the chevron: a bar hides or comes back, an overlay is pinned or let go.
    func togglePin() {
        if placement == .beside {
            barHidden.toggle()
            DebugLog.log("strip bar \(barHidden ? "hidden" : "shown")")
            onReservesSpaceChange?()
        } else {
            pinned.toggle()
            DebugLog.log("strip \(pinned ? "pinned" : "unpinned")")
        }
        // Let go with nothing else holding it: it goes now, the user asked for that.
        update(hideAtOnce: true)
    }

    /// Whether `T` holds the strip on screen: a bar not hidden, a pinned overlay.
    var isPinned: Bool { placement == .beside ? !barHidden : pinned }

    @objc private func chevronClicked() { togglePin() }

    /// Set while the cheat sheet is open: a strip on screen does not hide under it (the sheet's Mouse & Trackpad column
    /// talks about it), and a hidden one does not come up for it. Cleared, the usual delay starts.
    var staysShown = false {
        didSet { if staysShown != oldValue { update() } }
    }

    // MARK: Showing

    private var placement: StripWindowMode { isFullScreen ? .over : mode }

    /// Shows the strip when something holds it, otherwise hides it after the delay (at once for `hideAtOnce`).
    private func update(hideAtOnce: Bool = false) {
        guard !closed else { return }
        view.isOverlay = placement == .over
        let holds: Bool
        switch placement {
        case .hidden: holds = false
        case .beside: holds = !barHidden || resizing
        case .over:
            holds = pinned || mouseNearBottom || hoverState.file != nil || resizing || isMoving
                || (staysShown && isShown)
        }
        if holds {
            hideTask?.cancel()
            hideTask = nil
            show()
        } else if placement != .over || hideAtOnce {
            hideTask?.cancel()
            hideTask = nil
            hide()
        } else if isShown, hideTask == nil {
            let delay = hideDelay
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.hideTask = nil
                self.hide()
            }
        }
        updateChevron()
    }

    private func show() {
        guard !isShown else { return }
        isShown = true
        view.acceptsMouse = true
        view.isHidden = false
        DebugLog.log("strip show")
        if fadeIn > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeIn
                view.animator().alphaValue = 1
            }
        } else {
            view.layer?.removeAllAnimations()   // a hide fade still running must not keep fading it out
            view.alphaValue = 1
        }
        relayout()
        loadVisible()
        sendVisible()
        onShownChange?()
    }

    private func hide() {
        guard isShown else { return }
        isShown = false
        view.acceptsMouse = false   // clicks reach the picture while it fades
        dropHover()
        DebugLog.log("strip hide")
        // Hidden once the fade ends (or at once without one): its tracking areas stop too, so no arrow cursor
        // over an invisible strip.
        let finishHide = { [weak self] in
            guard let self, !self.isShown else { return }
            self.view.isHidden = true
        }
        if fadeOut > 0 {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = fadeOut
                view.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { finishHide() }
            })
        } else {
            view.layer?.removeAllAnimations()   // a show fade still running must not keep fading it in
            view.alphaValue = 0
            finishHide()
        }
        sendVisible()
        onShownChange?()
    }

    /// The chevron: over the strip while it is on screen, at the bottom edge while not, down or up as `T` would go;
    /// shown while the mouse is over the window's bottom third, never with `strip-window=hidden` in a window.
    private func updateChevron() {
        guard container != nil else { return }
        let wanted = mouseInLowerThird && placement != .hidden
        let symbol = isShown ? "chevron.down" : "chevron.up"
        if chevron.image?.accessibilityDescription != symbol {
            chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        }
        chevron.toolTip = isShown ? "Hide the thumbnails (T)" : "Show the thumbnails (T)"
        if isShown {
            chevronAtBottom?.isActive = false
            chevronAboveStrip?.isActive = true
        } else {
            chevronAboveStrip?.isActive = false
            chevronAtBottom?.isActive = true
        }
        guard wanted != (chevron.alphaValue > 0 && !chevron.isHidden) else { return }
        if wanted { chevron.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = wanted ? fadeIn : fadeOut
            chevron.animator().alphaValue = wanted ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !(self.mouseInLowerThird && self.placement != .hidden) else { return }
                self.chevron.isHidden = true
            }
        })
    }

    /// The store makes the visible cells' thumbnails first; none while the strip is hidden.
    private func sendVisible() {
        guard !closed else { return }
        session.stripVisibleFiles = isShown ? view.visibleItems : []
    }

    // MARK: Mouse near the bottom (tracking area owner)

    // Not a responder: the tracking area sends these by their NSResponder selectors, hence the explicit names.

    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) {
        guard let container else { return }
        if isShown { view.trackOutside(event) }
        let p = container.convert(event.locationInWindow, from: nil)
        let inside = container.bounds.contains(p)
        let near = inside && p.y - container.bounds.minY <= bandHeight
        let lower = inside && p.y - container.bounds.minY <= container.bounds.height / 3
        if lower != mouseInLowerThird {
            mouseInLowerThird = lower
            updateChevron()
        }
        guard near != mouseNearBottom else { return }
        mouseNearBottom = near
        update()
    }

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        if !dragging { hover(nil) }   // a drag keeps its hover
        if mouseInLowerThird {
            mouseInLowerThird = false
            updateChevron()
        }
        guard mouseNearBottom else { return }
        mouseNearBottom = false
        update()
    }

    /// The window is no longer key: mouse moves stop arriving, so what they said is stale.
    func windowDidResignKey() {
        view.cancelResize()
        endMotion()
        mouseNearBottom = false
        mouseInLowerThird = false
        hover(nil)
        updateChevron()
    }

    // MARK: Session

    /// Called on every session change (every frame of a pan), so it only compares.
    func sessionDidChange() {
        guard let list = session.playlist else { return }
        if list.files != files {
            playlistChanged(list.files, current: list.index)
            return
        }
        // While the strip moves, the files it reaches are the session's current ones already.
        guard list.index != shownCurrent, !isMoving else { return }
        let step = shownCurrent.map { abs($0 - list.index) == 1 } ?? false
        rest(on: list.index, animated: step)
    }

    /// Another playlist. The session ended its scrub with the old one. Files still in it keep their pictures at their
    /// new places (a listing that arrives in parts, `FolderWatcher`); a motion whose centre file is still there goes
    /// on from it, anything else (another folder) ends with the old list and the strip rests on the current file.
    private func playlistChanged(_ list: [URL], current: Int) {
        let map = FilmstripItems.indexMap(from: files, to: list)
        let centre = scroll.offset.flatMap(view.layout.item(atBase:)).flatMap { map[$0] }
        let keepsMotion = isMoving && centre != nil
        if !keepsMotion {
            view.cancelPress()
            dragRest?.cancel()
            dragging = false
            scroll.takeOver()
            scroll.settle()
            scrollRest?.cancel()
            scrollRest = nil
        }
        sessionScrubbing = false
        files = list
        indices = Dictionary(list.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        aspects.setPlaylist(files)
        // The label showed a file of the old playlist (the interim one-file list replaced by the listing): the
        // hover comes back for the new file under the cursor on the next move.
        hover(nil)
        loads.values.forEach { $0.cancel() }
        loads = [:]
        given = Dictionary(uniqueKeysWithValues: given.compactMap { file, held in map[file].map { ($0, held) } })
        inViewSince = Dictionary(uniqueKeysWithValues: inViewSince.compactMap { file, since in map[file].map { ($0, since) } })
        view.remap(map)
        shownCurrent = shownCurrent.flatMap { map[$0] }
        relayout(keeping: keepsMotion ? centre : nil)
        if !keepsMotion { rest(on: current, animated: false) }
    }

    /// The strip at rest on `file`: at the centre, expanded.
    private func rest(on file: Int, animated: Bool) {
        guard files.indices.contains(file) else { return }
        shownCurrent = file
        view.show(offset: view.layout.centre(of: file), current: file, expansion: 1, animated: animated)
        view.refreshHover()
    }

    /// The strip moving: at the offset of the motion, every cell narrow; `animated` for the first move, so the
    /// expanded cell narrows rather than jumps.
    private func drawMotion(animated: Bool) {
        guard let offset = scroll.offset else { return }
        let file = view.layout.item(atBase: offset) ?? 0
        view.show(offset: offset, current: file, expansion: 0, animated: animated)
    }

    /// A layout for the view's width, the playlist and the aspects. The file at the centre stays there: the moving
    /// strip's (`keeping`, when the playlist changed under it), or the current one.
    private func relayout(animated: Bool = false, keeping: Int? = nil) {
        let layout = FilmstripLayout(itemCount: files.count, length: Double(view.bounds.width),
                                     thickness: Double(cellHeight), maxAspect: cellMax, aspects: aspects.aspects)
        guard layout != view.layout || keeping != nil else { return }
        let centre = keeping ?? scroll.offset.flatMap(view.layout.item(atBase:))
        view.setLayout(layout, animated: animated)
        if let centre {
            scroll.layoutChanged(keeping: centre, layout: layout)
            drawMotion(animated: false)
        } else if let current = shownCurrent ?? session.playlist?.index {
            rest(on: current, animated: animated)
        }
        if let file = hoverState.file, file >= files.count { hover(nil) }
        loadVisible()
    }

    // MARK: Aspects

    /// New aspects narrowed cells, or gave the current one its shape: it grows to it.
    private func aspectsArrived() {
        DebugLog.log("strip aspects: \(aspects.knownCount) / \(files.count) known")
        relayout(animated: !isMoving)
        view.refreshHover()
    }

    // MARK: Cell pictures

    /// The pixel size of a file's picture on its long side: the cell at rest covered by the photo, the cell height at
    /// its aspect (3:2 while unknown; a portrait photo's height), at most `thumb-size` (the thumbnail has no more).
    private func maxPixel(forFile file: Int) -> Int {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let known = file < aspects.aspects.count ? aspects.aspects[file] : nil
        let aspect = max(1, known ?? FilmstripLayout.unknownCurrentAspect)
        return min(thumbSize, Int((Double(cellHeight) * aspect * Double(scale)).rounded()))
    }

    /// Whether a file's cell holds its picture at a size good enough now: an upscale of more than 10 % or a picture
    /// over twice the size is worth a new one.
    private func isSettled(_ file: Int) -> Bool {
        guard let held = given[file], held.url == files[file] else { return false }
        let needed = maxPixel(forFile: file)
        return Double(needed) <= Double(held.maxPixel) * 1.1 && needed * 2 >= held.maxPixel
    }

    /// The visible files changed: those that came into view start their dwell; at rest their pictures are asked
    /// for at once.
    private func visibleChanged() {
        let visible = view.visibleItems, now = ContinuousClock.now
        let set = Set(visible)
        inViewSince = inViewSince.filter { set.contains($0.key) }
        for file in visible where inViewSince[file] == nil { inViewSince[file] = now }
        loadVisible()
        if isMoving {
            armDwell()
        } else {
            sendVisible()
        }
    }

    /// While the strip moves: wakes once the newest cells have dwelt, asks for their pictures and tells the store.
    private func armDwell() {
        guard dwellTask == nil else { return }
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: ViewerSession.dwellDelay)
            guard !Task.isCancelled, let self, !self.closed else { return }
            self.dwellTask = nil
            self.loadVisible()
            self.sendVisible()
            if self.isMoving, self.view.visibleItems.contains(where: { self.loads[$0] == nil && !self.isSettled($0) }) {
                self.armDwell()
            }
        }
    }

    /// Asks for every visible cell not holding its file's picture yet (while the strip moves, only those that have
    /// dwelt in view); only while shown (a hidden strip costs nothing) and not while the edge is dragged (the release
    /// asks once, for the final pixel size). Pictures far from the window are dropped.
    private func loadVisible() {
        guard isShown, !resizing, !closed else { return }
        let moving = isMoving, now = ContinuousClock.now
        for file in view.visibleItems where files.indices.contains(file) && loads[file] == nil && !isSettled(file) {
            if moving, let since = inViewSince[file], now - since < ViewerSession.dwellDelay { continue }
            load(file)
        }
        forgetFar()
    }

    /// Keeps the pictures of a few hundred files around the window: the rest are asked for again when they return.
    private func forgetFar() {
        guard given.count > 400, let centre = view.visibleItems.first else { return }
        let reach = view.visibleItems.count + 150
        for file in Array(given.keys) where abs(file - centre) > reach {
            given[file] = nil
            loads[file]?.cancel()
            loads[file] = nil
            view.forget(file)
        }
    }

    private func load(_ file: Int) {
        let url = files[file], store = self.store, maxPixel = maxPixel(forFile: file)
        let applies = aspects.appliesOrientation
        loads[file] = Task { [weak self] in
            let image = await store.cell(url, maxPixel: maxPixel, applyingOrientation: applies)
            let status = image == nil ? await store.status(url) : .ready
            guard let self, !Task.isCancelled else { return }
            self.loads[file] = nil
            // Another playlist meanwhile: this file is someone else's cell now.
            guard self.files.indices.contains(file), self.files[file] == url else { return }
            if let image {
                self.view.setImage(image, forItem: file)
                self.aspects.cellPictureArrived(url)
            } else if status == .unavailable {
                self.view.setUnavailable(forItem: file)
            } else {
                self.view.setImage(nil, forItem: file)
            }
            self.given[file] = (url, maxPixel)
            // An aspect that arrived meanwhile changed the size this file needs.
            if !self.isSettled(file) { self.loadVisible() }
        }
    }

    /// New pixel size (strip height, backing scale) or a cleared cache: every cell again, pictures kept on
    /// screen until their replacements arrive.
    private func reloadAll() {
        loads.values.forEach { $0.cancel() }
        loads = [:]
        given = [:]
        loadVisible()
    }

    private func thumbnailChanged(_ url: URL) {
        aspects.thumbnailArrived(url)
        guard let file = indices[url] else { return }
        given[file] = nil
        loads[file]?.cancel()
        loads[file] = nil
        loadVisible()
    }

    // MARK: Motion

    /// The file the strip brings to the centre becomes current, as its stretched thumbnail.
    private func scrub(to file: Int) {
        if !sessionScrubbing { DebugLog.log("strip scrub from \((session.playlist?.index ?? 0) + 1)") }
        sessionScrubbing = true
        session.scrub(to: file)
    }

    /// The session's scrub, if this strip has one on, ends: the normal plan for the file it rests on.
    private func endSessionScrub() {
        guard sessionScrubbing else { return }
        sessionScrubbing = false
        DebugLog.log("strip scrub end on \((session.playlist?.index ?? 0) + 1)")
        if !closed { session.endScrub() }
    }

    /// The motion is over (momentum end, cancel, rest, release): the strip settles on the nearest file and expands
    /// it, and the scrub ends there.
    private func finishMotion() {
        scrollRest?.cancel()
        scrollRest = nil
        dragRest?.cancel()
        dragRest = nil
        dwellTask?.cancel()
        dwellTask = nil
        dragging = false
        if let settled = scroll.settled(layout: view.layout), !closed {
            if settled.item != session.playlist?.index { scrub(to: settled.item) }
            shownCurrent = settled.item
            view.show(offset: settled.offset, current: settled.item, expansion: 1, animated: true)
        }
        scroll.settle()
        endSessionScrub()
        loadVisible()
        sendVisible()
        view.refreshHover()
        update()
    }

    /// The window lost key or changes full screen, or the playlist changed: a motion under way finishes now.
    private func endMotion() {
        view.cancelPress()   // a drag ends as at a release
        guard scroll.offset != nil || sessionScrubbing else { return }
        _ = scroll.end()
        finishMotion()
    }

    /// A click on a cell: that file opens, and the strip moves to it; a momentum or a settling under way stops.
    private func pressed(_ file: Int) {
        guard !closed, files.indices.contains(file) else { return }
        scroll.takeOver()
        scrollRest?.cancel()
        scrollRest = nil
        DebugLog.log("strip click on \(file + 1)")
        shownCurrent = file   // the session's change below is this move
        if session.playlist?.index != file {
            sessionScrubbing = true
            session.scrub(to: file)
        }
        endSessionScrub()
        view.show(offset: view.layout.centre(of: file), current: file, expansion: 1, animated: true)
        scroll.settle()
        loadVisible()
        sendVisible()
        update()
    }

    /// A mouse drag across the cells moves the strip with the cursor; it takes over a trackpad motion under way.
    private func dragged(by dx: CGFloat) {
        guard !closed, let current = session.playlist?.index else { return }
        let first = !dragging
        if first {
            dragging = true
            scroll.takeOver()
            scrollRest?.cancel()
            scrollRest = nil
            dropHover()
        }
        let outcome = scroll.drag(by: Double(dx), layout: view.layout, current: current)
        if let file = outcome.item {
            scrub(to: file)
            armDragRest()
        }
        drawMotion(animated: first)
        if first { update() }
    }

    /// A drag resting `dwellDelay` on one file ends the session's scrub there (the sharp photo); the next file it
    /// reaches scrubs again.
    private func armDragRest() {
        dragRest?.cancel()
        dragRest = Task { [weak self] in
            try? await Task.sleep(for: ViewerSession.dwellDelay)
            guard !Task.isCancelled, let self, self.dragging else { return }
            self.dragRest = nil
            self.endSessionScrub()
        }
    }

    private func dragEnded() {
        guard dragging else { return }
        finishMotion()
    }

    // MARK: Trackpad scroll

    /// A precise scroll over the strip that is the strip's (`FilmstripView.onStripScroll`): the strip moves, a new
    /// file at the centre scrubs to it; the end of the momentum or a cancelled gesture finishes at once, otherwise
    /// the rest timer does. Not during a press: the press owns the strip.
    private func scrolled(_ event: NSEvent) {
        guard !closed, !view.isPressed, let current = session.playlist?.index else { return }
        let wasMoving = scroll.isMoving
        let fingers = FingerDirection.sign(invertedFromDevice: event.isDirectionInvertedFromDevice)
        let outcome = scroll.event(fingerDelta: fingers * event.scrollingDeltaX, crossDelta: event.scrollingDeltaY,
                                   phase: ScrollPhase(rawValue: event.phase.rawValue),
                                   momentum: ScrollPhase(rawValue: event.momentumPhase.rawValue),
                                   layout: view.layout, current: current, now: event.timestamp)
        if let file = outcome.item { scrub(to: file) }
        if outcome.commit {
            drawMotion(animated: false)
            finishMotion()
            return
        }
        guard scroll.isMoving else { return }
        if !wasMoving { dropHover() }
        drawMotion(animated: !wasMoving)
        armScrollRest()
        if !wasMoving { update() }
    }

    /// One timer for the rest: armed for the deadline it finds, and on waking it finishes or, when events put the
    /// deadline off meanwhile, sleeps again until the new one. Event timestamps and `systemUptime` share a clock.
    private func armScrollRest() {
        guard scrollRest == nil, let deadline = scroll.restDeadline else { return }
        scrollRest = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            guard !Task.isCancelled, let self else { return }
            self.scrollRest = nil
            if self.scroll.rested(now: ProcessInfo.processInfo.systemUptime) {
                self.finishMotion()
            } else if self.scroll.isMoving {
                self.armScrollRest()
            }
        }
    }

    // MARK: Hover

    private func hover(_ file: Int?) {
        // Moves seen while fading out (or before a show) must not leave a label to resurface on the next show.
        if file != nil, !isShown || isMoving {
            view.endHover()
            return
        }
        guard let file, files.indices.contains(file) else {
            if hoverState.drop() {
                view.endHover()
                update()
            }
            return
        }
        let labelled = hoverState.restedFile != nil
        guard hoverState.set(file) else { return }
        // Once a label is up it follows the cursor at once; the first waits for the rest.
        if labelled { view.showLabel(item: file, text: label(file)) }
        update()
    }

    /// "N / M · name" of the file under the cursor.
    private func label(_ file: Int) -> String {
        "\(file + 1) / \(view.layout.itemCount) · \(ArchivePath.shortName(files[file]))"
    }

    private func dropHover() {
        hoverState.drop()
        view.endHover()
    }

    /// The cursor stayed on one file: its label goes up.
    private func rested() {
        guard let file = hoverState.restedFile, files.indices.contains(file), isShown else { return }
        view.showLabel(item: file, text: label(file))
    }
}
