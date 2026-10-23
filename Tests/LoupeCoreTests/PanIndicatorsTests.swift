import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

// 6000×4000 photo at 100 % in a 1600×1000 px view (backing 2: 10 px thick, 8 px inset, 48 px minimum).
private func view(center: CGPoint = CGPoint(x: 0.5, y: 0.5), view: CGSize = CGSize(width: 1600, height: 1000),
                  mode: ZoomMode = .actual(1)) -> ViewTransform {
    ViewTransform(imageSize: CGSize(width: 6000, height: 4000), viewSize: view, mode: mode, center: center)
}

/// The pills of `t` in `area` (default: the view's own rect, the container the size of the viewer).
private func pills(_ t: ViewTransform, scale: Double = 2, area: CGRect? = nil) -> [PanIndicatorPill] {
    PanIndicators.pills(for: t, backingScale: scale, in: area ?? CGRect(origin: .zero, size: t.viewSize))
}

// Horizontal track 8 ... 1600 - 8 - 18 = 1574 (the vertical pill takes 10 + 8); vertical 8 ... 1000 - 8 - 18 = 974.
private let hTrack = 8.0 ... 1574.0, vTrack = 8.0 ... 974.0

@Test func fitHasNoPills() {
    #expect(pills(view(mode: .fit)).isEmpty)
}

@Test func hundredPercentGivesTwoPillsWithTheVisibleFraction() throws {
    let p = pills(view())   // centred: visible x 2200 ... 3800, y 1500 ... 2500
    #expect(p.count == 2)
    let h = try #require(p.first { $0.rect.height == 10 && $0.rect.width > 10 })
    let v = try #require(p.first { $0.rect.width == 10 && $0.rect.height > 10 })
    let hLen = (hTrack.upperBound - hTrack.lowerBound) * 1600 / 6000
    #expect(abs(h.rect.width - hLen) < 1e-9)
    #expect(abs(h.rect.minX - (hTrack.lowerBound + (1566 - hLen) * (2200.0 / 4400))) < 1e-9)
    #expect(h.rect.maxY == 992.0)                      // bottom, 8 px up
    let vLen = (vTrack.upperBound - vTrack.lowerBound) * 1000 / 4000
    #expect(abs(v.rect.height - vLen) < 1e-9)
    #expect(abs(v.rect.minY - (vTrack.lowerBound + (966 - vLen) * (1500.0 / 3000))) < 1e-9)
    #expect(v.rect.maxX == 1592.0)                      // right, 8 px in
}

@Test func edgesPinTheStartAndTheEndOfTheTrack() throws {
    let tl = pills(view(center: CGPoint(x: 0, y: 0)))
    let br = pills(view(center: CGPoint(x: 1, y: 1)))
    for p in tl {
        #expect(p.rect.minX == 8 || p.rect.width == 10)
        #expect(p.rect.minY == 8 || p.rect.height == 10)
    }
    let h = try #require(br.first { $0.rect.height == 10 })
    let v = try #require(br.first { $0.rect.width == 10 })
    #expect(abs(h.rect.maxX - 1574) < 1e-9)
    #expect(abs(v.rect.maxY - 974) < 1e-9)
}

@Test func rubberBandPinsThePillAtTheEnd() throws {
    let base = view(center: CGPoint(x: 0, y: 1))
    let pulled = base.withOffset(CGVector(dx: 120, dy: -80))   // past the left edge and past the bottom edge
    let h = try #require(pills(pulled).first { $0.rect.height == 10 })
    let v = try #require(pills(pulled).first { $0.rect.width == 10 })
    #expect(h.rect.minX == 8)
    #expect(abs(v.rect.maxY - 974) < 1e-9)
    let other = view(center: CGPoint(x: 1, y: 0)).withOffset(CGVector(dx: -120, dy: 80))   // the far ends: pinned there
    let h2 = try #require(pills(other).first { $0.rect.height == 10 })
    #expect(abs(h2.rect.maxX - 1574) < 1e-9)
    // Same size as unstretched: no squeeze.
    #expect(abs(h2.rect.width - h.rect.width) < 1e-9)
}

@Test func minimumLengthAppliesToASmallFraction() throws {
    let t = ViewTransform(imageSize: CGSize(width: 200_000, height: 4000), viewSize: CGSize(width: 1600, height: 1000),
                          mode: .actual(1))
    let h = try #require(pills(t).first { $0.rect.height == 10 })
    #expect(h.rect.width == 48)                           // 1566 × 1 % would be 15.7
}

@Test func pillsSitAtContainerEdgeWhateverTheStripMode() throws {
    // Strip beside: the viewer (1600×800 px) ends at the strip's top, the container is 1600×1000.
    let beside = pills(view(view: CGSize(width: 1600, height: 800)), area: CGRect(x: 0, y: 0, width: 1600, height: 1000))
    // Strip over: the viewer fills the container, the strip floats over its bottom.
    let over = pills(view(), area: CGRect(x: 0, y: 0, width: 1600, height: 1000))
    for p in [beside, over] {
        let h = try #require(p.first { $0.rect.height == 10 }), v = try #require(p.first { $0.rect.width == 10 })
        #expect(h.rect.maxY == 992.0)               // the container's bottom, not the viewer's or the strip's top
        #expect(v.rect.maxX == 1592.0)
        #expect(v.rect.minY >= 8 && v.rect.maxY <= 1000 - 8 - 18 + 1e-9)
    }
    // Windowed with the stats bar at the top (60 px): the vertical track starts below it, the horizontal pill stays put.
    let barred = pills(view(view: CGSize(width: 1600, height: 740)), area: CGRect(x: 0, y: 60, width: 1600, height: 940))
    let h = try #require(barred.first { $0.rect.height == 10 }), v = try #require(barred.first { $0.rect.width == 10 })
    #expect(h.rect.maxY == 992.0)
    #expect(v.rect.minY >= 60 + 8 && v.rect.maxY <= 1000 - 8 - 18 + 1e-9)
    // The pill's length is the viewer's visible share of the container's track: 800 / 4000 of 1000 - 8 - 8 - 18.
    let vb = try #require(beside.first { $0.rect.width == 10 })
    #expect(abs(vb.rect.height - (1000.0 - 34) * 800 / 4000) < 1e-9)
}

@Test func tinyViewsAndShortAreasGiveNoPillAndNoNegativeSize() {
    #expect(pills(view(view: CGSize(width: 30, height: 30)), scale: 1).isEmpty)
    // An area too short for the horizontal pill (17 px < inset 8 + thickness 10): none, not one at a negative y.
    #expect(!pills(view(), area: CGRect(x: 0, y: 0, width: 1600, height: 17)).contains { $0.rect.height == 10 })
    #expect(pills(view(), area: CGRect(x: 0, y: 0, width: 1600, height: -50)).isEmpty)
    // Just fitting: 18 = inset 8 + thickness 10, so the horizontal pill still stands at y 0.
    let edge = pills(view(), area: CGRect(x: 0, y: 0, width: 1600, height: 18))
    #expect(edge.contains { $0.rect.height == 10 && $0.rect.minY == 0 })
    #expect(edge.allSatisfy { $0.rect.minY >= 0 && $0.rect.width > 0 && $0.rect.height > 0 })
    #expect(pills(view(view: .zero)).isEmpty)
}

@Test func alphaFollowsTheMode() {
    typealias P = PanIndicators
    // hide 0.5 s and fade 0.25 s: exact in binary, so the boundaries are exact.
    #expect(P.alpha(mode: .always, now: 100, lastMotion: nil, hide: 0.5, fade: 0.25) == 1)
    #expect(P.alpha(mode: .no, now: 100, lastMotion: 99.5, hide: 0.5, fade: 0.25) == 0)
    #expect(P.alpha(mode: .auto, now: 100, lastMotion: nil, hide: 0.5, fade: 0.25) == 0)
    #expect(P.alpha(mode: .auto, now: 100.0, lastMotion: 100.0, hide: 0.5, fade: 0.25) == 1)
    #expect(P.alpha(mode: .auto, now: 100.5, lastMotion: 100.0, hide: 0.5, fade: 0.25) == 1)
    #expect(P.alpha(mode: .auto, now: 100.625, lastMotion: 100.0, hide: 0.5, fade: 0.25) == 0.5)
    #expect(P.alpha(mode: .auto, now: 100.75, lastMotion: 100.0, hide: 0.5, fade: 0.25) == 0)
    #expect(P.alpha(mode: .auto, now: 105, lastMotion: 100.0, hide: 0.5, fade: 0.25) == 0)
    #expect(P.alpha(mode: .auto, now: 100.5625, lastMotion: 100.0, hide: 0.5, fade: 0) == 0)
    #expect(P.alpha(mode: .auto, now: 100.5, lastMotion: 100.0, hide: 0.5, fade: 0) == 1)
}

@Test func toastsNameTheModes() {
    #expect(PanIndicators.toast(for: .auto) == "Pan indicators: auto")
    #expect(PanIndicators.toast(for: .always) == "Pan indicators: always")
    #expect(PanIndicators.toast(for: .no) == "Pan indicators: off")
    #expect(PanIndicators.savedToast == "Pan indicators saved as default")
}

// MARK: What counts as motion (M4b spec §5.2, `pan-indicators-on-switch`)

@Test func changesOfTheSamePictureAreMotion() {
    for onSwitch in [false, true] {
        #expect(PanIndicators.isMotion(sameImage: true, imageSizeChanged: false, scaleChanged: false, visibleChanged: true,
                                       onSwitch: onSwitch))
        #expect(PanIndicators.isMotion(sameImage: true, imageSizeChanged: false, scaleChanged: true, visibleChanged: false,
                                       onSwitch: onSwitch))
        #expect(PanIndicators.isMotion(sameImage: true, imageSizeChanged: true, scaleChanged: false, visibleChanged: false,
                                       onSwitch: onSwitch))
        #expect(!PanIndicators.isMotion(sameImage: true, imageSizeChanged: false, scaleChanged: false,
                                        visibleChanged: false, onSwitch: onSwitch))   // a new level, a colour fade
    }
}

@Test func aPhotoSwitchIsMotionOnlyWithOnSwitch() {
    for changed in [false, true] {
        #expect(!PanIndicators.isMotion(sameImage: false, imageSizeChanged: changed, scaleChanged: changed,
                                        visibleChanged: changed, onSwitch: false))
        #expect(PanIndicators.isMotion(sameImage: false, imageSizeChanged: changed, scaleChanged: changed,
                                       visibleChanged: changed, onSwitch: true))
    }
}
