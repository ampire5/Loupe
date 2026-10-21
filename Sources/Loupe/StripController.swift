import AppKit
import LoupeCore

extension Notification.Name {
    /// Posted on the main thread with the file URL as `object` whenever the thumbnail store reports a status
    /// change (made, or could not be made): the one store handler fans out to every window's strip.
    static let thumbnailChanged = Notification.Name("local.loupe.thumbnailChanged")
    /// Posted after "Clear Thumbnail Cache": every cell's picture is gone.
    static let thumbnailsCleared = Notification.Name("local.loupe.thumbnailsCleared")
}

/// One window's thumbnail strip (spec §4): decides when it shows, keeps `StripView` in step with the session's
/// playlist and position, and fills its cells from the `ThumbnailStore`.
///
/// Showing: in full screen, and in a window with `strip-window=overlay`, the strip floats over the bottom of the
/// picture and is visible while it is pinned (`T`, persisted as `stripPinned`), while the mouse is within the
/// strip's whole height (+ 8 pt, which is the band) of the window's bottom edge, while its top edge is being
/// dragged, or while the cursor is over the strip; it hides
/// `strip-hide-delay` ms after none of these holds. While the `?` cheat sheet is open (`staysShown`) a strip on screen
/// stays too. `bar` keeps it always visible under the picture (the window
/// controller anchors the viewer to its top); `off` never shows it in a window.
///
/// Pictures are asked for only for the cells of the current layout while the strip is shown, at the cell's
/// pixel size; a store notification refreshes just the cells of that file.
///
/// Hover magnifies the cells Dock-style (`StripMagnifier`, `strip-magnify`, `strip-magnify-reach`, the height capped
/// at `strip-magnify-limit` of the viewer's). Once the file under the cursor has stayed the same for 100 ms, the magnified cells are
/// asked for again at their magnified pixel size with the cursor on that file (at most `thumb-size`), the hovered cell showing that file rather than its range's middle one; while
/// the cursor moves, the cells keep what they hold (scaled), so a sweep across the strip decodes nothing.
///
/// Cell shapes follow `strip-aspect`: `native` lays each cell out at its photo's proportions, which
/// `StripAspects` gathers from the store (at most one relayout per 250 ms, none during a drag of the edge). A
/// sampled strip keeps its cell count while the aspects stream in (`StripLayout.preferredCount`).
///
/// A press on the cells scrubs (spec §4.3, §5.3): the file under the cursor becomes current at once as its
/// stretched thumbnail (`ViewerSession.scrub(to:)`), and the release, or the cursor resting `ViewerSession.dwellDelay`
/// on one file, ends the scrub (`endScrub`: the normal plan for that file); the next file the drag reaches scrubs
/// again. A click is a scrub of one file. The strip stays while the press lasts.
///
/// A two-finger horizontal swipe over the strip scrubs too (`StripScroll`, Task 20): by default fingers left go to the
/// next files (`strip-scroll-direction`), a cell's width of travel per cell, momentum included; the end of the
/// momentum, a cancelled gesture or `StripScroll.restDelay` without scroll events commits (`endScrub`). A vertical
/// swipe over the strip does nothing; the wheel and a held-button scroll go on to the viewer.
///
/// Dragging the strip's top edge resizes it live (cells relaid each move, pictures asked for again only on release,
/// at the new pixel size) and saves `strip-height` through `Settings`.
@MainActor final class StripController: NSObject {
    static let pinnedKey = "stripPinned"

    let view = StripView()
    private let session: ViewerSession
    private let store: ThumbnailStore
    private let aspects: StripAspects
    private var heightConstraint: NSLayoutConstraint!

    private var mode = StripWindowMode.overlay
    private var cellHeight: CGFloat = 64
    private var hideDelay: Duration = .milliseconds(500)
    /// `strip-fade-in` / `strip-fade-out` in seconds; read at each show / hide, so a loupe.conf edit applies at the
    /// next activation.
    private var fadeIn: TimeInterval = 0.15
    private var fadeOut: TimeInterval = 0.25
    private var magnify = 2.0
    private var reach = 2.0
    private var magnifyLimit = 15.0
    private var thumbSize = 512
    private var isFullScreen = false

    private var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pinnedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pinnedKey) }
    }

    /// The cursor is in the bottom zone (the band's height above the window's bottom edge, shown or not).
    private var mouseNearBottom = false
    /// The strip's top edge is being dragged: the pointer is above the band then, and the strip stays.
    private var resizing = false
    /// The cell height when the drag began: what a cut-off drag goes back to, and what tells a drag that
    /// ended where it began.
    private var heightBeforeResize: CGFloat = 0
    private let hoverState = StripHover()
    /// A press on the cells is scrubbing (from the view's `onScrub` to its `onScrubEnd`).
    private var scrubbing = false
    /// Ends the scrub once the cursor rests on one file.
    private var scrubRest: Task<Void, Never>?
    /// Trackpad scrolling over the strip and its scrub, which `scrollRest` commits once `StripScroll.restDeadline`
    /// passes: one timer, re-armed when it wakes before a deadline that later events put off.
    private var scroll = StripScroll()
    private var scrollRest: Task<Void, Never>?
    private(set) var isShown = false
    private var hideTask: Task<Void, Never>?
    /// Set by `close()`: a settings push or a late callback must not touch the closed window's session.
    private var closed = false
    private var container: NSView?
    private var observers: [NSObjectProtocol] = []

    /// The playlist the layout was made for.
    private var files: [URL] = []
    /// The playlist and aspect mode of the view's layout: a sampled strip keeps its cell count only for them.
    private var laidFiles: [URL] = []
    private var laidMode = StripAspect.native
    /// The file each cell shows, and the file whose picture (or placeholder) the cell holds for good with the
    /// pixel size it was asked for at: a cell is asked for again while the files differ or the size is off.
    private var cellFiles: [URL] = []
    private var settled: [(url: URL, maxPixel: Int)?] = []
    private var loads: [Int: Task<Void, Never>] = [:]

    /// The strip took or gave back its own space below the picture (`bar` in a window).
    var onReservesSpaceChange: (() -> Void)?
    /// `isShown` changed (at the start of a fade): the info panel ends above a strip on screen.
    var onShownChange: (() -> Void)?

    /// Whether the viewer must end at the strip's top instead of the window's bottom.
    var reservesSpace: Bool { !isFullScreen && mode == .bar }

    /// The band's height: cells plus padding.
    var bandHeight: CGFloat { cellHeight + 2 * StripView.padding }

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
        view.onScrub = { [weak self] in self?.scrub(to: $0) }
        view.onScrubEnd = { [weak self] in self?.endScrub() }
        view.onTrackpadScroll = { [weak self] in self?.scrolled($0) }
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
    /// bottom edge.
    func attach(to container: NSView) {
        self.container = container
        container.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                                        .activeInKeyWindow, .inVisibleRect],
                                                 owner: self))
    }

    /// The window closes: no timers, no more notifications.
    func close() {
        closed = true
        resizing = false   // a drag cut off by the close has nothing left to restore or save
        scrubbing = false   // the session closes too
        scrubRest?.cancel()
        scroll.takeOver()   // nothing to commit: the session closes too
        scrollRest?.cancel()
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
        if config.stripMagnify != magnify || config.stripMagnifyReach != reach
            || config.stripMagnifyLimit != magnifyLimit || config.thumbSize != thumbSize {
            magnify = config.stripMagnify
            reach = config.stripMagnifyReach
            magnifyLimit = config.stripMagnifyLimit
            thumbSize = config.thumbSize
            view.magnify = CGFloat(magnify)
            view.reach = reach
            view.magnifyLimit = magnifyLimit
            retarget()
            loadCells()   // other magnified pixel sizes
        }
        if config.stripAspect != aspects.mode {
            aspects.setMode(config.stripAspect)
            DebugLog.log("strip aspect \(config.stripAspect.rawValue)")
            relayout()
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
        let height = CGFloat(Config.clampedStripHeight(Double(band - 2 * StripView.padding)))
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
            loadCells()   // the cells the drag skipped
        }
        aspects.paused = false   // what arrived during the drag
        update()
    }

    func setFullScreen(_ on: Bool) {
        guard on != isFullScreen else { return }
        let reserved = reservesSpace
        view.cancelResize()
        view.cancelScrub()
        endScrollScrub()
        isFullScreen = on
        mouseNearBottom = false
        if reservesSpace != reserved { onReservesSpaceChange?() }
        update()
    }

    /// `T` and View › Thumbnail Strip.
    func togglePin() {
        pinned.toggle()
        DebugLog.log("strip \(pinned ? "pinned" : "unpinned")")
        // Unpinned with nothing else holding it: it goes now, the user asked for that.
        update(hideAtOnce: true)
    }

    var isPinned: Bool { pinned }

    /// Set while the cheat sheet is open: a strip on screen does not hide under it (the sheet's Mouse & Trackpad column
    /// talks about it), and a hidden one does not come up for it. Cleared, the usual delay starts.
    var staysShown = false {
        didSet { if staysShown != oldValue { update() } }
    }

    // MARK: Showing

    private var placement: StripWindowMode { isFullScreen ? .overlay : mode }

    /// Shows the strip when something holds it, otherwise hides it after the delay (at once for `hideAtOnce`).
    private func update(hideAtOnce: Bool = false) {
        guard !closed else { return }
        view.isOverlay = placement == .overlay
        let holds: Bool
        switch placement {
        case .off: holds = false
        case .bar: holds = true
        case .overlay:
            holds = pinned || mouseNearBottom || hoverState.file != nil || resizing || scrubbing || scroll.isScrubbing
                || (staysShown && isShown)
        }
        if holds {
            hideTask?.cancel()
            hideTask = nil
            show()
        } else if placement != .overlay || hideAtOnce {
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
        loadCells()
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

    /// The store makes the visible cells' thumbnails first; none while the strip is hidden.
    private func sendVisible() {
        guard !closed else { return }
        session.stripVisibleFiles = isShown ? view.layout.cells.map(\.file) : []
    }

    // MARK: Mouse near the bottom (tracking area owner)

    // Not a responder: the tracking area sends these by their NSResponder selectors, hence the explicit names.

    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) {
        guard let container else { return }
        if isShown { view.trackOutside(event) }
        let p = container.convert(event.locationInWindow, from: nil)
        let near = container.bounds.contains(p) && p.y - container.bounds.minY <= bandHeight
        guard near != mouseNearBottom else { return }
        mouseNearBottom = near
        update()
    }

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        if !scrubbing { hover(nil) }   // left the window from a magnified cell above the band; a scrub keeps its hover
        guard mouseNearBottom else { return }
        mouseNearBottom = false
        update()
    }

    /// The window is no longer key: mouse moves stop arriving, so what they said is stale.
    func windowDidResignKey() {
        view.cancelResize()
        view.cancelScrub()
        endScrollScrub()
        mouseNearBottom = false
        hover(nil)
    }

    // MARK: Session

    /// Called on every session change (every frame of a pan), so it only compares.
    func sessionDidChange() {
        guard let list = session.playlist else { return }
        if list.files != files {
            // A press or trackpad scrub over the old list ends with it (the session already ended its scrub): its
            // cells are other files now, and a press held on would go on scrubbing a list it never saw.
            view.cancelScrub()
            endScrollScrub()
            files = list.files
            aspects.setPlaylist(files)
            // The label showed a file of the old playlist (the interim one-file list replaced by the listing): the
            // hover comes back for the new file under the cursor on the next move.
            hover(nil)
            relayout()
        }
        view.current = list.index
    }

    /// A layout for the view's width and the playlist; cells showing another file than before are asked for.
    /// The files are compared too: another folder of the same length has an equal layout.
    private func relayout() {
        let width = Double(view.bounds.width), height = Double(cellHeight)
        let preferred = laidFiles == files && laidMode == aspects.mode
            ? StripLayout.preferredCount(after: view.layout, fileCount: files.count, width: width, cellHeight: height) : nil
        let layout = StripLayout(fileCount: files.count, width: width, cellHeight: height,
                                 aspects: aspects.layoutAspects, preferredCount: preferred)
        let shown = layout.cells.map { files[$0.file] }
        laidFiles = files
        laidMode = aspects.mode
        guard layout != view.layout || shown != cellFiles else { return }
        view.layout = layout
        scroll.layoutChanged()
        retarget()
        cellFiles = shown
        settled = settled.count > cellFiles.count ? Array(settled.prefix(cellFiles.count))
                                                  : settled + Array(repeating: nil, count: cellFiles.count - settled.count)
        for (index, task) in loads where index >= cellFiles.count {
            task.cancel()
            loads[index] = nil
        }
        if let file = hoverState.file, file >= files.count { hover(nil) }
        loadCells()
        if isShown { sendVisible() }
    }

    // MARK: Aspects

    /// New aspects moved the cells: a cursor resting on the strip now points at another file.
    private func aspectsArrived() {
        DebugLog.log("strip aspects: \(aspects.knownCount) / \(files.count) known")
        relayout()
        view.refreshHover()
    }

    // MARK: Cell pictures

    /// The rested hover's magnification for the current layout and settings.
    private func retarget() {
        hoverState.retarget(layout: view.layout, magnify: Double(view.effectiveMagnify), reach: view.reach)
    }

    /// The file a cell is to show: its own, or for the rested hover's cell the file under the cursor (in a sampled
    /// strip, one of the files of its range).
    private func shownURL(_ index: Int) -> URL {
        if let rested = hoverState.restedFile, index == hoverState.restedCell(in: view.layout), files.indices.contains(rested) {
            return files[rested]
        }
        return cellFiles[index]
    }

    /// The cell's pixel size on its long side: its width, or its height for a portrait cell; magnified around the
    /// rested hover, up to `thumb-size` (the thumbnail has no more).
    private func maxPixel(forCell index: Int) -> Int {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = view.layout.cells.indices.contains(index) ? CGFloat(view.layout.cells[index].width) : cellHeight
        let base = Int((max(width, cellHeight) * scale).rounded())
        let grow = hoverState.pictureScale(ofCell: index)
        guard grow > 1 else { return base }
        return max(base, min(Int((Double(base) * grow).rounded()), thumbSize))
    }

    /// Whether a cell holds its file at a size good enough for its frame now: native cells change width a
    /// little with every relayout for new aspects, which should not ask for every picture again, but an
    /// upscale of more than 10 % or a picture over twice the size is worth a new one.
    private func isSettled(_ index: Int) -> Bool {
        guard let held = settled[index], held.url == shownURL(index) else { return false }
        let needed = maxPixel(forCell: index)
        return Double(needed) <= Double(held.maxPixel) * 1.1 && needed * 2 >= held.maxPixel
    }

    /// Asks for every cell not holding its file's picture yet; only while shown (a hidden strip costs nothing)
    /// and not while the edge is dragged (the release asks once, for the final pixel size).
    private func loadCells() {
        guard isShown, !resizing else { return }
        for index in cellFiles.indices where loads[index] == nil && !isSettled(index) {
            load(cell: index)
        }
    }

    private func load(cell index: Int) {
        let url = shownURL(index), store = self.store, maxPixel = maxPixel(forCell: index)
        let applies = aspects.appliesOrientation
        loads[index] = Task { [weak self] in
            let image = await store.cell(url, maxPixel: maxPixel, applyingOrientation: applies)
            let status = image == nil ? await store.status(url) : .ready
            guard let self, !Task.isCancelled else { return }
            self.loads[index] = nil
            // The layout or the hover moved on meanwhile: this cell shows another file now.
            guard self.cellFiles.indices.contains(index), self.shownURL(index) == url else {
                self.loadCells()
                return
            }
            if let image {
                self.view.setImage(image, forCell: index)
                self.aspects.cellPictureArrived(url)
            } else if status == .unavailable {
                self.view.setUnavailable(forCell: index)
            } else if url == self.cellFiles[index] {
                self.view.setImage(nil, forCell: index)
            }   // the hovered file of a sampled cell, not made yet: the cell keeps its own picture, not a grey box
            self.settled[index] = (url, maxPixel)
            // The rest changed the size this cell needs while it was being read.
            if !self.isSettled(index) { self.loadCells() }
        }
    }

    /// New pixel size (strip height, backing scale) or a cleared cache: every cell again, pictures kept on
    /// screen until their replacements arrive.
    private func reloadAll() {
        loads.values.forEach { $0.cancel() }
        loads = [:]
        settled = Array(repeating: nil, count: cellFiles.count)
        loadCells()
    }

    private func thumbnailChanged(_ url: URL) {
        aspects.thumbnailArrived(url)
        for index in cellFiles.indices where shownURL(index) == url {
            settled[index] = nil
            loads[index]?.cancel()
            loads[index] = nil
        }
        loadCells()
    }

    // MARK: Scrub

    /// A press reached `file` (the press itself, or a new file under the drag): the session scrubs to it, and a
    /// rest of `dwellDelay` on it ends the scrub.
    private func scrub(to file: Int) {
        guard !closed else { return }
        // A press takes over a scroll's scrub (the session's scrub goes on under the press, which commits it).
        scroll.takeOver()
        scrollRest?.cancel()
        scrollRest = nil
        scrubbing = true
        session.scrub(to: file)
        scrubRest?.cancel()
        scrubRest = Task { [weak self] in
            try? await Task.sleep(for: ViewerSession.dwellDelay)
            guard !Task.isCancelled, let self, !self.closed else { return }
            self.scrubRest = nil
            self.session.endScrub()
        }
        update()
    }

    /// The press ended (or was cut off): the scrub ends unless a rest already ended it.
    private func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        scrubRest?.cancel()
        scrubRest = nil
        if !closed { session.endScrub() }
        update()
    }

    // MARK: Trackpad scroll

    /// A precise scroll over the strip that is the strip's (`StripView.onTrackpadScroll`): a new file the selection
    /// reaches scrubs to it; the end of the momentum or a cancelled gesture commits at once, otherwise the rest timer
    /// does. Not during a press: that is the press's scrub.
    private func scrolled(_ event: NSEvent) {
        guard !closed, !scrubbing, let current = session.playlist?.index else { return }
        let wasScrubbing = scroll.isScrubbing
        let fingers = FingerDirection.sign(invertedFromDevice: event.isDirectionInvertedFromDevice)
        let outcome = scroll.event(fingerDX: fingers * event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                   phase: ScrollPhase(rawValue: event.phase.rawValue),
                                   momentum: ScrollPhase(rawValue: event.momentumPhase.rawValue),
                                   layout: view.layout, current: current, now: event.timestamp)
        if let file = outcome.file {
            if !wasScrubbing { DebugLog.log("strip scroll scrub from \(current + 1)") }
            session.scrub(to: file)
            update()
        }
        if outcome.commit {
            committedScrollScrub()
        } else {
            armScrollRest()
        }
    }

    /// One timer for the rest: armed for the deadline it finds, and on waking it commits or, when events put the
    /// deadline off meanwhile, sleeps again until the new one. Event timestamps and `systemUptime` share a clock.
    private func armScrollRest() {
        guard scrollRest == nil, let deadline = scroll.restDeadline else { return }
        scrollRest = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            guard !Task.isCancelled, let self else { return }
            self.scrollRest = nil
            if self.scroll.rested(now: ProcessInfo.processInfo.systemUptime) {
                self.committedScrollScrub()
            } else {
                self.armScrollRest()
            }
        }
    }

    /// The window lost key or changes full screen: a scroll's scrub commits now.
    private func endScrollScrub() {
        if scroll.end() { committedScrollScrub() }
    }

    /// `StripScroll` ended its scrub (momentum end, cancel, rest, `end()`): the session's scrub commits.
    private func committedScrollScrub() {
        scrollRest?.cancel()
        scrollRest = nil
        DebugLog.log("strip scroll scrub end")
        if !closed { session.endScrub() }
        update()
    }

    // MARK: Hover

    private func hover(_ file: Int?) {
        // Moves seen while fading out (or before a show) must not leave a magnification to resurface on the next show.
        if file != nil, !isShown {
            view.endHover()
            return
        }
        guard let file, files.indices.contains(file) else {
            if hoverState.file != nil {
                dropHover()
                update()
            }
            return
        }
        guard hoverState.set(file) else { return }
        view.showLabel(file: file, name: ArchivePath.shortName(files[file]))
        update()
    }

    /// No hover: the base layout, and the cells back to their own files at their own size (keeping the larger
    /// pictures until those arrive; none are asked for while hidden).
    private func dropHover() {
        view.endHover()
        guard hoverState.drop() else { return }
        loadCells()
    }

    /// The cursor stayed on one file: the magnified cells get pictures for their size, the hovered one its file.
    private func rested() {
        retarget()
        let before = loads.count
        loadCells()
        DebugLog.log("strip rest on \((hoverState.restedFile ?? 0) + 1): \(loads.count - before) cells asked for at the magnified size")
    }
}
