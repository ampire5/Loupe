/// Keeps the owner of a phased scroll through modifier changes and its momentum tail.
public struct PlaybackInput {
    public enum Phase { case notch, begin, change, end, cancel, momentum, momentumEnd }
    public enum Route: Equatable { case viewer, player, transport, discard }

    public private(set) var locked = false
    private var route: Route?
    private var chord = false

    public init() {}

    public mutating func toggleLock() {
        if locked { exit() } else { locked = true }
    }

    public mutating func exit() {
        locked = false
        chord = false
        if route == .player || route == .transport { route = .discard }
    }

    public mutating func cancelChord() { chord = false }

    /// Raw three-finger navigation takes over a scroll that AppKit began with two fingers.
    @discardableResult
    public mutating func claimNavigation() -> Bool {
        guard route != .transport else { return false }
        let wasPlayer = route == .player
        route = .discard
        return wasPlayer
    }

    public mutating func modifiers(lockChord: Bool, none: Bool) {
        if lockChord {
            chord = true
        } else if none {
            if chord { toggleLock() }
            chord = false
        }
    }

    public mutating func scroll(_ phase: Phase, eligible: Bool, overTransport: Bool = false,
                                trackingNavigation: Bool = false) -> Route {
        chord = false
        let candidate: Route
        if overTransport { candidate = .transport }
        else if trackingNavigation { candidate = .discard }
        else { candidate = eligible ? .player : .viewer }
        switch phase {
        case .notch: return candidate
        case .begin: route = candidate
        case .change: if route == nil { route = candidate }
        case .end, .cancel, .momentum, .momentumEnd: break
        }
        let outcome = route ?? .viewer
        if phase == .cancel || phase == .momentumEnd { route = nil }
        return outcome
    }
}
