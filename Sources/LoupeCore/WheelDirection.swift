/// `wheel-direction`: which way a notched-wheel notch steps through the folder.
/// - `content`: as a document scrolls — the notch that scrolls a page down (negative `scrollingDeltaY`, after macOS and
///   any mouse utility such as LinearMouse or Mac Mouse Fix have applied their direction) shows the next photo. The
///   default (user, M3a): the wheel then agrees with every other app on the machine.
/// - `device`: by the wheel's physical turn, recovered through `isDirectionInvertedFromDevice` (the way it was): wrong
///   when a mouse utility reverses the wheel but the event still carries the system's natural-scrolling flag.
public enum WheelDirection: String, Sendable, CaseIterable {
    case content, device

    /// Case-insensitive.
    public init?(text: String) { self.init(rawValue: text.lowercased()) }

    /// Whether a notch with this vertical delta steps to the next photo (false: the previous one).
    public func isNext(deltaY: Double, invertedFromDevice: Bool) -> Bool {
        switch self {
        case .content: deltaY < 0
        case .device: invertedFromDevice ? deltaY > 0 : deltaY < 0
        }
    }
}
