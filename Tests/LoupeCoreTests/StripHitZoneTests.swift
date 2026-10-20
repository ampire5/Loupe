import Foundation
import Testing
@testable import LoupeCore

@Suite struct StripHitZoneTests {
    /// A 1000 pt wide band 72 pt tall (64 pt cells, 4 pt padding), cells 100...400; the middle one grown to 160 pt.
    private let base: [(x: Double, width: Double, height: Double)] = [(100, 100, 64), (200, 100, 64), (300, 100, 64)]
    private let grown: [(x: Double, width: Double, height: Double)] = [(40, 120, 80), (160, 180, 160), (340, 120, 80)]

    private func zone(_ frames: [(x: Double, width: Double, height: Double)], hovering: Bool) -> StripHitZone {
        StripHitZone(frames: frames, width: 1000, height: 72, padding: 4, hovering: hovering)
    }

    @Test func withoutHoverTheBandIsTheZoneAndItsTopIsTheGrabBand() {
        let z = zone(base, hovering: false)
        #expect(z.inHoverZone(x: 250, y: 30) && !z.inResizeBand(x: 250, y: 30))
        #expect(z.inResizeBand(x: 250, y: 69) && !z.inHoverZone(x: 250, y: 69))
        #expect(!z.inHoverZone(x: 250, y: 100))   // above the band
        #expect(!z.overMagnifiedCell(x: 250, y: 30))
    }

    @Test func magnifiedCellsCoverTheGrabBandAndReachAboveTheBand() {
        let z = zone(grown, hovering: true)
        // Over the grown cell the top padding is the cell, not the grab band.
        #expect(!z.inResizeBand(x: 250, y: 69) && z.inHoverZone(x: 250, y: 69))
        // Above the band, inside the grown cell (4 + 160 = 164) and not above it.
        #expect(z.inHoverZone(x: 250, y: 150) && z.overMagnifiedCell(x: 250, y: 150))
        #expect(!z.inHoverZone(x: 250, y: 170))
        // Beside every cell the grab band is still there.
        #expect(z.inResizeBand(x: 700, y: 70))
        // Outside the view's width or below its padding nothing is magnified.
        #expect(!z.overMagnifiedCell(x: 250, y: 2) && !z.inHoverZone(x: -5, y: 150))
    }

    /// The middle cell at twice the base height (128 pt), its top at 4 + 128 = 132 pt.
    private let doubled: [(x: Double, width: Double, height: Double)] = [(40, 120, 96), (160, 180, 128), (340, 120, 96)]

    @Test func grabAboveMagnifiedCell() {
        let z = zone(doubled, hovering: true)
        // The 4 pt just above the shown top, outside the band.
        #expect(z.inResizeBand(x: 250, y: 132) && z.inResizeBand(x: 250, y: 135.5))
        #expect(!z.inResizeBand(x: 250, y: 120) && !z.inResizeBand(x: 250, y: 136))
        // Over the smaller neighbour the zone follows its top (4 + 96 = 100).
        #expect(z.inResizeBand(x: 380, y: 101) && !z.inResizeBand(x: 380, y: 133))
        // The base edge under a magnified cell is the cell now.
        #expect(!z.inResizeBand(x: 250, y: 69))
    }

    @Test func grabZoneKeepsHover() {
        let z = zone(doubled, hovering: true)
        #expect(z.inHoverZone(x: 250, y: 133))
        #expect(!z.inHoverZone(x: 250, y: 137))   // above the zone the wave goes
    }

    @Test func grabAtBaseEdgeWithoutHover() {
        let z = zone(base, hovering: false)
        #expect(z.inResizeBand(x: 250, y: 68) && z.inResizeBand(x: 250, y: 71.5))
        #expect(!z.inHoverZone(x: 250, y: 69))   // coming down from the photo, no hover starts on the edge
        #expect(!z.inResizeBand(x: 250, y: 72) && !z.inResizeBand(x: 250, y: 133))
        #expect(z.inResizeBand(x: 700, y: 70) && !z.inResizeBand(x: 1000, y: 70))
    }

    @Test func cellBodyNeverGrab() {
        let hovered = zone(doubled, hovering: true), still = zone(base, hovering: false)
        for y in stride(from: 4.0, to: 132, by: 0.5) {
            #expect(!hovered.inResizeBand(x: 250, y: y) && hovered.inHoverZone(x: 250, y: y))
        }
        for y in stride(from: 4.0, to: 68, by: 0.5) {
            #expect(!still.inResizeBand(x: 250, y: y) && still.inHoverZone(x: 250, y: y))
        }
    }

    @Test func magnifyOneWhileHoveringKeepsTheBandTopAndTheHover() {
        // strip-magnify=1: the frames are the base ones even while hovering, so the zone is the band's top.
        let z = zone(base, hovering: true)
        #expect(z.inResizeBand(x: 250, y: 69) && z.inHoverZone(x: 250, y: 69))   // over a cell: the hover stays
        #expect(z.inResizeBand(x: 700, y: 70) && !z.inHoverZone(x: 700, y: 70))  // beside the cells: no hover
        #expect(!z.inResizeBand(x: 250, y: 73) && !z.inHoverZone(x: 250, y: 73))
    }

    @Test func zoneStepsAtABoundaryBetweenCellsOfDifferentHeights() {
        // The 128 pt middle cell ends at 340, where the 96 pt neighbour starts.
        let z = zone(doubled, hovering: true)
        #expect(z.inResizeBand(x: 339.9, y: 133) && !z.inResizeBand(x: 340, y: 133))
        #expect(!z.inHoverZone(x: 340, y: 133))   // above the neighbour's zone: off the strip
        #expect(z.inResizeBand(x: 340, y: 101) && z.inHoverZone(x: 340, y: 101))
        #expect(!z.inResizeBand(x: 339.9, y: 101) && z.inHoverZone(x: 339.9, y: 101))   // the middle cell's body
    }

    @Test func theGrabbedCellIsTheShownOneUnderX() {
        let z = zone(doubled, hovering: true)
        #expect(z.shownCellHeight(atX: 250) == 128 && z.shownCellHeight(atX: 380) == 96)
        #expect(z.shownCellHeight(atX: 700) == nil)                       // the band's top beside the cells
        #expect(zone(base, hovering: false).shownCellHeight(atX: 250) == nil)
    }
}
