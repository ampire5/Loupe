import Foundation
import Testing
@testable import LoupeCore

@Suite struct StripHitZoneTests {
    /// A 1000 pt wide band 80 pt tall (68 pt cells, 6 pt padding).
    private let zone = StripHitZone(width: 1000, height: 80, padding: 6)

    @Test func theBandIsTheZoneAndItsTopIsTheGrabBand() {
        #expect(zone.inHoverZone(x: 250, y: 30) && !zone.inResizeBand(x: 250, y: 30))
        #expect(zone.inResizeBand(x: 250, y: 77) && !zone.inHoverZone(x: 250, y: 77))
        #expect(!zone.inHoverZone(x: 250, y: 100) && !zone.inResizeBand(x: 250, y: 100))   // above the band
    }

    @Test func grabBandIsTheTopPadding() {
        #expect(zone.inResizeBand(x: 250, y: 74) && zone.inResizeBand(x: 250, y: 79.5))
        #expect(!zone.inResizeBand(x: 250, y: 73.9) && !zone.inResizeBand(x: 250, y: 80))
        #expect(zone.inResizeBand(x: 0, y: 75) && !zone.inResizeBand(x: 1000, y: 75) && !zone.inResizeBand(x: -1, y: 75))
    }

    @Test func cellBodyNeverGrab() {
        for y in stride(from: 0.0, to: 74, by: 0.5) {
            #expect(!zone.inResizeBand(x: 250, y: y) && zone.inHoverZone(x: 250, y: y))
        }
        #expect(!zone.inHoverZone(x: -5, y: 30) && !zone.inHoverZone(x: 1000, y: 30) && !zone.inHoverZone(x: 250, y: -1))
    }
}
