/// A mouse's back and forward buttons in the Folders tab (file browser spec §3.1): Back and Forward on a click, as
/// the recogniser reports it after the release — a press alone does nothing, so a utility's button + drag gesture
/// (Mac Mouse Fix) still has the button, as on a photo.
public enum BrowserButtons {
    public enum Action: Equatable, Sendable { case back, forward }

    public static func action(_ button: MouseButton, _ kind: PressKind) -> Action? {
        guard kind == .tap else { return nil }
        switch button {
        case .back: return .back
        case .forward: return .forward
        default: return nil
        }
    }
}
