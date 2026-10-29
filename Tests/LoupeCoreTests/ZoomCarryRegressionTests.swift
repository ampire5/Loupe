import CoreGraphics
import Testing
@testable import LoupeCore

/// A photo switch and a later, sharper level must not replace a kept view with default Fit.
@Test func ordinaryStepsAndRefinementsKeepZoomAndPosition() {
    var config = Config()
    config.keepZoomPosition = true
    config.keepZoomAs = .scale
    _ = config.set("step-pan", "keep")
    let rules = ZoomRules(config: config)
    for mode in [ZoomMode.actual(4), .free(3), .fitWidth] {
        var view = ViewTransform(imageSize: CGSize(width: 3000, height: 4000),
            viewSize: CGSize(width: 1600, height: 1000), mode: mode, center: CGPoint(x: 0.4, y: 0.65))
        for size in [CGSize(width: 3000, height: 4000), CGSize(width: 3000, height: 4000)] {
            let previous = view
            view = PhotoSwitchView.shown(.switched, current: view, imageSize: size, rules: rules)
            #expect(abs(view.scale - previous.scale) < 1e-9)
            #expect(view.center == previous.center)
            let refined = PhotoSwitchView.shown(.laidOut, current: view, imageSize: size, rules: rules)
            #expect(refined == view)
        }
    }
}
