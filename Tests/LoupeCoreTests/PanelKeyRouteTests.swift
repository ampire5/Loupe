import Testing
@testable import LoupeCore

/// A key typed while a value of the info panel is selected: a ⌘ or ⌃ chord is the menus', any other the viewer's.
@Test func panelKeyRoute() {
    #expect(PanelKeyRoute.route(command: true, control: false) == .menu)
    #expect(PanelKeyRoute.route(command: false, control: true) == .menu)
    #expect(PanelKeyRoute.route(command: true, control: true) == .menu)
    #expect(PanelKeyRoute.route(command: false, control: false) == .viewer)
}
