import CoreGraphics
import Foundation

/// Two fixed viewports. Linked movement is measured in screen pixels, so it also
/// works after the user aligns a detail in differently cropped photos.
public struct PhotoComparison: Sendable {
    public enum Side: CaseIterable, Sendable {
        case left, right
        public var other: Side { self == .left ? .right : .left }
    }

    private var left: ViewTransform
    private var right: ViewTransform
    private var initiallyFitted = true
    public var isLinked: Bool {
        didSet { if isLinked != oldValue { initiallyFitted = false } }
    }

    public init(_ left: ViewTransform, _ right: ViewTransform) {
        self.left = left
        self.right = right
        isLinked = false
        fit()
    }

    public private(set) subscript(_ side: Side) -> ViewTransform {
        get { side == .left ? left : right }
        set {
            switch side {
            case .left: left = newValue
            case .right: right = newValue
            }
        }
    }

    public func canMatchScale(from side: Side) -> Bool {
        hasSameProportions && self[side.other].scaleLimits.contains(matchedScale(from: side))
    }

    public mutating func matchScale(from side: Side) {
        guard canMatchScale(from: side) else { return }
        let other = side.other
        self[other] = self[other].zoomed(toScale: matchedScale(from: side), anchor: viewportCenter(other))
        isLinked = true
        initiallyFitted = false
    }

    public mutating func resize(left leftSize: CGSize, right rightSize: CGSize) {
        guard left.viewSize != leftSize || right.viewSize != rightSize else { return }
        let leftScale = left.scale, rightScale = right.scale
        left.viewSize = leftSize
        right.viewSize = rightSize
        if initiallyFitted {
            fit()
            return
        }
        let factor = isLinked ? sharedZoomFactor(1, leftScale: leftScale, rightScale: rightScale) : 1
        left.mode = .actual(leftScale * factor)
        right.mode = .actual(rightScale * factor)
        left = left.clamped
        right = right.clamped
    }

    public mutating func pan(from side: Side, by delta: CGVector) {
        if !isLinked {
            let moved = self[side].panned(by: delta)
            guard moved != self[side] else { return }
            self[side] = moved
            initiallyFitted = false
            return
        }
        let l = left.panLeftover(delta), r = right.panLeftover(delta)
        func shared(_ delta: CGFloat, _ l: CGFloat, _ r: CGFloat) -> CGFloat {
            let magnitude = max(0, abs(delta) - max(abs(l), abs(r)))
            return delta < 0 ? -magnitude : magnitude
        }
        let common = CGVector(dx: shared(delta.dx, l.dx, r.dx), dy: shared(delta.dy, l.dy, r.dy))
        guard common != .zero else { return }
        left = left.panned(by: common)
        right = right.panned(by: common)
        initiallyFitted = false
    }

    public mutating func zoom(from side: Side, by multiplier: Double, anchor: CGPoint) {
        guard multiplier.isFinite, multiplier > 0 else { return }
        let source = self[side]
        let other = side.other
        let target = self[other]
        let lower = source.scaleLimits.lowerBound / source.scale
        let upper = source.scaleLimits.upperBound / source.scale
        let factor = isLinked
            ? sharedZoomFactor(multiplier, leftScale: left.scale, rightScale: right.scale)
            : min(max(multiplier, lower), upper)
        guard factor != 1 else { return }
        self[side] = source.zoomed(toScale: source.scale * factor, anchor: anchor)
        if isLinked {
            let fromCenter = viewportCenter(side), toCenter = viewportCenter(other)
            let corresponding = CGPoint(x: anchor.x - fromCenter.x + toCenter.x,
                                        y: anchor.y - fromCenter.y + toCenter.y)
            self[other] = target.zoomed(toScale: target.scale * factor, anchor: corresponding)
        }
        initiallyFitted = false
    }

    private var hasSameProportions: Bool {
        let a = left.imageSize, b = right.imageSize
        return a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0 && a.width * b.height == b.width * a.height
    }

    private func matchedScale(from side: Side) -> Double {
        self[side].scale * (self[side].imageSize.width / self[side.other].imageSize.width)
    }

    private func viewportCenter(_ side: Side) -> CGPoint {
        let size = self[side].viewSize
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private func sharedZoomFactor(_ requested: Double, leftScale: Double, rightScale: Double) -> Double {
        let lower = max(left.scaleLimits.lowerBound / leftScale, right.scaleLimits.lowerBound / rightScale)
        let upper = min(left.scaleLimits.upperBound / leftScale, right.scaleLimits.upperBound / rightScale)
        return min(max(requested, lower), upper)
    }

    private mutating func fit() {
        left.mode = .fit
        right.mode = .fit
        left.center = CGPoint(x: 0.5, y: 0.5)
        right.center = left.center
        guard hasSameProportions else { return }
        let leftWidth = left.imageSize.width, rightWidth = right.imageSize.width
        let desired = min(left.scale * leftWidth, right.scale * rightWidth)
        let lower = max(left.scaleLimits.lowerBound * leftWidth, right.scaleLimits.lowerBound * rightWidth)
        func fittingWidth(_ transform: ViewTransform) -> Double {
            min(transform.viewSize.width, transform.viewSize.height * transform.imageSize.width / transform.imageSize.height)
        }
        let upper = min(fittingWidth(left), fittingWidth(right),
                        left.scaleLimits.upperBound * leftWidth, right.scaleLimits.upperBound * rightWidth)
        isLinked = lower <= upper
        initiallyFitted = true
        guard isLinked else { return }
        let width = min(max(desired, lower), upper)
        left.mode = .actual(width / leftWidth)
        right.mode = .actual(width / rightWidth)
    }
}
