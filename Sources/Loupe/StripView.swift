import AppKit
import LoupeCore
import QuartzCore

/// The thumbnail strip's surface (spec §4.4): a layer per visible cell over a dark band, an accent border on
/// the current photo's cell and, while the cursor is over the strip, Dock-style magnification (Build 1.1, in
/// place of the preview of Build 1): the cells grow upwards by how close they are to the cursor, continuously, up
/// to `magnify` (at most `strip-magnify-limit` of the viewer's height), the rest part (`StripMagnifier`), with "137 / 200 · name"
/// over the cell under the cursor. Pure Core Animation: thumbnails arrive as
/// `layer.contents` and the cells move by their layer frames, so nothing is drawn on the main thread. What to show
/// comes from `StripController`; this view only reports the cursor (`onHover`), a press and drag on the cells
/// (`onScrub` / `onScrubEnd`, Build 2; a click is a scrub of one file), a drag of its top edge (`onResize*`,
/// Build 1.1) and trackpad scrolling (`onTrackpadScroll`, Task 20; the wheel goes on to the viewer).
///
/// Magnified cells reach above the band, outside the view's bounds: once the cursor is over the strip, it stays
/// over it while it is inside a magnified cell or the grab band on its top (hit-testing and `trackOutside` cover
/// that part), so neither collapses under a cursor moving up into it. The file under the cursor always comes from
/// the base layout, never from the magnified frames, so the mapping from x to file stays put while the cells move.
@MainActor final class StripView: NSView {
    /// Space above and below the cells, inside the band.
    static let padding: CGFloat = 4
    /// Between the magnified cell and its label, and between the label and the window's edges.
    private static let labelGap: CGFloat = 6
    /// The implicit animation of the cells' frames as the magnification comes and goes (the cursor enters or leaves
    /// the strip). In between the frames follow the cursor directly.
    private static let magnifyDuration: CFTimeInterval = 0.1
    private static let fadeDuration: CFTimeInterval = 0.15
    private static let placeholderColor = CGColor(gray: 0x33 / 255, alpha: 1)
    private static let unavailableColor = CGColor(gray: 0x1c / 255, alpha: 1)

    var layout = StripLayout(fileCount: 0, width: 0, cellHeight: 64) {
        didSet { if layout != oldValue { layoutCells() } }
    }

    /// The current photo's file index: its cell gets the accent border.
    var current = 0 {
        didSet { if current != oldValue { withoutAnimation { placeBorder() } } }
    }

    /// `strip-magnify`, `strip-magnify-reach` and `strip-magnify-limit` (% of the viewer's height).
    var magnify: CGFloat = 2 {
        didSet { if magnify != oldValue { placeCells(animated: false) } }
    }
    var reach = 2.0 {
        didSet { if reach != oldValue { placeCells(animated: false) } }
    }
    var magnifyLimit = 15.0 {
        didSet { if magnifyLimit != oldValue { placeCells(animated: false) } }
    }

    /// `strip-corner-radius`: the cells' corner radius in points at the base height (a magnified cell scales it with
    /// its height); the band behind a strip that does not fill the width is rounded `padding` more, so its corners
    /// are concentric with the cells'.
    var cornerRadius: CGFloat = 4 {
        didSet {
            guard cornerRadius != oldValue else { return }
            for cell in cells { cell.shown = .null }   // the radius is written with the frame
            bandShown = nil
            placeCells(animated: false)
        }
    }

    /// Floating over the picture (translucent band) or a bar of its own (solid).
    var isOverlay = true {
        didSet { if isOverlay != oldValue { needsDisplay = true } }
    }

    /// The file under the cursor while it is over the cells, nil when it leaves them.
    var onHover: ((Int?) -> Void)?
    /// A press on the cells, then every new file a drag reaches (spec §4.3): the file under the cursor's x, the x
    /// held within the cells while the drag goes past either end or off the strip.
    var onScrub: ((Int) -> Void)?
    /// The press that scrubbed ended: mouse-up, or a press cut off (`cancelScrub`).
    var onScrubEnd: (() -> Void)?
    /// The backing scale changed: cell pictures must be asked for at the new pixel size.
    var onBackingChange: (() -> Void)?
    /// A drag of the top edge asks for this band height (points); the controller clamps it and answers by
    /// changing the view's height.
    var onResizeDrag: ((CGFloat) -> Void)?
    /// The drag of the top edge ended: `save` is true for a real mouse-up, false for a drag that was cut off (see
    /// `cancelResize`), which must give the start height back.
    var onResizeEnd: ((_ save: Bool) -> Void)?
    /// The view's width changed: the controller makes a new layout.
    var onResize: (() -> Void)?
    /// Scrolling over the strip that is the viewer's (`StripScroll.route`): the wheel steps through photos everywhere
    /// (spec §4.3), and a scroll with a folder-gesture button held steps folders.
    var onScroll: ((NSEvent) -> Void)?
    /// Trackpad scrolling with no button held, the strip's own: the controller scrubs on a horizontal swipe
    /// (`StripScroll`) and ignores a vertical one, so the photo under the strip does not pan.
    var onTrackpadScroll: ((NSEvent) -> Void)?
    /// Whether the viewer's scroll guard says the rest of this precise scroll's gesture does nothing
    /// (`ViewerView.stripScrollIsSpent`, which also stops a glide of the photo): asked only for the strip's own scroll.
    var isScrollSpent: (NSEvent) -> Bool = { _ in false }

    private final class Cell {
        let layer = CALayer()
        let image = CALayer()
        let mark = CATextLayer()
        var hasImage = false
        /// The frame last given to `layer`: the frames follow the cursor on every move, and most of them do not change.
        var shown = CGRect.null
    }

    private var cells: [Cell] = []
    private let border = CALayer()
    /// The dark band: the view's full width when the cells fill it, else only behind the cells (`StripBand`).
    private let band = CALayer()
    /// The frame and radius last given to `band`: written only when they change.
    private var bandShown: (frame: CGRect, radius: CGFloat)?
    /// "N / M · name" over the magnified cell, and its size, measured once per text rather than on every move.
    private let label = CATextLayer()
    private var labelSize = CGSize.zero
    /// The cursor's x while it is over the strip (base layout coordinates), and the base cell under it: the cell
    /// that is magnified most, with the label.
    private var hoverX: CGFloat?
    private var magnifiedCell: Int?
    /// The cells' frames as shown (magnified around `magnifiedCell`, or the base layout).
    private var frames: [(x: Double, width: Double, height: Double)] = []
    /// While a press on the cells scrubs: the file last reported by `onScrub`.
    private var scrubFile: Int?
    /// While the top edge is dragged: the press's y in the window and the base height for each distance from it
    /// (`StripResizeDrag`: a magnified top stays under the cursor while it can, else the base follows 1:1). The
    /// view sits at the window's bottom and grows upwards, so its own coordinates move with it; the window's do not.
    private var resizeStart: (y: CGFloat, drag: StripResizeDrag)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Magnified cells and their label rise above the band, outside the view's bounds.
        clipsToBounds = false
        border.borderWidth = 2
        border.cornerCurve = .continuous
        border.borderColor = NSColor.controlAccentColor.cgColor
        border.zPosition = 1
        label.fontSize = 12
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.foregroundColor = CGColor(gray: 0.92, alpha: 1)
        label.backgroundColor = CGColor(gray: 0.1, alpha: 0.75)
        label.cornerRadius = 4
        label.alignmentMode = .center
        label.truncationMode = .middle
        label.isHidden = true
        label.zPosition = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.addSublayer(band)   // first: under the cells
        layer.addSublayer(border)
        layer.addSublayer(label)
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        withoutAnimation { band.backgroundColor = CGColor(gray: 0.1, alpha: isOverlay ? 0.6 : 1) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        withoutAnimation(placeBand)   // the height too
        if widthChanged { onResize?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 1
        for cell in cells { cell.mark.contentsScale = scale }
        label.contentsScale = scale
        onBackingChange?()
    }

    // MARK: Cells

    /// The picture of a cell; nil puts the grey "not made yet" placeholder back. A cell that had no picture
    /// fades it in; one replacing another picture (a new layout, a new size) swaps at once, so a resize does
    /// not flicker.
    func setImage(_ image: CGImage?, forCell index: Int) {
        guard cells.indices.contains(index) else { return }
        let cell = cells[index]
        withoutAnimation {
            cell.mark.isHidden = true
            cell.layer.backgroundColor = Self.placeholderColor
            cell.image.contents = image
        }
        if image != nil, !cell.hasImage {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Self.fadeDuration
            cell.image.add(fade, forKey: "fade")
        }
        cell.hasImage = image != nil
    }

    /// The darker "no thumbnail" placeholder with a ×: the file could not be read or decoded.
    func setUnavailable(forCell index: Int) {
        guard cells.indices.contains(index) else { return }
        let cell = cells[index]
        withoutAnimation {
            cell.image.contents = nil
            cell.layer.backgroundColor = Self.unavailableColor
            cell.mark.isHidden = false
        }
        cell.hasImage = false
    }

    /// Adds or removes cell layers to match the layout; the pictures stay with the layers until the controller
    /// replaces them.
    private func layoutCells() {
        withoutAnimation {
            while cells.count > layout.cells.count { cells.removeLast().layer.removeFromSuperlayer() }
            while cells.count < layout.cells.count {
                let cell = makeCell()
                cells.append(cell)
                layer?.addSublayer(cell.layer)
            }
            placeCells(animated: false)
        }
    }

    /// The band for the frames as shown, in the caller's animation context: full width and square when the cells fill
    /// the view, else just behind them (the magnified row too) with `padding` beside them, rounded.
    private func placeBand() {
        let shape = StripBand(leftEdge: frames.first.map(\.x), rightEdge: frames.last.map { $0.x + $0.width },
                              viewWidth: Double(bounds.width), margin: Double(Self.padding))
        let frame = CGRect(x: shape.x, y: 0, width: shape.width, height: bounds.height)
        let radius = shape.isFull ? 0 : min(cornerRadius + Self.padding, min(frame.width, frame.height) / 2)
        guard bandShown?.frame != frame || bandShown?.radius != radius else { return }
        bandShown = (frame, radius)
        band.frame = frame
        band.cornerRadius = radius
    }

    private func makeCell() -> Cell {
        let cell = Cell()
        cell.layer.backgroundColor = Self.placeholderColor
        // The cell's layer draws only the placeholder (background and rounded corners, no clipping of sublayers); the
        // picture clips itself, so no cell needs an offscreen mask pass while the frames follow the cursor.
        cell.layer.cornerCurve = .continuous
        cell.image.masksToBounds = true
        cell.image.cornerCurve = .continuous
        // Crop mode: the centre 3:2. Native: the cell has the photo's proportions, so the whole picture; a
        // sampled strip scales its cells by one factor to fill the width, and the few per cent that leaves
        // over are cropped rather than shown as slivers between cells.
        cell.image.contentsGravity = .resizeAspectFill
        cell.layer.addSublayer(cell.image)
        cell.mark.string = "×"
        cell.mark.fontSize = 16
        cell.mark.foregroundColor = CGColor(gray: 0.55, alpha: 1)
        cell.mark.alignmentMode = .center
        cell.mark.contentsScale = window?.backingScaleFactor ?? 2
        cell.mark.isHidden = true
        cell.layer.addSublayer(cell.mark)
        return cell
    }

    /// `magnify` as applied: the magnified cell at most `magnifyLimit` % of the viewer's height (the window's, less
    /// the strip in `bar` mode, where the viewer ends at the strip's top).
    var effectiveMagnify: CGFloat {
        let viewer = (superview?.bounds.height ?? 0) - (isOverlay ? 0 : bounds.height)
        return CGFloat(StripMagnifier.effectiveMagnify(Double(magnify), cellHeight: layout.cellHeight,
                                                       viewerHeight: Double(viewer), limitPercent: magnifyLimit))
    }

    /// The cells at their frames for the cursor (`StripMagnifier`): animated when the magnification comes or goes,
    /// at once while it follows the cursor and for a new layout or setting.
    private func placeCells(animated: Bool) {
        let height = layout.cellHeight
        magnifiedCell = hoverX.flatMap(baseCell(atX:))
        let base = layout.cells.map { (x: $0.x, width: $0.width) }, cursor = hoverX.map(Double.init)
        let magnified = StripMagnifier.frames(baseCells: base, height: height, cursorX: cursor,
                                              magnify: Double(effectiveMagnify), reach: reach)
        frames = StripMagnifier.keepingInside(magnified, baseCells: base, cursorX: cursor, width: Double(bounds.width))
        let place = {
            for (cell, f) in zip(self.cells, self.frames) {
                // Grown upwards from the band's bottom padding. A hairline between cells keeps neighbours apart
                // without breaking the edge-to-edge axis.
                let frame = CGRect(x: f.x, y: Self.padding, width: f.width, height: f.height)
                guard frame != cell.shown else { continue }
                let resized = frame.size != cell.shown.size
                cell.shown = frame
                cell.layer.frame = frame
                guard resized else { continue }
                cell.image.frame = CGRect(origin: .zero, size: frame.size).insetBy(dx: 0.5, dy: 0)
                // The radius follows the height, and only a size change moves it.
                let radius = CGFloat(StripCorners.radius(base: Double(self.cornerRadius), height: Double(f.height),
                                                         baseHeight: Double(self.layout.cellHeight), width: f.width))
                cell.layer.cornerRadius = radius
                cell.image.cornerRadius = radius
                cell.mark.frame = CGRect(x: 0, y: (f.height - 20) / 2, width: f.width, height: 20)
            }
            self.placeBand()
            self.placeBorder()
            self.placeLabel()
        }
        if animated { magnifying(place) } else { withoutAnimation(place) }
    }

    private func placeBorder() {
        guard let index = layout.cell(containingFile: current) else {
            border.isHidden = true
            return
        }
        border.isHidden = false
        guard cells.indices.contains(index) else {
            border.frame = .zero
            return
        }
        border.frame = cells[index].layer.frame
        let radius = cells[index].layer.cornerRadius
        if border.cornerRadius != radius { border.cornerRadius = radius }
    }

    /// The base cell under `x`, nil beside the cells.
    private func baseCell(atX x: CGFloat) -> Int? {
        layout.fileIndex(atX: Double(x)).flatMap(layout.cell(containingFile:))
    }

    // MARK: Hover label

    /// "N / M · name" of the file under the cursor, over the magnified cell.
    func showLabel(file: Int, name: String) {
        withoutAnimation {
            label.string = "\(file + 1) / \(layout.fileCount) · \(name)"
            labelSize = label.preferredFrameSize()
            label.isHidden = false
        }
        withoutAnimation(placeLabel)
    }

    /// The cursor left the strip (or the controller dropped the hover: hidden, window not key, another
    /// playlist): back to the base layout, no label.
    func endHover() {
        withoutAnimation { label.isHidden = true }
        guard hoverX != nil else { return }
        hoverX = nil
        placeCells(animated: true)
        releaseResizeCursor()
    }

    /// Centred over the magnified cell, inside the window: the view spans the window's width, and a tall strip can
    /// push the label against the window's top.
    private func placeLabel() {
        guard !label.isHidden, let index = magnifiedCell, frames.indices.contains(index) else { return }
        let f = frames[index], gap = Self.labelGap
        let size = labelSize
        let width = min(size.width + 16, max(40, bounds.width - 2 * gap))
        let height = size.height + 4
        let left = min(max(f.x + f.width / 2 - width / 2, gap), max(gap, bounds.width - gap - width))
        var bottom = Self.padding + f.height + gap
        if let superview { bottom = min(bottom, convert(superview.bounds, from: superview).maxY - gap - height) }
        label.frame = CGRect(x: left, y: bottom, width: width, height: height)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited,
                                                              .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    /// The grab band, the magnified cells and the hover zone (`StripHitZone`) for the frames as shown.
    private var zone: StripHitZone {
        StripHitZone(frames: frames, width: Double(bounds.width), height: Double(bounds.height),
                     padding: Double(Self.padding), hovering: hoverX != nil)
    }

    private func inResizeBand(_ p: NSPoint) -> Bool {
        acceptsMouse && zone.inResizeBand(x: Double(p.x), y: Double(p.y))
    }

    private func overMagnifiedCell(_ p: NSPoint) -> Bool { zone.overMagnifiedCell(x: Double(p.x), y: Double(p.y)) }

    /// Where the cursor counts as over the strip; fading out, nowhere.
    private func inHoverZone(_ p: NSPoint) -> Bool {
        acceptsMouse && zone.inHoverZone(x: Double(p.x), y: Double(p.y))
    }

    /// Ends a drag of the top edge whose mouse-up never came (Mission Control, a sheet, the window closing, a
    /// full-screen change): the controller restores the start height and does not save.
    func cancelResize() {
        guard resizeStart != nil else { return }
        resizeStart = nil
        NSCursor.arrow.set()
        onResizeEnd?(false)
    }

    /// Ends a scrub whose mouse-up never came (the same cases as `cancelResize`): the session gets its normal plan.
    func cancelScrub() {
        guard scrubFile != nil else { return }
        scrubFile = nil
        onScrubEnd?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancelResize()
        cancelScrub()
    }

    /// The arrow over the strip, whatever the picture under it would show; up-down arrows on the top edge.
    override func cursorUpdate(with event: NSEvent) { setCursor(for: event) }

    private func setCursor(for event: NSEvent) {
        // A drag keeps its cursor wherever the pointer goes.
        (resizeStart != nil || inResizeBand(convert(event.locationInWindow, from: nil)) ? NSCursor.resizeUpDown : NSCursor.arrow).set()
    }

    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) {
        endLostPress()
        setCursor(for: event)
        hover(event)
    }

    /// Moves arrive only while no button is down, so a resize or scrub still on lost its mouse-up without the
    /// window resigning key (which `cancelResize` / `cancelScrub` cover): it ends as cut off, and the strip stops
    /// being held with a frozen hover.
    private func endLostPress() {
        guard resizeStart != nil || scrubFile != nil, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        cancelResize()
        cancelScrub()
    }

    /// Leaving the band upwards into a magnified cell is not leaving the strip.
    override func mouseExited(with event: NSEvent) { hover(event) }

    /// A mouse move anywhere in the window (the controller's tracking area): the view's own tracking area covers
    /// only its bounds, so the magnified cells above the band and the grab band on their tops are followed from
    /// here (the cursor too: the view's `cursorUpdate` comes only inside its bounds).
    func trackOutside(_ event: NSEvent) {
        endLostPress()
        let p = convert(event.locationInWindow, from: nil)
        guard hoverX != nil, !bounds.contains(p) else { return }
        hover(event)
        if hoverX != nil { setCursor(for: event) } else { releaseResizeCursor() }
    }

    /// The hover ended with the cursor in the grab band over a magnified cell, which is gone with it: the ↕ goes
    /// too. The viewer may already have handled this move (seeing the strip there), so nothing else would replace
    /// the ↕ before the next one; the viewer sets its own cursor on that move.
    private func releaseResizeCursor() {
        if resizeStart == nil, NSCursor.current == NSCursor.resizeUpDown { NSCursor.arrow.set() }
    }

    /// Not while scrubbing: the drag moves the hover (`scrubbed`), and the cursor leaving the strip then is no exit.
    /// Not while the top edge is dragged either: the magnification stays as it was at the press.
    private func hover(_ event: NSEvent) {
        guard scrubFile == nil, resizeStart == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let file = inHoverZone(p) ? layout.fileIndex(atX: p.x) : nil
        setHoverX(file == nil ? nil : p.x)
        onHover?(file)
    }

    /// The frames follow the cursor on every move, set directly (an animation per move would lag behind it);
    /// only entering and leaving the strip animate.
    private func setHoverX(_ x: CGFloat?) {
        let entersOrLeaves = (x == nil) != (hoverX == nil)
        guard x != hoverX else { return }
        hoverX = x
        placeCells(animated: entersOrLeaves)
    }

    /// The layout moved under a cursor that did not (new aspects): the file under it again.
    func refreshHover() {
        guard let x = hoverX else { return }
        let file = layout.fileIndex(atX: x)
        if file == nil { setHoverX(nil) }
        onHover?(file)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Taken here so the press never reaches the picture underneath (no pan starts on the strip). The grab band
    /// on the shown top edge starts a resize; a press on a cell (the band or a magnified one) starts a scrub;
    /// anywhere else nothing.
    override func mouseDown(with event: NSEvent) {
        // A press while a drag is still on means its mouse-up was lost.
        cancelResize()
        cancelScrub()
        let p = convert(event.locationInWindow, from: nil)
        if inResizeBand(p) {
            let base = Double(layout.cellHeight)
            let drag = StripResizeDrag(startHeight: base, shownHeight: zone.shownCellHeight(atX: Double(p.x)) ?? base,
                                       magnify: Double(magnify), windowHeight: Double(superview?.bounds.height ?? 0),
                                       viewerShrinks: !isOverlay, padding: Double(Self.padding),
                                       limitPercent: magnifyLimit)
            resizeStart = (event.locationInWindow.y, drag)
            return
        }
        // The base layout's file under x, as the hover said: not the magnified frame's.
        guard bounds.contains(p) || overMagnifiedCell(p), let file = layout.fileIndex(atX: p.x) else { return }
        scrubFile = file
        onScrub?(file)
    }

    override func mouseDragged(with event: NSEvent) {
        if let resizeStart {
            let height = resizeStart.drag.height(forDrag: Double(event.locationInWindow.y - resizeStart.y))
            onResizeDrag?(CGFloat(height) + 2 * Self.padding)
            return
        }
        if scrubFile != nil { scrubbed(event) }
    }

    /// A drag of a scrub: the hover follows the cursor's x (mouse moves stop while the button is down), held within
    /// the cells like a scroll bar's thumb, and each new file under it is reported.
    private func scrubbed(_ event: NSEvent) {
        guard !layout.cells.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        let x = min(max(p.x, CGFloat(layout.originX)), CGFloat(layout.originX + layout.span).nextDown)
        guard let file = layout.fileIndex(atX: Double(x)) else { return }
        setHoverX(x)
        onHover?(file)
        guard file != scrubFile else { return }
        scrubFile = file
        onScrub?(file)
    }

    override func mouseUp(with event: NSEvent) {
        if resizeStart != nil {
            resizeStart = nil
            onResizeEnd?(true)
            hover(event)   // the hover was held during the drag
            setCursor(for: event)
            return
        }
        guard scrubFile != nil else { return }
        scrubFile = nil
        onScrubEnd?()
        hover(event)   // the drag may have left the strip
    }

    // The middle, back and forward buttons are the viewer's bindings over the strip too (`MouseButtons`, as in
    // `ViewerView`); the left button stays the strip's own (a scrub, a resize).
    override func otherMouseDown(with event: NSEvent) {
        if !MouseButtons.shared.otherMouseDown(event) { super.otherMouseDown(with: event) }
    }

    override func otherMouseDragged(with event: NSEvent) { MouseButtons.shared.moved(event) }

    override func otherMouseUp(with event: NSEvent) {
        if !MouseButtons.shared.otherMouseUp(event) { super.otherMouseUp(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        switch StripScroll.route(precise: event.hasPreciseScrollingDeltas,
                                 held: LoupeCore.MouseButtons(rawValue: NSEvent.pressedMouseButtons),
                                 folderGesture: Settings.shared.config.folderScrollGesture, pressed: isPressed,
                                 spent: isScrollSpent(event)) {
        case .viewer: onScroll?(event)
        case .strip: onTrackpadScroll?(event)
        case .ignore: break
        }
    }

    /// A press of the strip's own is on (a scrub or a resize of its top edge), until its mouse-up.
    var isPressed: Bool { resizeStart != nil || scrubFile != nil }

    /// Fading out, the strip already lets clicks through to the picture; before its first show too: it starts
    /// hidden, and `hitTest` claims the grab band without `super`, which is what skips a hidden view.
    var acceptsMouse = false

    /// The magnified cells above the band and the grab band on their tops are the strip's too (clicks, scrolling,
    /// and the viewer's cursor and autohide, which hit-test to tell the picture from the strip).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsMouse, !isHidden else { return nil }
        if let hit = super.hitTest(point) { return hit }
        let p = convert(point, from: superview)
        return overMagnifiedCell(p) || inResizeBand(p) ? self : nil
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// The magnification's implicit animation.
    private func magnifying(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.magnifyDuration)
        body()
        CATransaction.commit()
    }
}
