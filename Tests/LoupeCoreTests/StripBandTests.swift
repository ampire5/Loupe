import Testing
@testable import LoupeCore

@Test func bandIsFullWidthWhenTheCellsFillTheView() {
    let b = StripBand(leftEdge: 0, rightEdge: 1000, viewWidth: 1000, margin: 4)
    #expect(b.isFull && b.x == 0 && b.width == 1000)
    // A sliver of free space within the margin does not make a gap.
    #expect(StripBand(leftEdge: 3, rightEdge: 997, viewWidth: 1000, margin: 4).isFull)
    // Float noise from a layout that fills the width.
    #expect(StripBand(leftEdge: 1e-9, rightEdge: 1000 - 1e-9, viewWidth: 1000, margin: 0).isFull)
}

@Test func bandHugsTheCellsWithAMarginWhenTheyDoNotFillTheView() {
    let b = StripBand(leftEdge: 400, rightEdge: 600, viewWidth: 1000, margin: 4)
    #expect(!b.isFull && b.x == 396 && b.width == 208)
}

@Test func bandIsFullWithoutCells() {
    #expect(StripBand(leftEdge: nil, rightEdge: nil, viewWidth: 800, margin: 4).isFull)
    #expect(StripBand(leftEdge: 10, rightEdge: 10, viewWidth: 800, margin: 4).isFull)
}

@Test func bandStaysInsideTheViewAndFollowsAMagnifiedRow() {
    // The row grown to the left edge of the view: its band starts at 0, and ends short of the right edge.
    let b = StripBand(leftEdge: 0, rightEdge: 300, viewWidth: 1000, margin: 4)
    #expect(!b.isFull && b.x == 0 && b.width == 304)
    // Wider than the view (cannot happen with `keepingInside`, but must not overflow).
    let w = StripBand(leftEdge: -20, rightEdge: 1020, viewWidth: 1000, margin: 4)
    #expect(w.isFull)
    let moved = StripBand(leftEdge: 380, rightEdge: 620, viewWidth: 1000, margin: 4)
    #expect(moved != StripBand(leftEdge: 400, rightEdge: 600, viewWidth: 1000, margin: 4))
}

@Test func cornerRadiusScalesWithHeightAndIsClamped() {
    #expect(StripCorners.radius(base: 4, height: 64, baseHeight: 64, width: 80) == 4)
    #expect(StripCorners.radius(base: 4, height: 128, baseHeight: 64, width: 160) == 8)
    #expect(StripCorners.radius(base: 0, height: 64, baseHeight: 64, width: 80) == 0)
    // Not more than half the shorter side.
    #expect(StripCorners.radius(base: 16, height: 40, baseHeight: 40, width: 10) == 5)
    #expect(StripCorners.radius(base: 16, height: 10, baseHeight: 40, width: 80) == 4)
    // A zero base height (no layout yet) neither divides by zero nor goes infinite.
    #expect(StripCorners.radius(base: 4, height: 64, baseHeight: 0, width: 80).isFinite)
    #expect(StripCorners.radius(base: 4, height: 0, baseHeight: 64, width: 80) == 0)
}
