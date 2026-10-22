/// What the photo strip shows in each mode, pinned or hidden, in a window and in full screen (filmstrip spec §2).
/// A pure function of the mode and the pointer, so the rules are tested apart from the views.
///
/// - Window, `beside`: the strip takes its own space unless `hidden` (its T button hides it); hidden, only the
///   reveal chevron near the window's bottom shows. `pinned` plays no part.
/// - Window, `over`: the strip floats; it shows when pinned or when the pointer reached its edge. `hidden` plays no part.
/// - Window, `hidden` mode: nothing at all.
/// - Full screen, any mode: as `over`, without the place button.
public struct StripPlacement: Equatable, Sendable {
    public struct Input: Equatable, Sendable {
        public var mode: StripWindowMode
        public var fullScreen: Bool
        /// T in beside (persisted `stripBarHidden`).
        public var hidden: Bool
        /// T in over (persisted `stripPinned`).
        public var pinned: Bool
        public var pointerOverStrip: Bool
        /// Within 24 pt of the window's bottom.
        public var pointerNearBottom: Bool
        /// Over: the strip is out because the pointer reached its edge, hovers or moves.
        public var revealedByEdge: Bool

        public init(
            mode: StripWindowMode, fullScreen: Bool, hidden: Bool, pinned: Bool,
            pointerOverStrip: Bool, pointerNearBottom: Bool, revealedByEdge: Bool
        ) {
            self.mode = mode
            self.fullScreen = fullScreen
            self.hidden = hidden
            self.pinned = pinned
            self.pointerOverStrip = pointerOverStrip
            self.pointerNearBottom = pointerNearBottom
            self.revealedByEdge = revealedByEdge
        }
    }

    /// The capsule's T button.
    public enum Pin: Equatable, Sendable { case pin(on: Bool), hide }

    public let visible: Bool
    public let reservesSpace: Bool
    /// The ⇧T button in the capsule.
    public let placeButton: Bool
    /// The T button in the capsule; nil: no capsule.
    public let pin: Pin?
    public let showsCapsule: Bool
    public let showsReveal: Bool

    public init(_ input: Input) {
        let floating = input.fullScreen || input.mode == .over
        if input.fullScreen || input.mode != .hidden {
            if floating {
                visible = input.pinned || input.revealedByEdge
                reservesSpace = false
                placeButton = !input.fullScreen
                pin = .pin(on: input.pinned)
                showsReveal = false
            } else if input.hidden {
                visible = false
                reservesSpace = false
                placeButton = false
                pin = nil
                showsReveal = input.pointerNearBottom
            } else {
                visible = true
                reservesSpace = true
                placeButton = true
                pin = .hide
                showsReveal = false
            }
        } else {
            visible = false
            reservesSpace = false
            placeButton = false
            pin = nil
            showsReveal = false
        }
        showsCapsule = visible && input.pointerOverStrip && pin != nil
    }

    /// ⇧T: the mode to write, nil when nothing changes (full screen).
    public static func toggledMode(_ mode: StripWindowMode, fullScreen: Bool) -> StripWindowMode? {
        if fullScreen { return nil }
        return mode == .beside ? .over : .beside
    }

    /// Leaving `hidden` for `beside` clears T's beside flag, so the strip appears instead of staying hidden.
    public static func clearsBarHidden(from: StripWindowMode, to: StripWindowMode) -> Bool {
        from == .hidden && to == .beside
    }
}

// MARK: What T does, and the capsule's buttons

extension StripPlacement {
    /// The persisted flag `T` (its capsule button, the reveal chevron, View › Thumbnail Strip) flips.
    public enum Flag: Equatable, Sendable { case hidden, pinned }

    /// `T`'s flag: `hidden` in a window's `beside`, `pinned` while the strip floats (`over`, full screen); nil in a
    /// window's `hidden` mode, where T does nothing. Each mode has its own flag, so neither leaks into the other.
    public static func flag(_ mode: StripWindowMode, fullScreen: Bool) -> Flag? {
        if fullScreen { return .pinned }
        switch mode {
        case .beside: return .hidden
        case .over: return .pinned
        case .hidden: return nil
        }
    }

    /// Whether `T` holds the strip on screen (View › Thumbnail Strip's checkmark): beside not hidden, a float pinned.
    public static func holds(_ mode: StripWindowMode, fullScreen: Bool, hidden: Bool, pinned: Bool) -> Bool {
        switch flag(mode, fullScreen: fullScreen) {
        case .hidden: !hidden
        case .pinned: pinned
        case nil: false
        }
    }

    /// One button of the capsule: the app turns it into a `FilmstripTool`.
    public struct Tool: Equatable, Sendable {
        public enum Action: Equatable, Sendable { case place, pin }
        public let symbol: String
        public let help: String
        public let isOn: Bool
        public let action: Action
    }

    /// The capsule's buttons, left to right: "where the strip is" (⇧T) when `placeButton`, then T's.
    public func tools(mode: StripWindowMode) -> [Tool] {
        var tools: [Tool] = []
        if placeButton {
            tools.append(mode == .beside
                ? Tool(symbol: "rectangle.bottomthird.inset.filled", help: "Let the strip float over the photo (⇧T)",
                       isOn: true, action: .place)
                : Tool(symbol: "rectangle.on.rectangle", help: "Keep the strip beside the photo (⇧T)",
                       isOn: false, action: .place))
        }
        switch pin {
        case .pin(on: false)?: tools.append(Tool(symbol: "pin", help: "Pin the strip (T)", isOn: false, action: .pin))
        case .pin(on: true)?: tools.append(Tool(symbol: "pin", help: "Unpin the strip (T)", isOn: true, action: .pin))
        case .hide?: tools.append(Tool(symbol: "chevron.down", help: "Hide the strip (T)", isOn: false, action: .pin))
        case nil: break
        }
        return tools
    }

    /// The reveal chevron's tip.
    /// The tool capsule's centre along the strip (user, 2026-10-23: under the pointer): where the pointer entered the
    /// strip, kept `inset` from either end of a strip `length` long; a capsule wider than the room sits in the middle.
    /// An `entry` of `.infinity` (none yet) puts it at the trailing end.
    public static func capsuleCentre(entry: Double, width: Double, length: Double, inset: Double) -> Double {
        let low = inset + width / 2, high = length - inset - width / 2
        guard low <= high else { return length / 2 }
        return min(max(entry, low), high)
    }

    public static let revealHelp = "Show the strip (T)"
    /// `⇧T` in full screen, where the mode does not change.
    public static let fullScreenToast = "In full screen the strip is always over the photo"
}
