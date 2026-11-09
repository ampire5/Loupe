import CoreGraphics
import LoupeCore
import Testing

@Test func threeFingerReversalStepsBackWithoutSwitchingAxis() {
    func points(_ x: Double, _ y: Double = 0.5) -> [CGPoint] {
        [CGPoint(x: x - 0.04, y: y), CGPoint(x: x, y: y), CGPoint(x: x + 0.04, y: y)]
    }
    var swipe = ThreeFingerSwipe(allowsReversal: true)
    #expect(swipe.update(touches: points(0.7)) == nil)
    #expect(swipe.update(touches: points(0.59)) == .next)
    #expect(swipe.update(touches: points(0.4)) == nil)
    #expect(swipe.update(touches: points(0.43, 0.9)) == nil)
    #expect(swipe.update(touches: points(0.52, 0.9)) == .previous)
    #expect(swipe.update(touches: points(0.7)) == nil)
    #expect(swipe.update(touches: points(0.59)) == .next)

    swipe.reset()
    #expect(swipe.update(touches: points(0.5, 0.6)) == nil)
    #expect(swipe.update(touches: points(0.5, 0.48)) == .down)
    #expect(swipe.update(touches: points(0.2, 0.48)) == nil)
    #expect(swipe.update(touches: points(0.2, 0.8)) == nil)
}

@Test func fitAxisGestureSkipsAVisuallyIdenticalScale() {
    let view = CGSize(width: 800, height: 600)
    let landscape = ViewTransform(imageSize: CGSize(width: 1600, height: 600), viewSize: view)
    let portrait = ViewTransform(imageSize: CGSize(width: 800, height: 1200), viewSize: view)
    let sameAspect = ViewTransform(imageSize: CGSize(width: 1600, height: 1200), viewSize: view)
    #expect(landscape.toggledFitAxis()?.mode == .fitHeight)
    #expect(portrait.toggledFitAxis()?.mode == .fitWidth)
    #expect(portrait.withMode(.fitWidth).toggledFitAxis()?.mode == .fitHeight)
    #expect(sameAspect.toggledFitAxis() == nil)
}
