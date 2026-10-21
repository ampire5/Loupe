import AppKit
import LoupeCore
import QuartzCore

/// The thumbnail strip's surface (spec 2026-10-21, Photos' filmstrip): narrow cells on one line that moves under the
/// strip's fixed centre, the current photo there in its own proportions, the edges fading out. No band, border or
/// glass behind the cells: the strip lies on the viewer's background (a bar) or the photo (the overlay); only the
/// hover label is glass. Pure Core Animation: the cells are layers of one content layer that moves as a whole (its
/// position, without implicit animations, while the strip follows a gesture), a layer per visible file from a pool,
/// thumbnails as `layer.contents`, so nothing is drawn on the main thread and the layer count follows the window,
/// not the folder.
///
/// What to show comes from `StripController` (`show(offset:current:expansion:animated:)`, the pictures by file);
/// this view reports the cursor (`onHover`), a click on a cell (`onPress`), a drag across the cells (`onDrag` /
/// `onDragEnd`), a drag of its top edge (`onResize*`) and trackpad scrolling (`onTrackpadScroll`; the wheel goes on
/// to the viewer).
@MainActor final class StripView: NSView {
    /// Space above and below the cells, inside the band: Photos' ≈ 6 pt between the photo and the cells.
    static let padding: CGFloat = 6
    /// Between a cell and its label above it.
    private static let labelGap: CGFloat = 6
    /// A press that moves less than this is a click.
    private static let clickSlop: CGFloat = 3
    /// The settling, a click's move and a step to a neighbour.
    private static let moveDuration: CFTimeInterval = 0.2
    private static let fadeDuration: CFTimeInterval = 0.15
    private static let placeholderBorder = CGColor(gray: 1, alpha: 0.38)
    private static let unavailableColor = CGColor(gray: 0x1c / 255, alpha: 1)

    var layout = StripScrollLayout(fileCount: 0, width: 0, cellHeight: 68, maxAspect: 1.5, aspects: []) {
        didSet {
            guard layout != oldValue else { return }
            withoutAnimation(placeFade)
            placeCells(animated: animatesLayout)
        }
    }
    private var animatesLayout = false

    /// A new layout whose cells move to their new frames in `moveDuration` (aspects that arrived: the current cell
    /// grows to its photo's proportions) rather than at once (a resize, another playlist).
    func setLayout(_ layout: StripScrollLayout, animated: Bool) {
        animatesLayout = animated
        self.layout = layout
        animatesLayout = false
    }

    /// `strip-corner-radius`: the cells' corner radius in points.
    var cornerRadius: CGFloat = 3 {
        didSet {
            guard cornerRadius != oldValue else { return }
            withoutAnimation {
                for cell in cells.values + pool {
                    cell.layer.cornerRadius = cornerRadius
                    cell.image.cornerRadius = cornerRadius
                }
            }
        }
    }

    /// Floating over the picture or a bar of its own.
    var isOverlay = true

    /// The file under the cursor while it is over the cells, nil when it leaves them.
    var onHover: ((Int?) -> Void)?
    /// A click (press and release with less than `clickSlop` of travel) on a file's cell.
    var onPress: ((Int) -> Void)?
    /// A press on the cells moved more than a click: each drag event's horizontal travel in points, then the release
    /// or a cut-off press (`cancelPress`).
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    /// The visible files changed (`visibleFiles`): pictures to ask for.
    var onVisibleChange: (() -> Void)?
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
    /// Trackpad scrolling with no button held, the strip's own: the controller moves the strip on a horizontal swipe
    /// (`StripScroll`) and ignores a vertical one, so the photo under the strip does not pan.
    var onTrackpadScroll: ((NSEvent) -> Void)?
    /// Whether the viewer's scroll guard says the rest of this precise scroll's gesture does nothing
    /// (`ViewerView.stripScrollIsSpent`, which also stops a glide of the photo): asked only for the strip's own scroll.
    var isScrollSpent: (NSEvent) -> Bool = { _ in false }

    private final class Cell {
        let layer = CALayer()
        let image = CALayer()
        let mark = CATextLayer()
        /// The frame last given to `layer`, in the content layer.
        var shown = CGRect.null
    }

    /// The pictures the controller gave, by file, until it forgets them.
    private var pictures: [Int: CGImage] = [:]
    private var unavailable: Set<Int> = []
    /// The cell of each file on screen, and the cells waiting for one.
    private var cells: [Int: Cell] = [:]
    private var pool: [Cell] = []
    /// The edges' fade (the mask) over everything the cells are in.
    private let fadeLayer = CALayer()
    private let fadeMask = CAGradientLayer()
    /// The cells, moved as one: its x is the view x of base x 0.
    private let contentLayer = CALayer()
    /// What `show` was last asked to show.
    private var offset = 0.0, current = 0, expansion = 1.0
    /// The cells shown, left to right, in view x.
    private var shownCells: [StripCell] = []
    /// The files on screen, from the centre outwards.
    private(set) var visibleFiles: [Int] = []
    private let label = StripLabelView()
    /// The file whose label is up, and the point last hovered (view coordinates), for `refreshHover`.
    private var labelFile: Int?
    private var hoverPoint: NSPoint?
    /// A press on the cells: where it began in the window, the x of the last drag event, the file under it and
    /// whether it moved far enough to be a drag.
    private var press: (startX: CGFloat, lastX: CGFloat, file: Int?, dragging: Bool)?
    /// While the top edge is dragged: the press's y in the window and the height for each distance from it. The
    /// view sits at the window's bottom and grows upwards, so its own coordinates move with it; the window's do not.
    private var resizeStart: (y: CGFloat, drag: StripResizeDrag)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // The hover label stands above the band, outside the view's bounds.
        clipsToBounds = false
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1),
                           CGColor(gray: 0, alpha: 0)]
        fadeLayer.mask = fadeMask
        fadeLayer.addSublayer(contentLayer)
        label.isHidden = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.addSublayer(fadeLayer)
        return layer
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        withoutAnimation(placeFade)
        if widthChanged { onResize?() } else { placeCells(animated: false) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 1
        for cell in cells.values + pool { cell.mark.contentsScale = scale }
        onBackingChange?()
    }

    /// The fade over the band: the whole view, opaque but for `fadeLength` at each end.
    private func placeFade() {
        fadeLayer.frame = bounds
        fadeMask.frame = fadeLayer.bounds
        let share = bounds.width > 0 ? min(0.5, layout.fadeLength / Double(bounds.width)) : 0
        fadeMask.locations = [0, NSNumber(value: share), NSNumber(value: 1 - share), 1]
    }

    // MARK: Showing

    /// Base x `offset` under the strip's centre, `current` expanded by `expansion` (0 narrow … 1 its photo's
    /// proportions). `animated`: the cells move there in `moveDuration`, ease-out (the settling, a click, a step);
    /// otherwise at once (a gesture, a jump).
    func show(offset: Double, current: Int, expansion: Double, animated: Bool) {
        let previous = self.offset
        guard offset != previous || current != self.current || expansion != self.expansion else { return }
        self.offset = offset
        self.current = current
        self.expansion = expansion
        placeCells(animated: animated, from: animated ? previous : nil)
    }

    /// The cells for the state `show` was given, each layer at its frame in the content layer, which carries the
    /// offset. An animated move also keeps the cells of where it starts until it ends, so none leaves the screen
    /// early.
    private func placeCells(animated: Bool, from previous: Double? = nil) {
        let target = layout.cells(offset: offset, current: current, expansion: expansion)
        let origin = Double(bounds.width) / 2 - offset
        // Each cell's x in the content layer: its view x less the origin it was laid out with.
        var frames: [Int: (x: Double, width: Double)] = [:]
        for c in target { frames[c.file] = (c.x - origin, c.width) }
        if let previous, previous != offset {
            let previousOrigin = Double(bounds.width) / 2 - previous
            for c in layout.cells(offset: previous, current: current, expansion: expansion) where frames[c.file] == nil {
                frames[c.file] = (c.x - previousOrigin, c.width)
            }
        }
        let place = {
            // Cells that leave go back to the pool and new ones start where they belong, so only the move animates.
            self.withoutAnimation {
                for file in Array(self.cells.keys) where frames[file] == nil { self.recycle(file) }
                for (file, frame) in frames where self.cells[file] == nil {
                    self.cells[file] = self.takeCell(for: file)
                    self.place(file, frame)
                }
            }
            self.contentLayer.frame = CGRect(x: origin, y: Double(Self.padding), width: 0, height: 0)
            for (file, frame) in frames { self.place(file, frame) }
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.moveDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated { self?.dropCellsOffScreen() }
            }
            place()
            CATransaction.commit()
        } else {
            withoutAnimation(place)
        }
        shownCells = target
        let files = target.map(\.file).sorted { abs($0 - current) < abs($1 - current) }
        if files != visibleFiles {
            visibleFiles = files
            onVisibleChange?()
        }
        placeLabel()
    }

    /// After an animated move: the cells kept for its start that are not shown now go back to the pool.
    private func dropCellsOffScreen() {
        let shown = Set(shownCells.map(\.file))
        withoutAnimation { for file in Array(cells.keys) where !shown.contains(file) { recycle(file) } }
    }

    private func place(_ file: Int, _ frame: (x: Double, width: Double)) {
        guard let cell = cells[file] else { return }
        let height = layout.cellHeight
        let rect = CGRect(x: frame.x, y: 0, width: frame.width, height: height)
        guard rect != cell.shown else { return }
        cell.shown = rect
        cell.layer.frame = rect
        cell.image.frame = CGRect(origin: .zero, size: rect.size)
        cell.mark.frame = CGRect(x: 0, y: (height - 20) / 2, width: frame.width, height: 20)
    }

    private func takeCell(for file: Int) -> Cell {
        let cell = pool.popLast() ?? makeCell()
        cell.shown = .null
        if cell.layer.superlayer == nil { contentLayer.addSublayer(cell.layer) }
        cell.layer.isHidden = false
        fill(cell, file: file, fade: false)
        return cell
    }

    private func recycle(_ file: Int) {
        guard let cell = cells.removeValue(forKey: file) else { return }
        cell.layer.isHidden = true
        cell.image.contents = nil
        cell.image.removeAllAnimations()
        pool.append(cell)
    }

    private func makeCell() -> Cell {
        let cell = Cell()
        // The placeholder is a frame of the cell's shape; the picture covers it (centre crop to the cell) once it
        // comes, clipped to the same radius.
        cell.layer.cornerCurve = .continuous
        cell.layer.cornerRadius = cornerRadius
        cell.layer.borderColor = Self.placeholderBorder
        cell.image.masksToBounds = true
        cell.image.cornerCurve = .continuous
        cell.image.cornerRadius = cornerRadius
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

    /// The cell's look for what the file has: its picture (faded in when `fade`), the "no thumbnail" ×, or the frame.
    private func fill(_ cell: Cell, file: Int, fade: Bool) {
        let image = pictures[file]
        let isUnavailable = image == nil && unavailable.contains(file)
        cell.image.contents = image
        cell.mark.isHidden = !isUnavailable
        cell.layer.backgroundColor = isUnavailable ? Self.unavailableColor : nil
        cell.layer.borderWidth = image == nil && !isUnavailable ? 1 : 0
        guard fade, image != nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = Self.fadeDuration
        cell.image.add(animation, forKey: "fade")
    }

    // MARK: Pictures

    /// The file's picture; nil puts the frame back. A picture over the frame fades in; one replacing another (a
    /// new size) swaps at once, so a resize does not flicker.
    func setImage(_ image: CGImage?, forFile file: Int) {
        let had = pictures[file] != nil
        pictures[file] = image
        unavailable.remove(file)
        guard let cell = cells[file] else { return }
        withoutAnimation { fill(cell, file: file, fade: !had) }
    }

    /// The darker "no thumbnail" cell with a ×: the file could not be read or decoded.
    func setUnavailable(forFile file: Int) {
        pictures[file] = nil
        unavailable.insert(file)
        guard let cell = cells[file] else { return }
        withoutAnimation { fill(cell, file: file, fade: false) }
    }

    /// The controller no longer keeps the file's picture (far from the window): a cell for it shows what it has
    /// until the controller asks again.
    func forget(_ file: Int) {
        pictures[file] = nil
        unavailable.remove(file)
    }

    /// Another playlist: every picture goes, the cells show frames until the new ones come.
    func forgetAll() {
        pictures = [:]
        unavailable = []
        withoutAnimation { for (file, cell) in cells { fill(cell, file: file, fade: false) } }
    }

    // MARK: Hover label

    /// "N / M · name" of the file under the cursor, over its cell.
    func showLabel(file: Int, name: String) {
        label.text = "\(file + 1) / \(layout.fileCount) · \(name)"
        labelFile = file
        placeLabel()
    }

    /// The cursor left the strip (or the controller dropped the hover: hidden, window not key, another playlist).
    func endHover() {
        label.isHidden = true
        labelFile = nil
        hoverPoint = nil
    }

    /// Centred over the file's cell, inside the window: the view spans the window's width, and a tall strip can push
    /// the label against the window's top. Hidden while the cell is off screen or a drag moves the strip.
    private func placeLabel() {
        guard let file = labelFile, press?.dragging != true, let c = shownCells.first(where: { $0.file == file }) else {
            label.isHidden = true
            return
        }
        label.isHidden = false
        let gap = Self.labelGap, size = label.fittingSize
        let width = min(size.width, max(40, bounds.width - 2 * gap))
        let left = min(max(CGFloat(c.x + c.width / 2) - width / 2, gap), max(gap, bounds.width - gap - width))
        var bottom = Self.padding + CGFloat(layout.cellHeight) + gap
        if let superview { bottom = min(bottom, convert(superview.bounds, from: superview).maxY - gap - size.height) }
        label.frame = CGRect(x: left, y: bottom, width: width, height: size.height)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited,
                                                              .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    private var zone: StripHitZone {
        StripHitZone(width: Double(bounds.width), height: Double(bounds.height), padding: Double(Self.padding))
    }

    private func inResizeBand(_ p: NSPoint) -> Bool {
        acceptsMouse && zone.inResizeBand(x: Double(p.x), y: Double(p.y))
    }

    /// Where the cursor counts as over the strip; fading out, nowhere.
    private func inHoverZone(_ p: NSPoint) -> Bool {
        acceptsMouse && zone.inHoverZone(x: Double(p.x), y: Double(p.y))
    }

    /// The file whose cell, as shown, is under view x (half a gap on each side counts), nil beside the cells.
    private func file(atX x: CGFloat) -> Int? {
        let half = layout.gap / 2, x = Double(x)
        return shownCells.first { x >= $0.x - half && x < $0.x + $0.width + half }?.file
    }

    /// Ends a drag of the top edge whose mouse-up never came (Mission Control, a sheet, the window closing, a
    /// full-screen change): the controller restores the start height and does not save.
    func cancelResize() {
        guard resizeStart != nil else { return }
        resizeStart = nil
        NSCursor.arrow.set()
        onResizeEnd?(false)
    }

    /// Ends a press whose mouse-up never came (the same cases as `cancelResize`): a drag ends as at a release, a
    /// click is dropped.
    func cancelPress() {
        guard let press else { return }
        self.press = nil
        if press.dragging { onDragEnd?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancelResize()
        cancelPress()
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
    override func mouseExited(with event: NSEvent) { hover(event) }

    /// Moves arrive only while no button is down, so a resize or press still on lost its mouse-up without the window
    /// resigning key (which `cancelResize` / `cancelPress` cover): it ends as cut off.
    private func endLostPress() {
        guard resizeStart != nil || press != nil, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        cancelResize()
        cancelPress()
    }

    /// A mouse move anywhere in the window (the controller's tracking area): a press that lost its mouse-up outside
    /// the strip ends there.
    func trackOutside(_ event: NSEvent) { endLostPress() }

    /// Not during a press or a drag of the top edge: the hover stays as it was at the press.
    private func hover(_ event: NSEvent) {
        guard press == nil, resizeStart == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        hoverPoint = inHoverZone(p) ? p : nil
        onHover?(hoverPoint.flatMap { file(atX: $0.x) })
    }

    /// The cells moved under a cursor that did not (new aspects, the strip settled): the file under it again.
    func refreshHover() {
        guard let p = hoverPoint, press == nil else { return }
        onHover?(file(atX: p.x))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Taken here so the press never reaches the picture underneath (no pan starts on the strip). The grab band on
    /// the top edge starts a resize; a press on the cells a click or a drag; anywhere else nothing.
    override func mouseDown(with event: NSEvent) {
        // A press while a drag is still on means its mouse-up was lost.
        cancelResize()
        cancelPress()
        let p = convert(event.locationInWindow, from: nil)
        if inResizeBand(p) {
            resizeStart = (event.locationInWindow.y, StripResizeDrag(startHeight: Double(layout.cellHeight)))
            return
        }
        guard inHoverZone(p) else { return }
        press = (event.locationInWindow.x, event.locationInWindow.x, file(atX: p.x), false)
    }

    override func mouseDragged(with event: NSEvent) {
        if let resizeStart {
            let height = resizeStart.drag.height(forDrag: Double(event.locationInWindow.y - resizeStart.y))
            onResizeDrag?(CGFloat(height) + 2 * Self.padding)
            return
        }
        guard var press else { return }
        let x = event.locationInWindow.x
        if !press.dragging {
            guard abs(x - press.startX) >= Self.clickSlop else { return }
            press.dragging = true
            label.isHidden = true
        }
        let dx = x - press.lastX
        press.lastX = x
        self.press = press
        if dx != 0 { onDrag?(dx) }
    }

    override func mouseUp(with event: NSEvent) {
        if resizeStart != nil {
            resizeStart = nil
            onResizeEnd?(true)
            hover(event)   // the hover was held during the drag
            setCursor(for: event)
            return
        }
        guard let press else { return }
        self.press = nil
        if press.dragging {
            onDragEnd?()
        } else if let file = press.file {
            onPress?(file)
        }
        hover(event)   // the drag may have left the strip
    }

    // The middle, back and forward buttons are the viewer's bindings over the strip too (`MouseButtons`, as in
    // `ViewerView`); the left button stays the strip's own (a click, a drag, a resize).
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

    /// A press of the strip's own is on (a click, a drag or a resize of its top edge), until its mouse-up.
    var isPressed: Bool { resizeStart != nil || press != nil }

    /// Fading out, the strip already lets clicks through to the picture; before its first show too.
    var acceptsMouse = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsMouse, !isHidden else { return nil }
        return super.hitTest(point)
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// The hover label: "137 / 200 · name" on a glass capsule, 12 pt, digits of one width. Takes no clicks.
@MainActor final class StripLabelView: NSView {
    private let glass = NSGlassEffectView()
    private let field = NSTextField(labelWithString: "")

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        glass.contentView = content
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var fittingSize: NSSize {
        let text = field.intrinsicContentSize
        return NSSize(width: ceil(text.width) + 20, height: ceil(text.height) + 6)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
