/// Where a key typed while a value of the info panel is selected goes, once the viewer has the keys back (the field
/// editor keeps ⌘C with text selected and ⌘A): a ⌘ or ⌃ chord to the menus, any other key to the viewer.
public enum PanelKeyRoute: Equatable, Sendable {
    case menu, viewer

    public static func route(command: Bool, control: Bool) -> PanelKeyRoute {
        command || control ? .menu : .viewer
    }
}
