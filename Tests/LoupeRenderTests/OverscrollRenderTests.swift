import CoreGraphics
import Foundation
import LoupeCore
import Metal
import Testing
@testable import LoupeRender

/// The rubber-band stretch (M4a spec §2.1): a frame whose `ViewTransform.offset` pulls the picture past its edge shows
/// the background there on every path, the picture moved by the offset and its edge pixels not repeated into the gap.
/// A 256 x 256 photo in a 200 x 200 view at the image's left edge, offset (40, 0), and at its bottom edge, offset
/// (0, -30), and fractional ones; every pixel is checked against the image's view rect (by pixel centre, as the renderer
/// cuts). Every path already honours the offset (LevelFrame.offset is `viewPoint(forImage: .zero)`; each path cuts to
/// the background by pixel centre, MetalFX in its final pass after reading the level clamped), so these pin it.
@Suite struct OverscrollRenderTests {
    private typealias Px = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

    /// Around the picture, and distinct from red and from the checker colours.
    private static let surround = BackgroundColor(red: 0x20, green: 0x60, blue: 0xa0)
    /// What the target holds before the frame, so a pixel no pass writes shows.
    private static let prefill = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)

    struct Path: CustomStringConvertible, Sendable {
        let name: String
        let settings: ResampleSettings
        let scale: Double
        let mode: ResampleMode
        var description: String { name }
    }

    static let paths: [Path] = [
        Path(name: "lanczos3", settings: ResampleSettings(pixelArtPercent: 0), scale: 1,
             mode: .kernel(.lanczos3, upscale: false)),
        Path(name: "nearest", settings: ResampleSettings(pixelArtPercent: 100), scale: 1, mode: .nearest),
        Path(name: "bilinear", settings: ResampleSettings(upscale: .bilinear, downscale: .bilinear, pixelArtPercent: 0),
             scale: 1, mode: .bilinear),
    ] + (MetalContext.shared.supportsMetalFX
        ? [Path(name: "metalfx", settings: ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0),
                scale: 2, mode: .metalfx)]
        : [])

    /// The brief's whole-pixel stretches, and fractional ones as a drag or the spring makes them (the edge pixel's
    /// centre decides, as everywhere).
    enum Edge: String, CaseIterable, Sendable {
        case left, bottom, leftFraction, bottomFraction
        /// The stretch past this edge, view px.
        var offset: CGVector {
            switch self {
            case .left: CGVector(dx: 40, dy: 0)
            case .bottom: CGVector(dx: 0, dy: -30)
            case .leftFraction: CGVector(dx: 40.37, dy: 0)
            case .bottomFraction: CGVector(dx: 0, dy: -29.6)
            }
        }
        /// The relative centre: pushed past the edge, `clamped` puts the view's edge on the image's.
        var centre: CGPoint {
            self == .left || self == .leftFraction ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 1)
        }
    }

    private static func renderer(_ path: Path) -> TileRenderer {
        let r = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
        r.resample = path.settings
        let c = surround.linear
        r.background = MTLClearColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        r.transparency = TransparencySettings(mode: .checker, checkerSizePt: 8, colors: .light, background: surround)
        r.backingScale = 1
        return r
    }

    private static func transform(_ path: Path, _ edge: Edge) -> ViewTransform {
        ViewTransform(imageSize: CGSize(width: 256, height: 256), viewSize: CGSize(width: 200, height: 200),
                      mode: .actual(path.scale), center: edge.centre).withOffset(edge.offset)
    }

    private static func render(_ image: TiledImage, _ t: ViewTransform, renderer: TileRenderer) async throws -> [UInt8] {
        let target = TestImages.renderTarget(Int(t.viewSize.width), Int(t.viewSize.height))
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = prefill
        pass.colorAttachments[0].storeAction = .store
        try #require(commands.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        renderer.encode(image: image, transform: t, into: commands, target: target)
        commands.commit()
        return try await TestImages.readTexture(target)
    }

    /// The bytes of a linear colour on the `_srgb` target.
    private static func encoded(_ r: Double, _ g: Double, _ b: Double) -> Px {
        func e(_ v: Double) -> UInt8 { UInt8((MetalContext.srgbEncode(min(max(v, 0), 1)) * 255).rounded()) }
        return (e(b), e(g), e(r), 255)
    }

    private static var background: Px { (surround.blue, surround.green, surround.red, 255) }

    /// Where the image's view rect starts and ends, view px: the edge the test names sits where the offset puts it.
    private static func imageRect(_ t: ViewTransform, _ edge: Edge) -> (min: CGPoint, max: CGPoint) {
        let a = t.viewPoint(forImage: .zero), b = t.viewPoint(forImage: CGPoint(x: 256, y: 256))
        switch edge {
        case .left, .leftFraction: #expect(a.x == edge.offset.dx)
        case .bottom, .bottomFraction: #expect(b.y == 200 + edge.offset.dy)
        }
        return (a, b)
    }

    /// The worst channel difference over the frame, and where, against `expected(x, y)`.
    private static func worst(_ frame: [UInt8], _ expected: (Int, Int) -> Px) -> (Int, Int, Int) {
        var worst = (0, -1, -1)
        for y in 0..<200 {
            for x in 0..<200 {
                let o = (y * 200 + x) * 4, e = expected(x, y)
                let d = max(abs(Int(frame[o]) - Int(e.b)), abs(Int(frame[o + 1]) - Int(e.g)),
                            abs(Int(frame[o + 2]) - Int(e.r)), abs(Int(frame[o + 3]) - Int(e.a)))
                if d > worst.0 { worst = (d, x, y) }
            }
        }
        return worst
    }

    private static func inside(_ rect: (min: CGPoint, max: CGPoint), _ x: Int, _ y: Int) -> Bool {
        let cx = Double(x) + 0.5, cy = Double(y) + 0.5
        return cx >= rect.min.x && cx < rect.max.x && cy >= rect.min.y && cy < rect.max.y
    }

    /// An opaque red photo: red inside its shifted view rect, the background past the edge (the left 40 columns, the
    /// bottom 30 rows), within one level.
    @Test(arguments: paths, Edge.allCases)
    func opaqueShowsBackgroundPastTheEdge(path: Path, edge: Edge) async throws {
        let image = try await TiledImage.make(from: TestImages.synthetic(256, 256) { _, _ in (0, 0, 255, 255) })
        let t = Self.transform(path, edge)
        let renderer = Self.renderer(path)
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == path.mode)
        let rect = Self.imageRect(t, edge)
        let red: Px = (0, 0, 255, 255)
        let (d, x, y) = Self.worst(frame) { Self.inside(rect, $0, $1) ? red : Self.background }
        #expect(d <= 1, "\(path) past the \(edge) edge: \(d) levels off at (\(x), \(y))")
    }

    /// A half-transparent red photo over the checkerboard: past the edge the background, as around a photo smaller than
    /// the view; inside, the photo over cells anchored on its shifted top-left corner. Neither the composited edge nor
    /// the cells run into the gap.
    @Test(arguments: paths, Edge.allCases)
    func alphaShowsBackgroundPastTheEdge(path: Path, edge: Edge) async throws {
        let image = try await TiledImage.make(from: TestImages.synthetic(256, 256) { _, _ in (0, 0, 128, 128) })
        #expect(image.hasAlpha)
        let t = Self.transform(path, edge)
        let renderer = Self.renderer(path)
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == path.mode)
        #expect(renderer.lastHasAlpha)
        let rect = Self.imageRect(t, edge)
        // Premultiplied linear red 128/255 at alpha 128/255, composited onto each cell colour.
        let a = 128.0 / 255, colors = renderer.transparency.colors
        func over(_ c: SIMD3<Float>) -> Px {
            Self.encoded(a + (1 - a) * Double(c.x), (1 - a) * Double(c.y), (1 - a) * Double(c.z))
        }
        let first = over(colors.0), second = over(colors.1)
        let ox = Float(rect.min.x), oy = Float(rect.min.y), inv = Float(1.0 / 8)
        let (d, x, y) = Self.worst(frame) { x, y in
            guard Self.inside(rect, x, y) else { return Self.background }
            let cx = ((Float(x) + 0.5 - ox) * inv).rounded(.down), cy = ((Float(y) + 0.5 - oy) * inv).rounded(.down)
            return Int(cx + cy) & 1 == 0 ? first : second
        }
        #expect(d <= 2, "\(path) with alpha past the \(edge) edge: \(d) levels off at (\(x), \(y))")
    }

    /// The zoom stretch (M4b spec §3): a 64 x 48 photo in a 256 x 256 view drawn with a stretch factor of 0.8 about the
    /// view centre appears at `drawnScale`: its extent in the frame is `imageSize * drawnScale` centred where
    /// `viewPoint(forImage:)` puts the photo's centre, and the filter is chosen from `drawnScale` too. The first case is
    /// the brief's (lower limit 0.25 -> 0.2, fragment path); a 64 x 48 photo has one level, and below a magnification of
    /// 0.5 the filter is bilinear, so the compute Lanczos path needs a scale of 1 -> 0.8 (the unstretched 1 would not
    /// change the mode but would draw 64 px wide, not 51); and 0.5 -> 0.4 shows the mode dropping from Lanczos to
    /// bilinear because `drawnScale` is below 0.5 while `scale` is not.
    struct StretchCase: CustomStringConvertible, Sendable {
        let name: String
        let settings: ResampleSettings
        let scale: Double
        let mode: ResampleMode
        var description: String { name }
    }

    static let stretchCases: [StretchCase] = [
        StretchCase(name: "fragment bilinear, lower limit 0.25 -> 0.2",
                    settings: ResampleSettings(upscale: .bilinear, downscale: .bilinear, pixelArtPercent: 0),
                    scale: 0.25, mode: .bilinear),
        StretchCase(name: "compute lanczos3, 1 -> 0.8", settings: ResampleSettings(pixelArtPercent: 0), scale: 1,
                    mode: .kernel(.lanczos3, upscale: false)),
        StretchCase(name: "filter follows drawnScale, 0.5 -> 0.4", settings: ResampleSettings(pixelArtPercent: 0),
                    scale: 0.5, mode: .bilinear),
    ]

    @Test(arguments: stretchCases)
    func zoomStretchDrawsAtDrawnScale(path: StretchCase) async throws {
        let image = try await TiledImage.make(from: TestImages.synthetic(64, 48) { _, _ in (0, 0, 255, 255) })
        let base = ViewTransform(imageSize: CGSize(width: 64, height: 48), viewSize: CGSize(width: 256, height: 256),
                                 mode: .actual(path.scale))
        #expect(path.scale != 0.25 || base.scale == base.scaleLimits.lowerBound)
        let t = base.withStretch(ZoomStretch(factor: 0.8, anchor: CGPoint(x: 128, y: 128)))
        #expect(abs(t.drawnScale - path.scale * 0.8) < 1e-12)
        let renderer = Self.renderer(Path(name: path.name, settings: path.settings, scale: path.scale, mode: path.mode))
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == path.mode)
        var cols = [Int](), rows = [Int]()
        for y in 0..<256 {
            for x in 0..<256 {
                let o = (y * 256 + x) * 4
                if (frame[o], frame[o + 1], frame[o + 2]) != (Self.background.b, Self.background.g, Self.background.r) {
                    cols.append(x)
                    rows.append(y)
                }
            }
        }
        let (c0, c1) = try (#require(cols.min()), #require(cols.max()))
        let (r0, r1) = try (#require(rows.min()), #require(rows.max()))
        let centre = t.viewPoint(forImage: CGPoint(x: 32, y: 24))
        let w = 64 * t.drawnScale, h = 48 * t.drawnScale
        #expect(abs(Double(c0) - (centre.x - w / 2)) <= 1 && abs(Double(c1 + 1) - (centre.x + w / 2)) <= 1,
                "\(path): columns \(c0)...\(c1) against \(centre.x - w / 2)...\(centre.x + w / 2)")
        #expect(abs(Double(r0) - (centre.y - h / 2)) <= 1 && abs(Double(r1 + 1) - (centre.y + h / 2)) <= 1,
                "\(path): rows \(r0)...\(r1) against \(centre.y - h / 2)...\(centre.y + h / 2)")
    }
}
