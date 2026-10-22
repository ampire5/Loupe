import CoreGraphics

/// Where the pages of one spread sit in the virtual picture they are shown as. The picture is as tall as the page
/// with more pixels in height; the other page is scaled to that height, and the two touch with no gap.
public struct SpreadLayout: Equatable, Sendable {
    /// Size of the virtual picture, in the pixels of the taller page. May be zero when the pages have no size yet.
    public let virtualSize: CGSize
    /// A rectangle per page in virtual coordinates, left to right on screen.
    public let rects: [CGRect]
    /// Which page of the pair each rect holds: 0 the first, 1 the second.
    public let order: [Int]

    public init(first: CGSize, second: CGSize?, rightToLeft: Bool) {
        guard let second else {
            virtualSize = first
            rects = [CGRect(origin: .zero, size: first)]
            order = [0]
            return
        }
        let height = max(first.height, second.height)
        func scaled(_ s: CGSize) -> CGSize {
            s.height > 0 ? CGSize(width: s.width * height / s.height, height: height) : CGSize(width: 0, height: height)
        }
        let a = scaled(first), b = scaled(second)
        virtualSize = CGSize(width: a.width + b.width, height: height)
        if rightToLeft {
            rects = [CGRect(origin: .zero, size: b), CGRect(origin: CGPoint(x: b.width, y: 0), size: a)]
            order = [1, 0]
        } else {
            rects = [CGRect(origin: .zero, size: a), CGRect(origin: CGPoint(x: a.width, y: 0), size: b)]
            order = [0, 1]
        }
    }

    /// The page (0 first, 1 second) under a point of the virtual picture; nil outside every page.
    public func page(at point: CGPoint) -> Int? {
        rects.indices.first { rects[$0].contains(point) }.map { order[$0] }
    }

    /// The scale a page `pageHeight` px tall is drawn at when the virtual picture is drawn at `scale`: every page is as
    /// tall as the picture, so it is `scale` times its share of it. `scale` itself while either height is not known.
    public func pageScale(_ scale: Double, pageHeight: Double) -> Double {
        guard virtualSize.height > 0, pageHeight > 0 else { return scale }
        return scale * Double(virtualSize.height) / pageHeight
    }

    /// Two pages fit a view that is at least as wide as it is tall; a narrower one shows one page.
    public static func showsTwo(viewSize: CGSize) -> Bool {
        viewSize.height > 0 && viewSize.width / viewSize.height >= 1.0
    }
}
