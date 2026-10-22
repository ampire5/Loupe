import CoreGraphics
import simd

/// The one colour space two pages of a spread are shown in (spread spec, «Архитектура»): a layer has one tag, and each
/// photo's pixels stay in their own space (M3b spec §4.3). Two pages in the same space keep it, as a single photo does.
/// Two in different spaces are shown in Display P3, the wider of the usual pair (sRGB and Display P3); for any other
/// pair, whose gamuts are not ordered, Display P3 too, the space the app's own conversions go to (gray, CMYK). Each page
/// not already in it gets the matrix that takes its linear light to Display P3's, which the renderer folds into the
/// page's colour cube (`TileRenderer.conversion`).
public struct PairColorSpace: Sendable {
    /// The space to tag the layer with; nil: the pair needs nothing (one page, a page without a space yet, or both in
    /// the same space), and the layer is tagged as for a single photo.
    public let layer: CGColorSpace?
    /// Per page (first, second): the 3 x 3 matrix from its linear light to `layer`'s; nil: drawn as it is.
    public let first: simd_float3x3?
    public let second: simd_float3x3?

    public static let none = PairColorSpace(layer: nil, first: nil, second: nil)

    private init(layer: CGColorSpace?, first: simd_float3x3?, second: simd_float3x3?) {
        self.layer = layer
        self.first = first
        self.second = second
    }

    /// The spaces of the two pages' photos (nil: no page, or none known yet).
    public init(first a: CGColorSpace?, second b: CGColorSpace?) {
        guard let a, let b, a != b else {
            self = .none
            return
        }
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        func matrix(_ s: CGColorSpace) -> simd_float3x3? { s == p3 ? nil : Self.matrix(from: s, to: p3) }
        let (ma, mb) = (matrix(a), matrix(b))
        // A space that cannot be linearized stays as it is: better its own colours under the wrong tag than none.
        self.init(layer: ma == nil && mb == nil && a != p3 && b != p3 ? nil : p3, first: ma, second: mb)
    }

    /// The matrix from `source`'s linear light to `target`'s (relative colorimetric, as ColorSync converts between two
    /// D65 RGB spaces): its columns are `source`'s primaries converted into `target`'s extended linear variant. Nil when
    /// either space has no linearized variant (not a matrix-and-curve RGB space) or a conversion fails.
    public static func matrix(from source: CGColorSpace, to target: CGColorSpace) -> simd_float3x3? {
        guard let linearSource = CGColorSpaceCreateLinearized(source),
              let linearTarget = CGColorSpaceCreateExtendedLinearized(target) else { return nil }
        var columns: [SIMD3<Float>] = []
        for primary in [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]] as [[CGFloat]] {
            guard let colour = CGColor(colorSpace: linearSource, components: primary + [1]),
                  let converted = colour.converted(to: linearTarget, intent: .relativeColorimetric, options: nil),
                  let c = converted.components, c.count >= 3, c[0].isFinite, c[1].isFinite, c[2].isFinite
            else { return nil }
            columns.append(SIMD3(Float(c[0]), Float(c[1]), Float(c[2])))
        }
        return simd_float3x3(columns: (columns[0], columns[1], columns[2]))
    }
}
