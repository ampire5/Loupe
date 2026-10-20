import CoreGraphics
import Testing
@testable import LoupeCore

/// While the back button is on screen, a panel in the top left corner stands below it; in any other corner it stays.
@Test func panelStepsDownOnlyTopLeft() {
    let base = CGRect(x: 0, y: 30, width: 800, height: 600)
    let topLeft = PanelPlacement(corner: .topLeft, dx: 12, dy: 12)
    let topRight = PanelPlacement(corner: .topRight, dx: 12, dy: 12)
    #expect(PanelArea.area(base, backButtonShown: true, corner: topLeft.corner) == CGRect(x: 0, y: 94, width: 800, height: 536))
    #expect(PanelArea.area(base, backButtonShown: true, corner: topRight.corner) == base)
    #expect(PanelArea.area(base, backButtonShown: false, corner: topLeft.corner) == base)
    // A short area is not made negative.
    let short = CGRect(x: 0, y: 0, width: 800, height: 40)
    #expect(PanelArea.area(short, backButtonShown: true, corner: topLeft.corner).height == 0)
}

/// The corner the step-down follows is where the panel is now (a drag out of the top left corner leaves the button's
/// band at once, so a drop at the top right does not land 64 pt low and jump up), else the stored one.
@Test func panelAreaFollowsThePanelsCorner() {
    let base = CGRect(x: 0, y: 30, width: 800, height: 600)
    let stored = PanelPlacement(corner: .topLeft, dx: 12, dy: 12)
    // Dragged to the top right (y down), still stored at the top left.
    let dragged = CGRect(x: 500, y: 94, width: 300, height: 200)
    #expect(PanelArea.corner(current: dragged, stored: stored, in: base) == .topRight)
    #expect(PanelArea.corner(current: nil, stored: stored, in: base) == .topLeft)
    #expect(PanelArea.corner(current: CGRect(x: 12, y: 106, width: 300, height: 200), stored: stored, in: base) == .topLeft)
}
