import CoreGraphics
import Testing
@testable import LoupeCore

struct PhotoComparisonTests {
    private func pair(_ second: CGSize = CGSize(width: 3000, height: 2000)) -> PhotoComparison {
        let viewport = CGSize(width: 900, height: 600)
        return PhotoComparison(
            ViewTransform(imageSize: CGSize(width: 6000, height: 4000), viewSize: viewport),
            ViewTransform(imageSize: second, viewSize: viewport)
        )
    }

    @Test func proportionalPhotosStartAtTheSameDisplayedSize() {
        let comparison = pair()
        #expect(comparison.isLinked)
        #expect(comparison[.left].scale == 0.15)
        #expect(comparison[.right].scale == 0.30)
    }

    @Test func matchingUsesTheActivePhotoAsReference() {
        var comparison = pair()
        comparison.isLinked = false
        comparison.zoom(from: .right, by: 2, anchor: CGPoint(x: 450, y: 300))
        comparison.matchScale(from: .right)
        #expect(comparison[.right].scale == 0.60)
        #expect(comparison[.left].scale == 0.30)
        #expect(comparison.isLinked)
    }

    @Test func linkedPanStopsBothAtTheFirstEdge() {
        var comparison = pair()
        let anchor = CGPoint(x: 450, y: 300)
        comparison.zoom(from: .left, by: 2, anchor: anchor)
        comparison.isLinked = false
        comparison.pan(from: .right, by: CGVector(dx: 400, dy: 0))
        comparison.isLinked = true
        comparison.pan(from: .left, by: CGVector(dx: 100, dy: 50))
        let left = comparison[.left].viewPoint(forImage: .zero)
        let right = comparison[.right].viewPoint(forImage: .zero)
        #expect(abs(left.x + 400) < 0.001)
        #expect(abs(right.x) < 0.001)
        #expect(abs(left.y + 250) < 0.001)
        #expect(abs(right.y + 250) < 0.001)
    }

    @Test func relinkingRetainsTheManualAlignmentAndScaleRatio() {
        var comparison = pair(CGSize(width: 3000, height: 1000))
        #expect(!comparison.isLinked)
        let anchor = CGPoint(x: 450, y: 300)
        comparison.zoom(from: .left, by: 2, anchor: anchor)
        comparison.pan(from: .left, by: CGVector(dx: 100, dy: 0))
        let left = comparison[.left]
        let right = comparison[.right]
        comparison.isLinked = true
        #expect(comparison[.left] == left)
        #expect(comparison[.right] == right)
        comparison.zoom(from: .right, by: 2, anchor: anchor)
        #expect(abs(comparison[.left].scale - 0.60) < 0.001)
        #expect(abs(comparison[.right].scale - 0.60) < 0.001)
        #expect(abs(comparison[.left].center.x - left.center.x) < 0.001)
    }

    @Test func sharedZoomStopsAtTheFirstScaleLimit() {
        var comparison = pair()
        comparison.zoom(from: .left, by: 1000, anchor: CGPoint(x: 450, y: 300))
        #expect(comparison[.left].scale == 32)
        #expect(comparison[.right].scale == 64)
    }

    @Test func resizeKeepsMatchedWidthsWhenTheViewportsRoundDifferently() {
        var comparison = pair()
        comparison.resize(left: CGSize(width: 800, height: 600), right: CGSize(width: 801, height: 600))
        let left = comparison[.left], right = comparison[.right]
        #expect(abs(left.imageSize.width * left.scale - 800) < 0.001)
        #expect(abs(right.imageSize.width * right.scale - 800) < 0.001)
    }

    @Test func matchingCanEnlargeTheSmallPhotoWhenOrdinaryFitCannotReachTheOtherPhoto() {
        let viewport = CGSize(width: 900, height: 600)
        let comparison = PhotoComparison(
            ViewTransform(imageSize: CGSize(width: 6000, height: 4000), viewSize: viewport, fitUpscale: false),
            ViewTransform(imageSize: CGSize(width: 150, height: 100), viewSize: viewport, fitUpscale: false)
        )
        #expect(comparison.isLinked)
        #expect(abs(comparison[.left].scale - 0.0375) < 0.001)
        #expect(abs(comparison[.right].scale - 1.5) < 0.001)
    }

    @Test func linkedPanReversesImmediatelyAtAnEdge() {
        var comparison = pair()
        comparison.zoom(from: .left, by: 2, anchor: CGPoint(x: 450, y: 300))
        comparison.pan(from: .left, by: CGVector(dx: -1000, dy: 0))
        comparison.pan(from: .right, by: CGVector(dx: 30, dy: 0))
        #expect(abs(comparison[.left].viewPoint(forImage: .zero).x + 870) < 0.001)
        #expect(abs(comparison[.right].viewPoint(forImage: .zero).x + 870) < 0.001)
    }
}
