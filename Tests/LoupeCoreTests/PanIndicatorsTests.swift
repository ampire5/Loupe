import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

// 6000×4000 photo at 100 % in a 1600×1000 px view (backing 2: 10 px thick, 8 px inset, 48 px minimum).
private func view(center: CGPoint = CGPoint(x: 0.5, y: 0.5), view: CGSize = CGSize(width: 1600, height: 1000),
                  mode: ZoomMode = .actual(1)) -> ViewTransform {
    ViewTransform(imageSize: CGSize(width: 6000, height: 4000), viewSize: view, mode: mode, center: center)
}

private func pills(_ t: ViewTransform, scale: Double = 2, bottom: Double = 0) -> [PanIndicatorPill] {
    PanIndicators.pills(for: t, backingScale: scale, bottomInsetPoints: bottom)
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

@Test func bottomInsetRaisesTheHorizontalPillAndShortensTheVerticalOne() throws {
    let plain = pills(view())
    let lifted = pills(view(), bottom: 80)               // 160 px at backing 2
    let h0 = try #require(plain.first { $0.rect.height == 10 }), h1 = try #require(lifted.first { $0.rect.height == 10 })
    let v0 = try #require(plain.first { $0.rect.width == 10 }), v1 = try #require(lifted.first { $0.rect.width == 10 })
    #expect(h1.rect.maxY == h0.rect.maxY - 160)
    #expect(h1.rect.width == h0.rect.width)
    #expect(abs((v1.rect.height / v0.rect.height) - ((974.0 - 160 - 8) / (974.0 - 8))) < 1e-9)
    #expect(v1.rect.minY >= 8)
    #expect(v1.rect.maxY <= 1000 - 8 - 160 - 18 + 1e-9)
}

@Test func tinyViewsAndHugeInsetsGiveNoPillAndNoNegativeSize() {
    #expect(pills(view(view: CGSize(width: 30, height: 30)), scale: 1).isEmpty)
    // A bottom inset taller than the view (1200 px, 4000 px in a 1000 px view): no pill at all, not one at a negative y.
    #expect(pills(view(), bottom: 600).isEmpty)
    #expect(pills(view(), bottom: 2000).isEmpty)
    // Just fitting: 1000 = bottom 982 + inset 8 + thickness 10 would be 1000, so the horizontal pill still stands at y 0.
    let edge = pills(view(), bottom: 491)
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
