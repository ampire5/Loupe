import AppKit
import ExtensionFoundation
import ExtensionKit
import LoupeCore

extension AppExtensionPoint {
    @Definition
    static var playback: AppExtensionPoint {
        Name("Playback")
        Scope(restriction: .none)
        UserInterface()
    }
}

@objc private protocol PlaybackService {
    func handshake(_ reply: @escaping @Sendable (Int, Int32) -> Void)
    func open(_ readOnlyFile: FileHandle, reply: @escaping @Sendable (String) -> Void)
    func step(_ count: Int, reply: @escaping @Sendable (String) -> Void)
    func play()
    func pause()
    func togglePlayback()
    func togglePlaybackColor(_ automatic: Bool)
    func seek(_ seconds: Double, reply: @escaping @Sendable (String) -> Void)
    func close()
    func playbackTime(_ reply: @escaping @Sendable (Double) -> Void)
    func status(_ reply: @escaping @Sendable (String) -> Void)
    func playbackKeys(_ reply: @escaping @Sendable ([String]) -> Void)
    func playbackKey(_ keyCode: UInt16, characters: String, flags: UInt, repeating: Bool)
    func playbackScroll(_ x: Double, y: Double, time: Double, flags: UInt,
                        precise: Bool, began: Bool, phased: Bool, momentum: Bool, notches: UInt16,
                        reply: @escaping @Sendable () -> Void)
    func cancelPlaybackScroll()
}

/// Discovery alone never activates the provider or opens its scene.
@MainActor
private enum PlaybackDiscovery {
    static let providerID = "local.framescrub.playback"
    private static var cachedMonitor: AppExtensionPoint.Monitor?
    private static var request: Task<AppExtensionPoint.Monitor, any Error>?

    static func monitor() async throws -> AppExtensionPoint.Monitor {
        if let cachedMonitor { return cachedMonitor }
        if let request { return try await request.value }
        let request = Task {
            defer { self.request = nil }
            let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .playback)
            cachedMonitor = monitor
            return monitor
        }
        self.request = request
        return try await request.value
    }

    static func identity(in monitor: AppExtensionPoint.Monitor) -> AppExtensionIdentity? {
        monitor.state.identities.first { $0.bundleIdentifier == providerID }
    }
}

/// A single visible media selection. Moving away drops the entire remote scene and its connection.
@MainActor
final class EmbeddedPlayback: NSViewController, NSMenuDelegate {
    private static let fileSlots = DecodePool(slots: 1)
    private static let posterSlots = DecodePool(slots: 1)
    private static let sceneID = "player"
    private static let inputModifiers: NSEvent.ModifierFlags = [.control, .shift, .option, .command]

    private var selected: URL?
    private var kind: PlaybackMedia?
    private var selection = UUID()
    private var active = false
    private var mayPlay = false
    private var autoplay = false
    private var autoplayTried = false
    private var autoplayStarting = false
    private var posterTask: Task<Void, Never>?
    private var frameScrubInstalled = false
    private var activationTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var remote: RemoteScene?
    private var failure = false
    private var ready = false {
        didSet { if ready != oldValue { onTransportVisibilityChange?() } }
    }
    private var input = PlaybackInput()
    private var rightClickOrigin: CGPoint?
    private var rightWheel = MediaScrubGesture()
    private var rightWheelAxis = GestureAxisLock()
    private var firstScrub: Int?
    private var trackingNavigation = false
    private var gestureFlags: NSEvent.ModifierFlags?
    private let scrubLockButton = NSButton(title: "Scrub Lock", target: nil, action: nil)
    private let poster = NSImageView()
    private let actions = NSStackView()
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let openWithButton = NSButton(title: "Open With", target: nil, action: nil)
    private let handoffButton = NSButton(title: "Open in FrameScrub", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var openWithMenu: NSMenu?

    var hasRemotePicture: Bool { ready }
    // Protocol 5 docks its transport in a 48-point row. This also clears the shorter legacy row.
    var transportLayout: PlaybackTransportLayout { .init(height: ready ? 48 : 0) }
    var onTransportVisibilityChange: (() -> Void)?
    var onTrackpadNavigation: (([CGPoint], TimeInterval) -> Void)?
    var onCancelTrackpadNavigation: (() -> Void)?

    override func loadView() {
        let surface = PlaybackSurface()
        surface.controls = actions
        surface.allowedTouchTypes = [.indirect]
        surface.onTouches = { [weak self] event in self?.trackNavigation(event) }
        surface.onTouchesCancelled = { [weak self] in self?.cancelNavigation() }
        surface.wantsLayer = true
        view = surface
        view.isHidden = true
        poster.wantsLayer = true
        poster.layer?.backgroundColor = NSColor.black.cgColor
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(poster)

        playButton.target = self
        playButton.action = #selector(play)
        openWithButton.target = self
        openWithButton.action = #selector(openWith)
        handoffButton.target = self
        handoffButton.action = #selector(handoff)
        scrubLockButton.target = self
        scrubLockButton.action = #selector(toggleScrubLock)
        scrubLockButton.setButtonType(.pushOnPushOff)
        scrubLockButton.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: nil)
        scrubLockButton.toolTip = "Toggle Scrub Lock (⇧⌃). Press Esc to exit."
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        for control in [playButton, openWithButton, handoffButton, scrubLockButton] {
            control.bezelStyle = .rounded
            control.imagePosition = .imageOnly
        }
        openWithButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Open With")
        openWithButton.toolTip = "Open With"
        handoffButton.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Open in FrameScrub")
        handoffButton.toolTip = "Open in FrameScrub"
        scrubLockButton.setAccessibilityLabel("Scrub Lock")
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 4
        actions.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        actions.appearance = NSAppearance(named: .darkAqua)
        actions.wantsLayer = true
        actions.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.86).cgColor
        actions.layer?.cornerRadius = 8
        [openWithButton, scrubLockButton, handoffButton, progress].forEach(actions.addArrangedSubview)
        actions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actions)
        playButton.controlSize = .large
        playButton.isBordered = false
        playButton.focusRingType = .exterior
        playButton.contentTintColor = .white
        playButton.wantsLayer = true
        playButton.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.88).cgColor
        playButton.layer?.cornerRadius = 28
        playButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playButton)
        surface.play = playButton
        NSLayoutConstraint.activate([
            poster.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            poster.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            poster.topAnchor.constraint(equalTo: view.topAnchor),
            poster.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            actions.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            actions.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            playButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 56),
            playButton.heightAnchor.constraint(equalToConstant: 56),
        ])
    }

    /// AppKit can briefly report a key/full-screen viewer as occluded. Build its fallback surface
    /// separately from the stricter permission to start reads and a remote player.
    func update(url: URL?, mayPlay: Bool, active: Bool, autoplay: Bool) {
        if active && !self.active { autoplayTried = false }
        self.active = active
        self.autoplay = autoplay
        if self.mayPlay != mayPlay {
            DebugLog.log("playback: window permits work=\(mayPlay)")
            self.mayPlay = mayPlay
            if !mayPlay { autoplayTried = false }
        }
        if selected != url {
            reset()
            selected = url
            if let url, PlaybackMedia.candidate(url) == .video {
                showPoster(for: .video, image: nil)
            }
        }
        if !mayPlay {
            if remote != nil || activationTask != nil {
                stopProvider()
                autoplayTried = false
                refresh()
            }
            posterTask?.cancel()
            posterTask = nil
            return
        }
        if autoplayStarting && (!active || !autoplay) {
            stopProvider()
            autoplayTried = false
            refresh()
        }
        if posterTask == nil, let url = selected, let candidate = PlaybackMedia.candidate(url) {
            loadPoster(for: url, candidate: candidate)
        }
        maybeAutoplay()
    }

    func reset() {
        selection = UUID()
        selected = nil
        kind = nil
        autoplayTried = false
        failure = false
        posterTask?.cancel()
        posterTask = nil
        stopProvider()
        if isViewLoaded {
            poster.image = nil
            progress.stopAnimation(nil)
            progress.isHidden = true
            view.isHidden = true
        }
    }

    func step(_ count: Int) {
        guard ready else { return }
        remote?.step(count)
    }

    var hasPendingFrameSteps: Bool { remote?.hasPendingFrameSteps == true }

    func readPresentedTime(_ reply: @escaping @Sendable (Double) -> Void) {
        guard ready, let service = remote?.service else { reply(-1); return }
        service.playbackTime(reply)
    }

    var isRightWheelScrubbing: Bool { rightWheel.isScrubbing }

    func releaseRightWheel() {
        rightWheel.release()
        rightWheelAxis.reset()
    }

    func beginRightClick(_ event: NSEvent, viewer: ViewerView) {
        releaseRightWheel()
        cancelInputChord()
        cancelRightClick()
        guard !ready, NSEvent.pressedMouseButtons & ~2 == 0, mayPlay, kind != nil,
              viewer.canClaimPlaybackScrub,
              isPlaybackPicture(event, viewer: viewer) else { return }
        rightClickOrigin = event.locationInWindow
    }

    func cancelRightClick() { rightClickOrigin = nil }

    func moveRightClick(_ event: NSEvent) {
        guard let origin = rightClickOrigin else { return }
        let point = event.locationInWindow
        if max(abs(point.x - origin.x), abs(point.y - origin.y)) >= RMBZoom.clickSlopPoints {
            cancelRightClick()
        }
    }

    func endRightClick(_ event: NSEvent, viewer: ViewerView) {
        defer {
            cancelRightClick()
            releaseRightWheel()
        }
        moveRightClick(event)
        guard rightClickOrigin != nil, mayPlay, !ready, !rightWheel.isScrubbing,
              viewer.canClaimPlaybackScrub, isPlaybackPicture(event, viewer: viewer) else { return }
        // The viewer also tracks the press under the poster for its normal RMB drag handling.
        // Clear the click action there and let AppKit deliver the release for cleanup.
        viewer.claimPlaybackScrub()
        play()
    }

    private func isPlaybackPicture(_ event: NSEvent, viewer: ViewerView) -> Bool {
        event.modifierFlags.isDisjoint(with: Self.inputModifiers)
            && containsPlayer(event.locationInWindow, posterOver: viewer)
            && !overTransport(event.locationInWindow)
    }

    private var supportsInput: Bool { ready && remote?.playbackKeys != nil }

    @objc private func toggleScrubLock() {
        guard supportsInput else { return }
        let wasLocked = input.locked
        input.toggleLock()
        updateLock(wasLocked: wasLocked)
    }

    func playbackModifiers(_ event: NSEvent) {
        if !event.modifierFlags.isDisjoint(with: Self.inputModifiers) { cancelRightClick() }
        guard supportsInput, view.window?.isKeyWindow == true else { return }
        let flags = event.modifierFlags.intersection(Self.inputModifiers)
        if !flags.isSubset(of: [.control, .shift]) {
            input.cancelChord()
            return
        }
        let wasLocked = input.locked
        input.modifiers(lockChord: flags == [.control, .shift], none: flags.isEmpty)
        updateLock(wasLocked: wasLocked)
    }

    func cancelInputChord() { input.cancelChord() }

    private func updateLock(wasLocked: Bool) {
        guard wasLocked != input.locked else { return }
        if !input.locked { remote?.cancelScroll() }
        updateLockButton()
    }

    private func updateLockButton() {
        scrubLockButton.state = input.locked ? .on : .off
        scrubLockButton.image = NSImage(systemSymbolName: input.locked ? "lock.fill" : "lock.open",
                                       accessibilityDescription: nil)
        scrubLockButton.contentTintColor = input.locked ? .controlAccentColor : nil
    }

    func playbackKey(_ event: NSEvent) -> Bool {
        input.cancelChord()
        let flags = event.modifierFlags.intersection(Self.inputModifiers)
        if event.keyCode == 49, flags.isEmpty, !input.locked, isViewLoaded, !view.isHidden,
           !(view.window?.firstResponder is NSTextInputClient) {
            if !ready {
                if !event.isARepeat { play() }
                return true
            }
            if let scene = remote, scene.version >= 5 {
                if !event.isARepeat { scene.service?.togglePlayback() }
                return true
            }
        }
        if flags.isEmpty, !input.locked, ready, let scene = remote, scene.version >= 6,
           !(view.window?.firstResponder is NSTextInputClient) {
            switch KeyboardLayout.characters(for: event)?.lowercased() {
            case "c":
                if !event.isARepeat { scene.service?.togglePlaybackColor(true) }
                return true
            case "v":
                if !event.isARepeat { scene.service?.togglePlaybackColor(false) }
                return true
            default: break
            }
        }
        guard supportsInput, input.locked else { return false }
        if event.keyCode == 53 {
            toggleScrubLock()
            return true
        }
        guard let scene = remote, !(view.window?.firstResponder is NSTextInputClient),
              !event.modifierFlags.contains(.command), event.keyCode != 48 else { return false }
        let characters = KeyboardLayout.characters(for: event) ?? ""
        let character = flags.contains(.shift) ? characters.uppercased() : characters
        let characterFlags = flags.subtracting(.shift).rawValue
        guard scene.playbackKeys?.contains("\(flags.rawValue):#\(event.keyCode)") == true
            || scene.playbackKeys?.contains("\(characterFlags):=\(character)") == true else { return false }
        scene.service?.playbackKey(event.keyCode, characters: characters, flags: flags.rawValue, repeating: event.isARepeat)
        return true
    }

    private func containsPlayer(_ location: CGPoint, posterOver viewer: ViewerView? = nil) -> Bool {
        guard isViewLoaded, !view.isHidden, let content = view.window?.contentView,
              let hit = content.hitTest(content.convert(location, from: nil)) else { return false }
        if let viewer, hit === viewer, view.bounds.contains(view.convert(location, from: nil)) { return true }
        return (hit === view || hit.isDescendant(of: view))
            && hit !== actions && !hit.isDescendant(of: actions)
    }

    private func overTransport(_ location: CGPoint) -> Bool {
        transportLayout.contains(view.convert(location, from: nil).y - view.bounds.minY)
    }

    func isPictureDoubleClick(_ event: NSEvent) -> Bool {
        ready && event.clickCount == 2 && event.modifierFlags.intersection(Self.inputModifiers).isEmpty
            && containsPlayer(event.locationInWindow) && !overTransport(event.locationInWindow)
    }

    private func trackNavigation(_ event: NSEvent) {
        guard ready else { return }
        let points = event.touches(matching: .touching, in: nil).map(\.normalizedPosition)
        if !trackingNavigation, points.count == 3, NSEvent.pressedMouseButtons == 0,
           containsPlayer(event.locationInWindow), !overTransport(event.locationInWindow) {
            trackingNavigation = true
            if input.claimNavigation() { remote?.cancelScroll() }
        }
        guard trackingNavigation else { return }
        if points.isEmpty { trackingNavigation = false }
        onTrackpadNavigation?(points, event.timestamp)
    }

    private func cancelNavigation() {
        guard trackingNavigation else { return }
        trackingNavigation = false
        onCancelTrackpadNavigation?()
    }

    func playbackScroll(_ event: NSEvent, viewer: ViewerView) -> Bool {
        if event.momentumPhase.isEmpty, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            cancelRightClick()
        }
        if scrubRightWheel(event, viewer: viewer) { return true }
        let inside = containsPlayer(event.locationInWindow)
        let flags = event.modifierFlags.intersection(Self.inputModifiers)
        let phase: PlaybackInput.Phase
        if !event.momentumPhase.isEmpty {
            phase = !event.momentumPhase.isDisjoint(with: [.ended, .cancelled]) ? .momentumEnd : .momentum
        } else if event.phase.contains(.cancelled) {
            phase = .cancel
        } else if event.phase.contains(.ended) {
            phase = .end
        } else if event.phase.contains(.mayBegin) {
            return false
        } else if event.phase.contains(.began) {
            phase = .begin
        } else {
            phase = event.phase.isEmpty ? .notch : .change
        }
        let isOverTransport = inside && overTransport(event.locationInWindow)
        let eligible = inside && supportsInput && (input.locked || flags.contains(.control))
        switch input.scroll(phase, eligible: eligible, overTransport: isOverTransport,
                            trackingNavigation: trackingNavigation && event.hasPreciseScrollingDeltas) {
        case .discard, .transport:
            return true
        case .viewer:
            gestureFlags = nil
            guard inside, ready else { return false }
            viewer.scrollWheel(with: event)
            return true
        case .player:
            if phase == .begin || phase == .notch || gestureFlags == nil {
                gestureFlags = input.locked ? flags : flags.subtracting(.control)
            }
            remote?.sendScroll(.init(x: event.scrollingDeltaX, y: event.scrollingDeltaY, time: event.timestamp,
                flags: (gestureFlags ?? []).rawValue, precise: event.hasPreciseScrollingDeltas,
                began: phase == .begin, phased: !event.phase.isEmpty, momentum: !event.momentumPhase.isEmpty))
            if phase == .notch || phase == .cancel || phase == .momentumEnd { gestureFlags = nil }
            return true
        }
    }

    private func scrubRightWheel(_ event: NSEvent, viewer: ViewerView) -> Bool {
        let buttons = NSEvent.pressedMouseButtons
        if buttons & 2 == 0 { releaseRightWheel() }
        let precise = event.hasPreciseScrollingDeltas
        let phase = ScrollPhase(rawValue: event.phase.rawValue)
        let momentum = ScrollPhase(rawValue: event.momentumPhase.rawValue)
        let dy = buttons == 2 ? rightWheelAxis.filter(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            precise: precise, momentum: !momentum.isEmpty, began: phase.contains(.began),
            phased: !phase.isEmpty, at: event.timestamp).y : 0
        let held = rightWheel.isScrubbing
        let canStart = !held && dy != 0 && mayPlay && kind != nil && !trackingNavigation
            && viewer.canClaimPlaybackScrub
            && containsPlayer(event.locationInWindow, posterOver: viewer)
            && !overTransport(event.locationInWindow)
        let forward = Settings.shared.config.wheelDirection.isNext(deltaY: dy,
            invertedFromDevice: event.isDirectionInvertedFromDevice)
        guard let steps = rightWheel.scroll(delta: forward ? abs(dy) : -abs(dy),
            precise: precise, phase: phase, momentum: momentum, canStart: canStart) else { return false }
        if !held, rightWheel.isScrubbing {
            input.claimNavigation()
            // The remote picture receives its own right-button events, but Loupe receives the wheel.
            remote?.cancelScroll()
            viewer.claimPlaybackScrub()
        }
        if steps != 0 {
            if ready {
                step(steps)
            } else if rightWheel.isScrubbing {
                firstScrub = (firstScrub ?? 0) + steps
                requestPlayback(automatically: false)
            }
        }
        return true
    }

    private func loadPoster(for url: URL, candidate: PlaybackMedia) {
        let selection = self.selection
        posterTask = Task { [weak self] in
            let result = try? await Self.posterSlots.run(forCurrent: true, rank: 0) {
                switch candidate {
                case .video: return (true, try? PlaybackMedia.videoPoster(url, maximumSide: 1280))
                case .animation: return PlaybackMedia.animationPoster(url, maximumSide: 1280)
                }
            }
            guard !Task.isCancelled, let self, self.selection == selection else { return }
            if let (matched, image) = result, matched { self.showPoster(for: candidate, image: image) }
        }
    }

    private func showPoster(for kind: PlaybackMedia, image: CGImage?) {
        if self.kind != kind { DebugLog.log("playback: showing \(kind) poster surface") }
        if self.kind != kind, kind == .video {
            frameScrubInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.framescrub") != nil
        }
        self.kind = kind
        view.isHidden = false
        if let image {
            poster.image = NSImage(cgImage: image, size: .zero)
        } else if kind == .video {
            poster.image = NSImage(systemSymbolName: "film", accessibilityDescription: "Video")
            poster.imageScaling = .scaleProportionallyDown
        }
        if image != nil { poster.imageScaling = .scaleProportionallyUpOrDown }
        refresh()
        maybeAutoplay()
    }

    private func maybeAutoplay() {
        guard mayPlay, active, autoplay, kind != nil, !autoplayTried, remote == nil, activationTask == nil else { return }
        autoplayTried = true
        requestPlayback(automatically: true)
    }

    @objc private func play() { requestPlayback(automatically: false) }

    private func requestPlayback(automatically: Bool) {
        guard mayPlay, selected != nil, kind != nil, remote == nil, activationTask == nil else { return }
        failure = false
        autoplayStarting = automatically
        let selection = self.selection
        activationTask = Task { [weak self] in
            let monitor = try? await PlaybackDiscovery.monitor()
            guard !Task.isCancelled, let self, self.selection == selection else { return }
            self.activationTask = nil
            guard let monitor, let identity = PlaybackDiscovery.identity(in: monitor) else {
                self.fail("enabled FrameScrub extension not found")
                return
            }
            self.start(identity)
        }
        refresh()
    }

    private func start(_ identity: AppExtensionIdentity) {
        let scene = RemoteScene()
        scene.onActivate = { [weak self, weak scene] in
            guard let self, let scene, self.remote === scene else { return }
            self.connect(scene)
        }
        scene.onDisconnect = { [weak self, weak scene] reason in
            guard let self, let scene, self.remote === scene else { return }
            self.fail(reason)
        }
        remote = scene
        addChild(scene)
        let embeddedView = scene.view
        embeddedView.allowedTouchTypes = [.indirect]
        embeddedView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(embeddedView, positioned: .below, relativeTo: poster)
        NSLayoutConstraint.activate([
            embeddedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            embeddedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            embeddedView.topAnchor.constraint(equalTo: view.topAnchor),
            embeddedView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        scene.configuration = .init(appExtension: identity, sceneID: Self.sceneID)
        deadline = Task { [weak self, weak scene] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, let scene, self.remote === scene else { return }
            self.fail("provider did not present a picture before the timeout")
        }
        refresh()
    }

    private func connect(_ scene: RemoteScene) {
        guard scene.connection == nil else { return }
        do {
            let connection = try scene.makeXPCConnection()
            connection.remoteObjectInterface = NSXPCInterface(with: PlaybackService.self)
            let disconnected: @Sendable (String) -> Void = { [weak scene] reason in
                Task { @MainActor in scene?.onDisconnect?(reason) }
            }
            // Foundation invokes these blocks on the connection queue even when set up on MainActor.
            connection.invalidationHandler = { @Sendable in disconnected("provider XPC connection invalidated") }
            connection.interruptionHandler = { @Sendable in disconnected("provider XPC connection interrupted") }
            let proxyError: @Sendable (Error) -> Void = { error in
                disconnected("provider XPC call failed: \(error)")
            }
            connection.resume()
            scene.connection = connection
            scene.service = connection.remoteObjectProxyWithErrorHandler(proxyError) as? PlaybackService
            guard let service = scene.service else { fail("no XPC playback service"); return }
            service.handshake { [weak self, weak scene] version, pid in
                Task { @MainActor in
                    guard let self, let scene, self.remote === scene else { return }
                    guard (3...6).contains(version) else { self.fail("incompatible protocol version \(version)"); return }
                    scene.version = version
                    DebugLog.log("playback: provider handshake v\(version), pid=\(pid)")
                    self.openSelection(on: scene)
                }
            }
        } catch {
            fail("could not connect to the playback scene: \(error)")
        }
    }

    private func openSelection(on scene: RemoteScene) {
        guard let url = selected else { return }
        openTask = Task { [weak self, weak scene] in
            let file = try? await Self.fileSlots.run(forCurrent: true, rank: 0) {
                try FileHandle(forReadingFrom: url)
            }
            guard !Task.isCancelled, let self, let scene, self.remote === scene else { return }
            guard let file, let service = scene.service else { self.fail("could not open read-only media"); return }
            service.open(file) { [weak self, weak scene] result in
                Task { @MainActor in
                    guard let self, let scene, self.remote === scene else { return }
                    DebugLog.log("playback: provider open reply: \(result)")
                    guard result == "ready" else { self.fail("provider could not open the media"); return }
                    self.deadline?.cancel()
                    self.deadline = nil
                    self.ready = true
                    self.autoplayStarting = false
                    self.refresh()
                    if scene.version >= 4 {
                        scene.service?.playbackKeys { [weak self, weak scene] keys in
                            Task { @MainActor in
                                guard let self, let scene, self.remote === scene else { return }
                                scene.playbackKeys = Set(keys)
                                self.refresh()
                            }
                        }
                    }
                    if let steps = self.firstScrub {
                        self.firstScrub = nil
                        scene.step(steps)
                    } else {
                        scene.service?.play()
                    }
                }
            }
        }
    }

    private func fail(_ reason: String) {
        DebugLog.log("playback: \(reason)")
        failure = true
        stopProvider()
        refresh()
    }

    private func stopProvider() {
        cancelNavigation()
        cancelRightClick()
        input.exit()
        rightWheel.cancel()
        firstScrub = nil
        gestureFlags = nil
        updateLockButton()
        autoplayStarting = false
        deadline?.cancel()
        deadline = nil
        activationTask?.cancel()
        activationTask = nil
        openTask?.cancel()
        openTask = nil
        if let scene = remote {
            remote = nil
            scene.onActivate = nil
            scene.onDisconnect = nil
            scene.service?.close()
            scene.service = nil
            scene.configuration = nil
            scene.connection?.invalidate()
            scene.connection = nil
            scene.view.removeFromSuperview()
            scene.removeFromParent()
        }
        ready = false
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let loading = activationTask != nil || (remote != nil && !ready)
        (view as? PlaybackSurface)?.forwardsToProvider = ready
        poster.isHidden = ready
        playButton.isHidden = loading || ready
        let playLabel = failure ? "Retry Playback" : "Play"
        playButton.setAccessibilityLabel(playLabel)
        let playIcon = NSImage(systemSymbolName: failure ? "arrow.clockwise" : "play.fill",
                               accessibilityDescription: playLabel)
        playButton.image = playIcon?.withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
        playButton.toolTip = "\(playLabel) (Space)"
        openWithButton.isHidden = ready || loading
        handoffButton.isHidden = kind != .video || !frameScrubInstalled
        scrubLockButton.isHidden = !supportsInput
        if loading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.isHidden = !loading
        actions.isHidden = actions.arrangedSubviews.allSatisfy(\.isHidden)
        // Keep pointer and keyboard navigation available outside the buttons until the scene is ready.
        view.setAccessibilityLabel(loading ? "Loading media" : nil)
    }

    @objc private func handoff() {
        guard let url = selected else { return }
        let selection = self.selection
        if ready, let scene = remote, let service = scene.service {
            service.playbackTime { [weak self, weak scene] time in
                Task { @MainActor in
                    guard let self, let scene, self.remote === scene, self.selection == selection else { return }
                    self.openFrameScrub(url, at: time)
                }
            }
        } else {
            openFrameScrub(url, at: 0)
        }
    }

    private func openFrameScrub(_ url: URL, at time: Double) {
        guard let link = PlaybackMedia.frameScrubLink(for: url, presentedTime: time) else { return }
        if NSWorkspace.shared.open(link) {
            remote?.service?.pause()
        }
    }

    @objc private func openWith() {
        guard let selected else { return }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Playback Extensions…", action: #selector(showExtensions), keyEquivalent: "").target = self
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: selected).filter {
            $0.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL
        }
        if !apps.isEmpty { menu.addItem(.separator()) }
        for app in apps {
            let name = FileManager.default.displayName(atPath: app.path)
            let item = menu.addItem(withTitle: name, action: #selector(openWithApplication(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
        }
        openWithMenu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: openWithButton.bounds.height + 3), in: openWithButton)
    }

    func menuDidClose(_ menu: NSMenu) { openWithMenu = nil }

    @objc private func showExtensions() { PlaybackExtensionSettings.show() }

    @objc private func openWithApplication(_ item: NSMenuItem) {
        guard let selected, let app = item.representedObject as? URL else { return }
        NSWorkspace.shared.open([selected], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

/// While showing the poster, only its controls take clicks. The rest behaves like Loupe's viewer.
private final class PlaybackSurface: NSView {
    weak var controls: NSView?
    weak var play: NSView?
    var forwardsToProvider = false
    var onTouches: ((NSEvent) -> Void)?
    var onTouchesCancelled: (() -> Void)?

    override func touchesBegan(with event: NSEvent) { onTouches?(event) }
    override func touchesMoved(with event: NSEvent) { onTouches?(event) }
    override func touchesEnded(with event: NSEvent) { onTouches?(event) }
    override func touchesCancelled(with event: NSEvent) { onTouchesCancelled?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let play, hit === play || hit.isDescendant(of: play) { return hit }
        if let controls, hit === controls || hit.isDescendant(of: controls) { return hit }
        return forwardsToProvider && hit !== self ? hit : nil
    }
}

@MainActor
private final class RemoteScene: EXHostViewController, EXHostViewControllerDelegate {
    struct Scroll {
        var x: Double
        var y: Double
        var time: Double
        let flags: UInt
        let precise: Bool
        var began: Bool
        let phased: Bool
        let momentum: Bool
        var notches: UInt16 = 1

        mutating func merge(_ input: Self) -> Bool {
            guard !input.began, flags == input.flags, precise == input.precise,
                  momentum == input.momentum, phased == input.phased else { return false }
            if precise {
                x += input.x
                y += input.y
            } else {
                guard x.sign == input.x.sign, y.sign == input.y.sign,
                      (abs(x) > abs(y)) == (abs(input.x) > abs(input.y)) else { return false }
                let (sum, overflow) = notches.addingReportingOverflow(input.notches)
                notches = overflow ? .max : sum
            }
            time = input.time
            return true
        }
    }

    var version = 0
    var playbackKeys: Set<String>?
    var connection: NSXPCConnection?
    var service: PlaybackService?
    var onActivate: (() -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var stepInFlight = false
    private var pendingSteps = 0
    private var scrollInFlight = false
    private var pendingScroll: Scroll?

    var hasPendingFrameSteps: Bool { stepInFlight }

    /// Frame steps wait for the provider to present a frame. Keep only the net travel
    /// accumulated during that request so fast wheel input cannot queue up XPC messages.
    func step(_ count: Int) {
        guard count != 0, let service else { return }
        if stepInFlight {
            pendingSteps += count
            return
        }
        stepInFlight = true
        service.step(count) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stepInFlight = false
                let next = self.pendingSteps
                self.pendingSteps = 0
                self.step(next)
            }
        }
    }

    /// At most one sample on the connection and one coalesced sample waiting behind it.
    func sendScroll(_ sample: Scroll) {
        guard let service else { return }
        if scrollInFlight {
            if pendingScroll?.merge(sample) != true { pendingScroll = sample }
            return
        }
        scrollInFlight = true
        service.playbackScroll(sample.x, y: sample.y, time: sample.time, flags: sample.flags,
                               precise: sample.precise, began: sample.began, phased: sample.phased,
                               momentum: sample.momentum, notches: sample.notches) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scrollInFlight = false
                if let next = self.pendingScroll {
                    self.pendingScroll = nil
                    self.sendScroll(next)
                }
            }
        }
    }

    func cancelScroll() {
        pendingScroll = nil
        if version >= 4 { service?.cancelPlaybackScroll() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }

    override func touchesBegan(with event: NSEvent) { forwardTouches(event) }
    override func touchesMoved(with event: NSEvent) { forwardTouches(event) }
    override func touchesEnded(with event: NSEvent) { forwardTouches(event) }
    override func touchesCancelled(with event: NSEvent) {
        (view.superview as? PlaybackSurface)?.onTouchesCancelled?()
    }

    private func forwardTouches(_ event: NSEvent) {
        (view.superview as? PlaybackSurface)?.onTouches?(event)
    }

    func hostViewControllerDidActivate(_ viewController: EXHostViewController) { onActivate?() }
    func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: (any Error)?) {
        onDisconnect?(error.map { "provider scene deactivated: \($0)" } ?? "provider scene deactivated")
    }
}

@MainActor
enum PlaybackExtensionSettings {
    private static var window: NSWindow?

    static func close() { window?.close() }

    static func show() {
        if window == nil {
            let browser = EXAppExtensionBrowserViewController()
            let extensionWindow = NSWindow(contentViewController: browser)
            extensionWindow.isReleasedWhenClosed = false
            extensionWindow.tabbingMode = .disallowed
            extensionWindow.setContentSize(NSSize(width: 620, height: 360))
            extensionWindow.title = "Playback Extensions"
            extensionWindow.center()
            window = extensionWindow
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
