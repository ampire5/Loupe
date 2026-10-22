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
}
