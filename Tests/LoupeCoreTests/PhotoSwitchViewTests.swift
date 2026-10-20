import CoreGraphics
import Testing
@testable import LoupeCore

// M4b spec §4.2: the view a newly shown photo gets.

private func rules(keep: Bool = true, mode: ZoomMode = .fit, fitUpscale: Bool = true) -> ZoomRules {
    var c = Config()
    c.keepZoomPosition = keep
    c.defaultZoomMode = mode
    c.fitUpscale = fitUpscale
    return ZoomRules(config: c)
}

private let view = CGSize(width: 2000, height: 1000)
private let newSize = CGSize(width: 600, height: 400)

/// A view zoomed in somewhere off-centre, with transient state (a rubber-band offset and a zoom stretch) on it.
private func zoomedIn(mode: ZoomMode = .actual(2)) -> ViewTransform {
    var t = ViewTransform(imageSize: CGSize(width: 4000, height: 3000), viewSize: view, mode: mode,
                          center: CGPoint(x: 0.2, y: 0.7))
    t.offset = CGVector(dx: 12, dy: -5)
    t.stretch = ZoomStretch(factor: 1.1, anchor: CGPoint(x: 100, y: 100))
    return t
}

@Test func photoSwitchViewKeepKeepsModeAndCentre() {
    let next = PhotoSwitchView.next(current: zoomedIn(), imageSize: newSize, rules: rules(keep: true))
    #expect(next.mode == .actual(2))
    #expect(next.center == CGPoint(x: 0.2, y: 0.7))
    #expect(next.imageSize == newSize)
    #expect(next.viewSize == view)
    #expect(next.offset == .zero)
    #expect(next.stretch == nil)
}

@Test func photoSwitchViewNoKeepOpensInTheDefaultModeCentred() {
    for mode in [ZoomMode.actual(1), .fitWidth, .fit, .fitHeight, .fill, .actual(2.5)] {
        let next = PhotoSwitchView.next(current: zoomedIn(), imageSize: newSize, rules: rules(keep: false, mode: mode))
        #expect(next.mode == mode, "\(mode)")
        #expect(next.center == CGPoint(x: 0.5, y: 0.5), "\(mode)")
        #expect(next.imageSize == newSize && next.viewSize == view, "\(mode)")
        #expect(next.offset == .zero && next.stretch == nil, "\(mode)")
    }
}

@Test func photoSwitchViewCopiesFitUpscale() {
    for keep in [true, false] {
        for on in [true, false] {
            var current = zoomedIn(mode: .fit)
            current.fitUpscale = !on
            let next = PhotoSwitchView.next(current: current, imageSize: newSize, rules: rules(keep: keep, fitUpscale: on))
            #expect(next.fitUpscale == on, "keep \(keep), fit-upscale \(on)")
            let opened = PhotoSwitchView.opened(viewSize: view, imageSize: newSize, rules: rules(keep: keep, fitUpscale: on))
            #expect(opened.fitUpscale == on, "keep \(keep), fit-upscale \(on)")
        }
    }
    // A small photo in Fit without fit-upscale stands at 100 %.
    let small = PhotoSwitchView.next(current: zoomedIn(mode: .fit), imageSize: newSize, rules: rules(fitUpscale: false))
    #expect(small.scale == 1)
}

/// The session passes `zoomTarget ?? transform`: a photo switched to while a zoom key's animation runs gets the mode the
/// key asked for, which `next` keeps (a named mode, not the `.free` frame on the way).
@Test func photoSwitchViewSwitchUsesTargetMidAnimation() {
    let target = zoomedIn(mode: .actual(1))
    let next = PhotoSwitchView.next(current: target, imageSize: newSize, rules: rules(keep: true))
    #expect(next.mode == .actual(1))
    #expect(next.scale == 1)
    // The frame on the way would have carried its `.free` scale over instead.
    let frame = PhotoSwitchView.next(current: zoomedIn(mode: .free(1.4)), imageSize: newSize, rules: rules(keep: true))
    #expect(frame.mode != .actual(1))
}

@Test func photoSwitchViewOpenedUsesTheDefaultModeCentred() {
    for keep in [true, false] {
        for mode in [ZoomMode.fit, .actual(1), .fitWidth, .fill] {
            let t = PhotoSwitchView.opened(viewSize: view, imageSize: newSize, rules: rules(keep: keep, mode: mode))
            #expect(t.mode == mode && t.center == CGPoint(x: 0.5, y: 0.5), "keep \(keep) \(mode)")
            #expect(t.imageSize == newSize && t.viewSize == view)
            #expect(t.offset == .zero && t.stretch == nil)
        }
    }
}

/// `shown`, the whole choice for a photo without a saved view: the photo already laid out keeps its view whatever the
/// rules (a level arriving must not reset a zoom made on it), a switch follows `next`, an opened photo `opened`.
@Test func photoSwitchViewShownByArrival() {
    let current = zoomedIn()
    let noKeep = rules(keep: false, mode: .fitWidth)
    let same = PhotoSwitchView.shown(.laidOut, current: current, imageSize: current.imageSize, rules: noKeep)
    #expect(same == current.withImageSize(current.imageSize))
    #expect(same.mode == .actual(2) && same.center == CGPoint(x: 0.2, y: 0.7))
    #expect(PhotoSwitchView.shown(.switched, current: current, imageSize: newSize, rules: noKeep)
            == PhotoSwitchView.next(current: current, imageSize: newSize, rules: noKeep))
    let keep = rules(keep: true, mode: .fitWidth)
    #expect(PhotoSwitchView.shown(.switched, current: current, imageSize: newSize, rules: keep).mode == .actual(2))
    // Launch and Finder's Open: the default mode even with keep.
    let opened = PhotoSwitchView.shown(.opened, current: current, imageSize: newSize, rules: keep)
    #expect(opened == PhotoSwitchView.opened(viewSize: view, imageSize: newSize, rules: keep))
    #expect(opened.mode == .fitWidth)
}
