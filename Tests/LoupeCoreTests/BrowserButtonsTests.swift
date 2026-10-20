import Testing
@testable import LoupeCore

/// The side buttons in the Folders tab act on a click, like every button binding: a press alone does nothing, so a
/// utility's button + drag gesture (Mac Mouse Fix) still gets the button.
@Test func sideButtonsActOnAClickOnly() {
    #expect(BrowserButtons.action(.back, .tap) == .back)
    #expect(BrowserButtons.action(.forward, .tap) == .forward)
    for kind in [PressKind.long, .wheel, .move, .withRight] {
        #expect(BrowserButtons.action(.back, kind) == nil)
        #expect(BrowserButtons.action(.forward, kind) == nil)
    }
    #expect(BrowserButtons.action(.middle, .tap) == nil)
}
