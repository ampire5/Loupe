import AppKit
import LoupeCore
import LoupeRender
import QuartzCore

/// A comparison tab has two render surfaces and one gesture model. Its cache session
/// is owned by the enclosing viewer tab, just like the regular photo viewer's.
@MainActor final class PhotoComparisonView: NSView {
    private typealias Side = PhotoComparison.Side
    let files: [URL]
    private let left: Pane
    private let right: Pane
    private let link = NSButton(checkboxWithTitle: "Link Pan & Zoom", target: nil, action: nil)
    private let match = NSButton(title: "Match Visual Scale", target: nil, action: nil)
    private var comparison: PhotoComparison?
    private var active: Side = .left
    private var visible: Bool
    private var config: Config

    init(files: [URL], config: Config, visible: Bool) {
        self.files = files
        self.config = config
        self.visible = visible
        left = Pane(url: files[0], config: config)
        right = Pane(url: files[1], config: config)
        super.init(frame: .zero)

        wantsLayer = true
        link.target = self
        link.action = #selector(toggleLink)
        match.target = self
        match.action = #selector(matchScale)
        match.toolTip = "Match the active photo’s displayed size. Available for photos with the same proportions."
        let controls = NSStackView(views: [link, match])
        controls.spacing = 12
        controls.alignment = .centerY

        let divider = NSBox()
        divider.boxType = .separator
        for view in [controls, left, right, divider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            left.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            left.bottomAnchor.constraint(equalTo: bottomAnchor),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.topAnchor.constraint(equalTo: left.topAnchor),
            right.bottomAnchor.constraint(equalTo: bottomAnchor),
            right.widthAnchor.constraint(equalTo: left.widthAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: left.topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for side in Side.allCases {
            let canvas = pane(side).canvas
            canvas.onSelect = { [weak self] in self?.select(side) }
            canvas.onPan = { [weak self] delta in self?.pan(side, by: delta) }
            canvas.onZoom = { [weak self] multiplier, anchor in self?.zoom(side, by: multiplier, at: anchor) }
            canvas.onSwitchSide = { [weak self] in self?.focus(side.other) }
        }
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }

    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    override var wantsUpdateLayer: Bool { true }

    func focus() { focus(active) }

    private func focus(_ side: Side) {
        select(side)
        window?.makeFirstResponder(pane(side).canvas)
    }

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        if visible {
            left.needsRedraw()
            right.needsRedraw()
            updateGeometry()
        }
        else {
            left.canvas.clearGesture()
            right.canvas.clearGesture()
            left.releasePhoto()
            right.releasePhoto()
        }
    }

    func stopRendering() {
        left.canvas.stopRendering()
        right.canvas.stopRendering()
    }

    func receive(_ entry: CacheEntryView<TiledImage>, for url: URL) {
        guard visible, let index = files.firstIndex(of: url) else { return }
        let pane = index == 0 ? left : right
        let sizeChanged = pane.receive(entry, applyingOrientation: config.exifOrientation)
        if sizeChanged { comparison = nil }
        updateGeometry()
    }

    func applyConfig(_ config: Config) {
        guard config != self.config else { return }
        let orientationChanged = config.exifOrientation != self.config.exifOrientation
        let needsRefit = orientationChanged || config.fitUpscale != self.config.fitUpscale
        self.config = config
        if needsRefit { comparison = nil }
        if orientationChanged {
            left.releasePhoto()
            right.releasePhoto()
        }
        left.canvas.applyConfig(config)
        right.canvas.applyConfig(config)
        updateGeometry()
    }

    private func pane(_ side: Side) -> Pane { side == .left ? left : right }

    private func select(_ side: Side) {
        guard active != side else { return }
        active = side
        updateControls()
    }

    private func updateGeometry() {
        guard visible else { return }
        let l = left.canvas.syncDrawableSize(), r = right.canvas.syncDrawableSize()
        guard l.width > 0, l.height > 0, r.width > 0, r.height > 0 else { return }
        if let first = left.imageSize, let second = right.imageSize {
            if comparison == nil {
                comparison = PhotoComparison(
                    ViewTransform(imageSize: first, viewSize: l, fitUpscale: config.fitUpscale),
                    ViewTransform(imageSize: second, viewSize: r, fitUpscale: config.fitUpscale)
                )
            } else {
                comparison?.resize(left: l, right: r)
            }
        }
        draw()
    }

    private func draw() {
        guard visible else { return }
        for side in Side.allCases {
            let pane = pane(side)
            // Each file can appear as soon as its preview is available, while the other is still loading.
            let transform = comparison?[side] ?? ViewTransform(imageSize: pane.imageSize ?? .zero,
                                                               viewSize: pane.canvas.drawableSize,
                                                               fitUpscale: config.fitUpscale)
            pane.draw(transform)
        }
        updateControls()
    }

    private func updateControls() {
        let linked = comparison?.isLinked == true
        if link.isEnabled != (comparison != nil) { link.isEnabled = comparison != nil }
        let linkState: NSControl.StateValue = linked ? .on : .off
        if link.state != linkState { link.state = linkState }
        let canMatch = comparison?.canMatchScale(from: active) == true
        if match.isEnabled != canMatch { match.isEnabled = canMatch }
        left.setActive(active == .left)
        right.setActive(active == .right)
    }

    @objc private func toggleLink() {
        comparison?.isLinked = link.state == .on
        focus()
    }

    @objc private func matchScale() {
        comparison?.matchScale(from: active)
        draw()
        focus()
    }

    private func pan(_ side: Side, by delta: CGVector) {
        if active != side { select(side) }
        comparison?.pan(from: side, by: delta)
        draw()
    }

    private func zoom(_ side: Side, by multiplier: Double, at anchor: CGPoint) {
        if active != side { select(side) }
        comparison?.zoom(from: side, by: multiplier, anchor: anchor)
        draw()
    }

    private final class Pane: NSView {
        let canvas: Canvas
        private let name: NSTextField
        private let scale = NSTextField(labelWithString: "")
        private let status = NSTextField(wrappingLabelWithString: "Loading…")
        private var image: TiledImage?
        private var orientation: ImageOrientation = .up
        private var lastTransform: ViewTransform?
        private(set) var imageSize: CGSize?

        init(url: URL, config: Config) {
            let title = ArchivePath.displayName(url)
            name = NSTextField(labelWithString: title)
            canvas = Canvas(config: config)
            super.init(frame: .zero)
            name.lineBreakMode = .byTruncatingMiddle
            name.toolTip = url.isFileURL ? url.path : title
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            name.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            scale.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            scale.textColor = .secondaryLabelColor
            scale.setContentCompressionResistancePriority(.required, for: .horizontal)
            status.alignment = .center
            status.textColor = .white
            status.wantsLayer = true
            status.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
            canvas.setAccessibilityLabel(title)
            for view in [canvas, name, scale, status] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                name.topAnchor.constraint(equalTo: topAnchor, constant: 3),
                scale.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
                scale.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                scale.centerYAnchor.constraint(equalTo: name.centerYAnchor),
                canvas.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 6),
                canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
                canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
                status.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
                status.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
                status.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        func setActive(_ active: Bool) {
            let color: NSColor = active ? .controlAccentColor : .labelColor
            if name.textColor != color { name.textColor = color }
        }

        func receive(_ entry: CacheEntryView<TiledImage>, applyingOrientation: Bool) -> Bool {
            image = entry.failure == nil ? entry.pyramid : nil
            needsRedraw()
            status.stringValue = entry.failure ?? "Loading…"
            status.isHidden = image != nil
            guard let info = entry.info else { return false }
            orientation = info.drawOrientation(applying: applyingOrientation, seeded: entry.pyramidIsSeeded)
            let size = info.displaySize(applying: applyingOrientation)
            let shown = CGSize(width: size.width, height: size.height)
            let changed = imageSize != shown
            imageSize = shown
            return changed
        }

        func needsRedraw() { lastTransform = nil }

        func releasePhoto() {
            image = nil
            if let lastTransform { canvas.drawPhoto(nil, orientation: .up, transform: lastTransform) }
            status.stringValue = "Loading…"
            status.isHidden = false
            needsRedraw()
        }

        func draw(_ transform: ViewTransform) {
            guard lastTransform != transform else { return }
            if imageSize != nil, lastTransform?.scale != transform.scale {
                let value = transform.scale.formatted(.percent.precision(.fractionLength(0...2)))
                if scale.stringValue != value {
                    scale.stringValue = value
                    canvas.setAccessibilityValue(value)
                }
            }
            lastTransform = transform
            canvas.drawPhoto(image, orientation: orientation, transform: transform)
        }
    }

    private final class Canvas: NSView {
        private var config: Config
        private var renderLoop: RenderLoop?
        private var zoomDragAnchor: CGPoint?
        private var sentBackingScale: CGFloat = 0
        private var metal: CAMetalLayer { layer as! CAMetalLayer }
        var onSelect: (() -> Void)?
        var onPan: ((CGVector) -> Void)?
        var onZoom: ((Double, CGPoint) -> Void)?
        var onSwitchSide: (() -> Void)?

        init(config: Config) {
            self.config = config
            super.init(frame: .zero)
            wantsLayer = true
            layerContentsPlacement = .center
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityHelp("Drag or scroll to pan. Use pinch, Command-scroll, or plus and minus to zoom.")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func makeBackingLayer() -> CALayer {
            let layer = CAMetalLayer()
            layer.device = MetalContext.shared.device
            layer.pixelFormat = .bgra8Unorm_srgb
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            layer.framebufferOnly = false
            layer.isOpaque = true
            layer.backgroundColor = config.background.cgColor
            return layer
        }

        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }
        override func updateLayer() {}
        override var wantsUpdateLayer: Bool { true }

        var drawableSize: CGSize { metal.drawableSize }

        func syncDrawableSize() -> CGSize {
            let backing = window?.backingScaleFactor ?? 1
            let size = CGSize(width: (bounds.width * backing).rounded(), height: (bounds.height * backing).rounded())
            if size.width > 0, size.height > 0 {
                if metal.contentsScale != backing { metal.contentsScale = backing }
                if metal.drawableSize != size { metal.drawableSize = size }
            }
            return size
        }

        func drawPhoto(_ image: TiledImage?, orientation: ImageOrientation, transform: ViewTransform) {
            let loop: RenderLoop
            if let renderLoop {
                loop = renderLoop
            } else {
                guard image != nil else { return }
                loop = RenderLoop(layer: metal)
                loop.setResampling(ResampleSettings(config: config))
                loop.setTransparency(TransparencySettings(config: config))
                loop.setBackground(config.background)
                renderLoop = loop
            }
            if sentBackingScale != metal.contentsScale {
                sentBackingScale = metal.contentsScale
                loop.setBackingScale(sentBackingScale)
            }
            let pages = image.map {
                RenderPages(first: RenderPage(image: $0, orientation: orientation, color: nil,
                                              rect: CGRect(origin: .zero, size: transform.imageSize)))
            } ?? .none
            loop.update(pages: pages, transform: transform)
        }

        func applyConfig(_ config: Config) {
            let previous = self.config
            self.config = config
            if config.background != previous.background {
                metal.backgroundColor = config.background.cgColor
                renderLoop?.setBackground(config.background)
            }
            let resampling = ResampleSettings(config: config)
            if resampling != ResampleSettings(config: previous) { renderLoop?.setResampling(resampling) }
            let transparency = TransparencySettings(config: config)
            if transparency != TransparencySettings(config: previous) { renderLoop?.setTransparency(transparency) }
        }

        func stopRendering() {
            renderLoop?.stop()
            renderLoop = nil
            sentBackingScale = 0
        }

        func clearGesture() { zoomDragAnchor = nil }

        private func point(_ event: NSEvent) -> CGPoint {
            let location = convert(event.locationInWindow, from: nil)
            let backing = window?.backingScaleFactor ?? 1
            return CGPoint(x: location.x * backing, y: location.y * backing)
        }

        private func select() {
            onSelect?()
            window?.makeFirstResponder(self)
        }

        override func mouseDown(with event: NSEvent) { select() }
        override func mouseDragged(with event: NSEvent) {
            let backing = window?.backingScaleFactor ?? 1
            onPan?(CGVector(dx: event.deltaX * backing, dy: event.deltaY * backing))
        }

        override func rightMouseDown(with event: NSEvent) {
            select()
            zoomDragAnchor = point(event)
        }
        override func rightMouseDragged(with event: NSEvent) {
            guard let zoomDragAnchor else { return }
            let direction = config.rmbZoomInvert ? 1.0 : -1.0
            let travel = RMBZoom.pointsPerDoubling(speed: config.rmbZoomSpeed)
            onZoom?(exp2(direction * event.deltaY / travel), zoomDragAnchor)
        }
        override func rightMouseUp(with event: NSEvent) { zoomDragAnchor = nil }

        override func magnify(with event: NSEvent) {
            if event.phase == .began { select() }
            onZoom?(max(0.01, 1 + event.magnification), point(event))
        }

        override func scrollWheel(with event: NSEvent) {
            if event.momentumPhase.isEmpty { select() }
            if event.modifierFlags.contains(.command) {
                let divisor = event.hasPreciseScrollingDeltas ? 120.0 : 6.0
                onZoom?(exp2(event.scrollingDeltaY / divisor), point(event))
            } else {
                let factor = (window?.backingScaleFactor ?? 1) * (event.hasPreciseScrollingDeltas ? 1 : 16)
                onPan?(CGVector(dx: event.scrollingDeltaX * factor, dy: event.scrollingDeltaY * factor))
            }
        }

        override func keyDown(with event: NSEvent) {
            let view = drawableSize
            let center = CGPoint(x: view.width / 2, y: view.height / 2)
            if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                switch event.keyCode {
                case 123: onPan?(CGVector(dx: view.width * 0.1, dy: 0)); return
                case 124: onPan?(CGVector(dx: -view.width * 0.1, dy: 0)); return
                case 125: onPan?(CGVector(dx: 0, dy: -view.height * 0.1)); return
                case 126: onPan?(CGVector(dx: 0, dy: view.height * 0.1)); return
                case 48 where event.modifierFlags.contains(.shift): onSwitchSide?(); return
                default: break
                }
                switch event.charactersIgnoringModifiers {
                case "+", "=": onZoom?(2.0.squareRoot(), center); return
                case "-": onZoom?(1 / 2.0.squareRoot(), center); return
                default: break
                }
            }
            super.keyDown(with: event)
        }
    }
}
