import CoreGraphics
import Foundation
import LoupeCore
import Metal
import simd
import Testing
@testable import LoupeRender

/// Two pages in one frame (spread spec, «Архитектура»): the first page's `encode` clears the target and draws its
/// picture, the second's draws only into its viewport (`clears: false`), each with the transform `PagePlacement` gives
/// it from the shared one. On every path the frame is the first page's colour in its viewport, the second's in its, the
/// background elsewhere, and nothing of what the target held before; where the pages touch, no column is lost.
@Suite struct TwoPageRenderTests {
    private typealias Px = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

    private static let surround = BackgroundColor(red: 0x20, green: 0x60, blue: 0xa0)
    /// What the target holds before the frame, so a pixel no pass writes shows.
    private static let prefill = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
    private static let view = CGSize(width: 400, height: 160)
    /// Pages of 100 x 150 and 50 x 75: a virtual picture of 200 x 150, the second page drawn at twice its scale.
    private static let sizes = [CGSize(width: 100, height: 150), CGSize(width: 50, height: 75)]
    private static let layout = SpreadLayout(first: sizes[0], second: sizes[1], rightToLeft: false)
    private static let colours: [Px] = [(0, 0, 255, 255), (0, 200, 0, 255)]

    struct Path: CustomStringConvertible, Sendable {
        let name: String
        let settings: ResampleSettings
        /// The shared transform's scale: the first page is drawn at it, the second at twice it.
        let scale: Double
        let modes: [ResampleMode]
        var description: String { name }
    }

    static let paths: [Path] = [
        Path(name: "lanczos3", settings: ResampleSettings(pixelArtPercent: 0), scale: 1.3,
             modes: [.kernel(.lanczos3, upscale: true), .kernel(.lanczos3, upscale: true)]),
        Path(name: "lanczos3 down, up", settings: ResampleSettings(pixelArtPercent: 0), scale: 0.7,
             modes: [.kernel(.lanczos3, upscale: false), .kernel(.lanczos3, upscale: true)]),
        Path(name: "nearest", settings: ResampleSettings(pixelArtPercent: 100), scale: 1.3, modes: [.nearest, .nearest]),
        Path(name: "bilinear", settings: ResampleSettings(upscale: .bilinear, downscale: .bilinear, pixelArtPercent: 0),
             scale: 1.3, modes: [.bilinear, .bilinear]),
    ] + (MetalContext.shared.supportsEWA
        ? [Path(name: "ewa", settings: ResampleSettings(upscale: .ewaLanczos, upscaleHighPercent: 0, pixelArtPercent: 0),
                scale: 1.3, modes: [.ewaLanczos, .ewaLanczos])]
        : [])
      + (MetalContext.shared.supportsMetalFX
        ? [Path(name: "metalfx", settings: ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0),
                scale: 1.3, modes: [.metalfx, .metalfx]),
           Path(name: "lanczos3, metalfx", settings: ResampleSettings(upscale: .metalfx, upscaleHigh: .kernel(.lanczos3),
                                                                     upscaleHighPercent: 200, pixelArtPercent: 0),
                scale: 1.3, modes: [.metalfx, .kernel(.lanczos3, upscale: true)])]
        : [])

    /// Where the pages' seam falls: on a pixel boundary, on a pixel centre, between, and a hair past a centre (where
    /// two roundings of the seam, one per page, could disagree by a column).
    static let seams: [Double] = [200, 200.5, 200.37, 200.5 + 1e-3, 200.5 + 1e-5]

    private static func renderer(_ path: Path) -> TileRenderer {
        let r = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
        r.resample = path.settings
        let c = surround.linear
        r.background = MTLClearColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        return r
    }

    /// The shared transform at `path.scale`, panned so that the seam lands on view x `seam`.
    private static func shared(_ path: Path, seam: Double) -> ViewTransform {
        let t = ViewTransform(imageSize: layout.virtualSize, viewSize: view, mode: .actual(path.scale))
        let at = t.viewPoint(forImage: CGPoint(x: layout.rects[1].minX, y: 0)).x
        return t.withOffset(CGVector(dx: seam - at, dy: 0))
    }

    private static func images() async throws -> [TiledImage] {
        var out: [TiledImage] = []
        for (size, colour) in zip(sizes, colours) {
            out.append(try await TiledImage.make(from: TestImages.synthetic(Int(size.width), Int(size.height)) { _, _ in
                colour
            }))
        }
        return out
    }

    /// Prefills a target, then encodes the pages as the render loop does: the first clearing, the next in its viewport.
    private static func render(_ images: [TiledImage?], _ shared: ViewTransform, renderer: TileRenderer,
                               modes: inout [ResampleMode?], colors: [ColorFrame?] = [nil, nil],
                               conversions: [simd_float3x3?] = [nil, nil]) async throws -> [UInt8] {
        let target = TestImages.renderTarget(Int(view.width), Int(view.height))
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = prefill
        pass.colorAttachments[0].storeAction = .store
        try #require(commands.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        modes = []
        for (i, image) in images.enumerated() {
            let place = PagePlacement(rect: layout.rects[i], pageSize: sizes[i], shared: shared)
            renderer.color = colors[i]
            renderer.conversion = conversions[i]
            renderer.encode(image: image, transform: place.transform, into: commands, target: target,
                            viewport: place.viewport, clears: i == 0)
            modes.append(renderer.lastMode)
        }
        commands.commit()
        return try await TestImages.readTexture(target)
    }

    private static var background: Px { (surround.blue, surround.green, surround.red, 255) }

    /// The worst channel difference over the frame against `expected(x, y)`, and where.
    private static func worst(_ frame: [UInt8], _ expected: (Int, Int) -> Px) -> (Int, Int, Int) {
        var worst = (0, -1, -1)
        let w = Int(view.width)
        for y in 0..<Int(view.height) {
            for x in 0..<w {
                let o = (y * w + x) * 4, e = expected(x, y)
                let d = max(abs(Int(frame[o]) - Int(e.b)), abs(Int(frame[o + 1]) - Int(e.g)),
                            abs(Int(frame[o + 2]) - Int(e.r)), abs(Int(frame[o + 3]) - Int(e.a)))
                if d > worst.0 { worst = (d, x, y) }
            }
        }
        return worst
    }

    private static func owner(_ viewports: [CGRect], _ x: Int, _ y: Int) -> Int? {
        let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
        return viewports.firstIndex { $0.contains(p) }
    }

    @Test(arguments: paths, seams)
    func twoPagesShareTheFrame(path: Path, seam: Double) async throws {
        let images = try await Self.images()
        let shared = Self.shared(path, seam: seam)
        let viewports = (0..<2).map { PagePlacement(rect: Self.layout.rects[$0], pageSize: Self.sizes[$0], shared: shared).viewport }
        #expect(viewports[0].maxX == viewports[1].minX)
        let renderer = Self.renderer(path)
        var modes: [ResampleMode?] = []
        let frame = try await Self.render(images, shared, renderer: renderer, modes: &modes)
        #expect(modes == path.modes.map { $0 })
        let (d, x, y) = Self.worst(frame) { x, y in Self.owner(viewports, x, y).map { Self.colours[$0] } ?? Self.background }
        #expect(d <= 1, "\(path), seam \(seam): \(d) levels off at (\(x), \(y))")
    }

    /// A second page without an image (still loading) draws nothing: its rect keeps the first page's background.
    @Test(arguments: paths)
    func missingSecondPageLeavesTheBackground(path: Path) async throws {
        let images = try await Self.images()
        let shared = Self.shared(path, seam: 200.37)
        let first = PagePlacement(rect: Self.layout.rects[0], pageSize: Self.sizes[0], shared: shared).viewport
        var modes: [ResampleMode?] = []
        let frame = try await Self.render([images[0], nil], shared, renderer: Self.renderer(path), modes: &modes)
        #expect(modes[1] == nil)
        let (d, x, y) = Self.worst(frame) { x, y in Self.owner([first], x, y) != nil ? Self.colours[0] : Self.background }
        #expect(d <= 1, "\(path): \(d) levels off at (\(x), \(y))")
    }

    // MARK: Two colour spaces

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998)!

    /// A colour's bytes in `space` as Display P3 bytes (ColorSync, relative colorimetric): the reference conversion.
    private static func inP3(_ c: Px, from space: CGColorSpace) -> Px {
        let colour = CGColor(colorSpace: space, components: [CGFloat(c.r) / 255, CGFloat(c.g) / 255, CGFloat(c.b) / 255, 1])!
        let p = colour.converted(to: p3, intent: .relativeColorimetric, options: nil)!.components!
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        return (byte(p[2]), byte(p[1]), byte(p[0]), 255)
    }

    private static func page(_ i: Int, _ colour: Px, _ space: CGColorSpace) async throws -> TiledImage {
        try await TiledImage.make(from: TestImages.synthetic(Int(sizes[i].width), Int(sizes[i].height), colorSpace: space) {
            _, _ in colour
        })
    }

    /// Saturated colours, where sRGB and Display P3 bytes differ most, and a grey, which they share.
    static let spaceColours: [(b: UInt8, g: UInt8, r: UInt8)] = [(30, 40, 200), (60, 180, 30), (220, 40, 20),
                                                                  (128, 128, 128), (10, 230, 240)]

    /// An sRGB page beside a Display P3 one: the layer is P3, the sRGB page is converted through its cube (here the
    /// identity, converted), the P3 one is drawn as it is. Both end up as ColorSync would show them, on every path.
    @Test(arguments: paths)
    func srgbBesideP3IsConvertedIntoP3(path: Path) async throws {
        let pair = PairColorSpace(first: Self.srgb, second: Self.p3)
        #expect(pair.layer == Self.p3 && pair.first != nil && pair.second == nil)
        let shared = Self.shared(path, seam: 200.37)
        let viewports = (0..<2).map { PagePlacement(rect: Self.layout.rects[$0], pageSize: Self.sizes[$0], shared: shared).viewport }
        for c in Self.spaceColours {
            let colour: Px = (c.b, c.g, c.r, 255)
            let images = [try await Self.page(0, colour, Self.srgb), try await Self.page(1, colour, Self.p3)]
            var modes: [ResampleMode?] = []
            let frame = try await Self.render(images, shared, renderer: Self.renderer(path), modes: &modes,
                                              conversions: [pair.first, pair.second])
            let expected = [Self.inP3(colour, from: Self.srgb), colour]
            let (d, x, y) = Self.worst(frame) { x, y in Self.owner(viewports, x, y).map { expected[$0] } ?? Self.background }
            #expect(d <= 1, "\(path), \(c): \(d) levels off at (\(x), \(y))")
        }
    }

    /// A page with a curve of its own (Adobe RGB, γ 2.2, drawn with CURVE_TABLE alone) beside a P3 one: converted, it is
    /// drawn with the sRGB curve, and within the 8-bit storage of its light (one or two levels) of ColorSync's colour.
    @Test(arguments: paths)
    func curvedPageIsConvertedToo(path: Path) async throws {
        let pair = PairColorSpace(first: Self.adobe, second: Self.p3)
        let shared = Self.shared(path, seam: 200.37)
        let viewports = (0..<2).map { PagePlacement(rect: Self.layout.rects[$0], pageSize: Self.sizes[$0], shared: shared).viewport }
        // Inside P3's gamut (Adobe RGB's own green is not): the conversion is exact there.
        for c in [(UInt8(40), UInt8(60), UInt8(180)), (60, 150, 90), (128, 128, 128)] {
            let colour: Px = (c.0, c.1, c.2, 255)
            let images = [try await Self.page(0, colour, Self.adobe), try await Self.page(1, colour, Self.p3)]
            var modes: [ResampleMode?] = []
            let renderer = Self.renderer(path)
            let frame = try await Self.render(images, shared, renderer: renderer, modes: &modes,
                                              conversions: [pair.first, pair.second])
            let expected = [Self.inP3(colour, from: Self.adobe), colour]
            let (d, x, y) = Self.worst(frame) { x, y in Self.owner(viewports, x, y).map { expected[$0] } ?? Self.background }
            #expect(d <= 2, "\(path), \(c): \(d) levels off at (\(x), \(y))")
        }
    }

    /// The page's own correction comes first, then the conversion: a cube that halves every encoded value, on an sRGB
    /// page beside a P3 one, shows the halved colour converted. A fade from the identity to it, halfway, mixes the two
    /// in linear light, both converted.
    @Test func correctionThenConversion() async throws {
        let path = Self.paths[0]
        let pair = PairColorSpace(first: Self.srgb, second: Self.p3)
        let shared = Self.shared(path, seam: 200.37)
        let viewport = PagePlacement(rect: Self.layout.rects[0], pageSize: Self.sizes[0], shared: shared).viewport
        let n = ColorCube.dimension, last = Float(n - 1)
        var values = [Float16](repeating: 1, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = ((b * n + g) * n + r) * 4
            values[i] = Float16(Float(r) / last / 2); values[i + 1] = Float16(Float(g) / last / 2)
            values[i + 2] = Float16(Float(b) / last / 2)
        } } }
        let half = try #require(ColorLUT.make(ColorCube(values: values)))
        let colour: Px = (40, 60, 200, 255)
        let halved: Px = (20, 30, 100, 255)
        let images = [try await Self.page(0, colour, Self.srgb), try await Self.page(1, colour, Self.p3)]
        var modes: [ResampleMode?] = []
        let frame = try await Self.render(images, shared, renderer: Self.renderer(path), modes: &modes,
                                          colors: [ColorFrame(lut: half), nil], conversions: [pair.first, nil])
        let expected = Self.inP3(halved, from: Self.srgb)
        // Checked on page 1's viewport only (page 2 is the P3 colour, the background around both).
        let w = Int(Self.view.width)
        var worst = 0
        for y in Int(viewport.minY)..<Int(viewport.maxY) {
            for x in Int(viewport.minX)..<Int(viewport.maxX) {
                let o = (y * w + x) * 4
                worst = max(worst, abs(Int(frame[o]) - Int(expected.b)), abs(Int(frame[o + 1]) - Int(expected.g)),
                            abs(Int(frame[o + 2]) - Int(expected.r)))
            }
        }
        #expect(worst <= 1, "halved and converted: \(worst) levels off")

        // Halfway through a fade from no correction: linear light halfway between the colour and the halved one.
        let fading = try await Self.render(images, shared, renderer: Self.renderer(path), modes: &modes,
                                           colors: [ColorFrame(lut: half, from: nil, mix: 0.5), nil],
                                           conversions: [pair.first, nil])
        func lin(_ v: UInt8) -> Double { MetalContext.srgbDecode(Double(v) / 255) }
        func enc(_ l: Double) -> UInt8 { UInt8((MetalContext.srgbEncode(l) * 255).rounded()) }
        let mid: Px = (enc((lin(colour.b) + lin(halved.b)) / 2), enc((lin(colour.g) + lin(halved.g)) / 2),
                       enc((lin(colour.r) + lin(halved.r)) / 2), 255)
        let expectedMid = Self.inP3(mid, from: Self.srgb)
        worst = 0
        for y in Int(viewport.minY)..<Int(viewport.maxY) {
            for x in Int(viewport.minX)..<Int(viewport.maxX) {
                let o = (y * w + x) * 4
                worst = max(worst, abs(Int(fading[o]) - Int(expectedMid.b)), abs(Int(fading[o + 1]) - Int(expectedMid.g)),
                            abs(Int(fading[o + 2]) - Int(expectedMid.r)))
            }
        }
        #expect(worst <= 2, "fade, converted: \(worst) levels off")
    }

    /// Two pages in the same space need nothing (`PairColorSpace` gives no matrix): the frame is the frame of before.
    @Test(arguments: paths)
    func sameSpacesAreUnchanged(path: Path) async throws {
        for space in [Self.srgb, Self.p3, Self.adobe] {
            let pair = PairColorSpace(first: space, second: space)
            #expect(pair.layer == nil && pair.first == nil && pair.second == nil)
            let colour: Px = (30, 40, 200, 255)
            let images = [try await Self.page(0, colour, space), try await Self.page(1, colour, space)]
            let shared = Self.shared(path, seam: 200.37)
            var modes: [ResampleMode?] = []
            let plain = try await Self.render(images, shared, renderer: Self.renderer(path), modes: &modes)
            let paired = try await Self.render(images, shared, renderer: Self.renderer(path), modes: &modes,
                                               conversions: [pair.first, pair.second])
            #expect(plain == paired)
        }
    }

    /// A first page off screen (an empty viewport) only clears: no path runs for it (MetalFX's compose and scaler
    /// included, whose stage is not even made), and the second page draws as usual.
    @Test(arguments: paths)
    func offScreenFirstPageOnlyClears(path: Path) async throws {
        let images = try await Self.images()
        let shared = Self.shared(path, seam: -20.3)
        let viewports = (0..<2).map { PagePlacement(rect: Self.layout.rects[$0], pageSize: Self.sizes[$0], shared: shared).viewport }
        #expect(viewports[0].isEmpty && !viewports[1].isEmpty)
        let renderer = Self.renderer(path)
        var modes: [ResampleMode?] = []
        let frame = try await Self.render(images, shared, renderer: renderer, modes: &modes)
        #expect(modes[0] == nil && modes[1] == path.modes[1])
        if path.modes[1] != .metalfx { #expect(!renderer.holdsMetalFX) }
        let (d, x, y) = Self.worst(frame) { x, y in Self.owner(viewports, x, y).map { Self.colours[$0] } ?? Self.background }
        #expect(d <= 1, "\(path): \(d) levels off at (\(x), \(y))")
    }

    /// A call that does not clear writes nothing outside its viewport, on every path: the prefill stays there.
    @Test(arguments: paths)
    func nonClearingCallStaysInItsViewport(path: Path) async throws {
        let images = try await Self.images()
        let shared = Self.shared(path, seam: 200.37)
        let place = PagePlacement(rect: Self.layout.rects[1], pageSize: Self.sizes[1], shared: shared)
        let target = TestImages.renderTarget(Int(Self.view.width), Int(Self.view.height))
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = Self.prefill
        pass.colorAttachments[0].storeAction = .store
        try #require(commands.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        // A viewport narrower than the page's own: the picture is cut at it.
        let viewport = place.viewport.insetBy(dx: 5, dy: 7)
        Self.renderer(path).encode(image: images[1], transform: place.transform, into: commands, target: target,
                                   viewport: viewport, clears: false)
        commands.commit()
        let frame = try await TestImages.readTexture(target)
        let magenta: Px = (255, 0, 255, 255)
        let (d, x, y) = Self.worst(frame) { x, y in Self.owner([viewport], x, y) != nil ? Self.colours[1] : magenta }
        #expect(d <= 1, "\(path): \(d) levels off at (\(x), \(y))")
    }

    /// Frames of a spread whose pages take different paths, one of them MetalFX, keep the MetalFX stage from frame to
    /// frame (no ~85 MB remade per frame); a frame without MetalFX on either page lets it go.
    @Test func mixedSpreadKeepsTheMetalFXStage() async throws {
        guard MetalContext.shared.supportsMetalFX else { return }
        let images = try await Self.images()
        let path = Self.paths.first { $0.name == "lanczos3, metalfx" }!
        let renderer = Self.renderer(path)
        var modes: [ResampleMode?] = []
        _ = try await Self.render(images, Self.shared(path, seam: 200), renderer: renderer, modes: &modes)
        let stage = try #require(renderer.metalFX)
        for _ in 0..<2 {
            _ = try await Self.render(images, Self.shared(path, seam: 200), renderer: renderer, modes: &modes)
            #expect(renderer.metalFX === stage)
        }
        // The pages swapped (MetalFX second): the frame of the swap remakes it once (its first page cannot know the
        // second will want it), the frames after keep it.
        renderer.resample = ResampleSettings(upscale: .kernel(.lanczos3), upscaleHigh: .metalfx, upscaleHighPercent: 200,
                                             pixelArtPercent: 0)
        _ = try await Self.render(images, Self.shared(path, seam: 200), renderer: renderer, modes: &modes)
        #expect(modes == [.kernel(.lanczos3, upscale: true), .metalfx])
        let second = try #require(renderer.metalFX)
        for _ in 0..<2 {
            _ = try await Self.render(images, Self.shared(path, seam: 200), renderer: renderer, modes: &modes)
            #expect(renderer.metalFX === second)
        }
        renderer.resample = ResampleSettings(pixelArtPercent: 0)
        _ = try await Self.render(images, Self.shared(path, seam: 200), renderer: renderer, modes: &modes)
        _ = try await Self.render(images, Self.shared(path, seam: 200), renderer: renderer, modes: &modes)
        #expect(renderer.metalFX == nil)
    }
}
