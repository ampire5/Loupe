import CoreGraphics
import Foundation
import ImageIO
import LoupeCore
import Metal
import Testing
import UniformTypeIdentifiers
@testable import LoupeRender

/// Transparency (M3b spec §3): a photo with alpha < 1 is uploaded as premultiplied linear light and drawn over a
/// checkerboard or a colour by the `HAS_ALPHA` pipelines, against a CPU double reference; soft edges do not darken; the
/// cells' size and anchor; an alpha channel that is all 255 keeps the ordinary pipelines.
@Suite struct TransparencyRendererTests {
    private typealias Px = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

    private static let lanczos = ResampleSettings(upscale: .kernel(.lanczos3), upscaleHighPercent: 0,
                                                  downscale: .kernel(.lanczos3), antiringing: false, pixelArtPercent: 0)
    private static let ewa = ResampleSettings(upscale: .ewaLanczos, upscaleHighPercent: 0, pixelArtPercent: 0)
    private static let metalfx = ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0)
    private static let bilinear = ResampleSettings(upscale: .bilinear, downscale: .bilinear, pixelArtPercent: 0)
    private static let pixelArt = ResampleSettings(upscaleHighPercent: 0, pixelArtPercent: 400)

    /// Around the picture, and the `background` mode's colour.
    private static let surround = BackgroundColor(red: 0x20, green: 0x60, blue: 0xa0)

    private static func renderer(_ settings: ResampleSettings, _ mode: TransparencyMode,
                                 colors: CheckerColors = .light, scale: Double = 2) -> TileRenderer {
        let r = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
        r.resample = settings
        let c = surround.linear
        r.background = MTLClearColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        r.transparency = TransparencySettings(mode: mode, checkerSizePt: 8, colors: colors, background: surround)
        r.backingScale = scale
        return r
    }

    private static func transform(_ width: Int, _ height: Int, view: (Int, Int) = (401, 263), _ mode: ZoomMode,
                                  centre: (Double, Double)) -> ViewTransform {
        ViewTransform(imageSize: CGSize(width: width, height: height), viewSize: CGSize(width: view.0, height: view.1),
                      mode: mode, center: CGPoint(x: centre.0 / Double(width), y: centre.1 / Double(height)))
    }

    private static func render(_ image: TiledImage, _ t: ViewTransform, renderer: TileRenderer) async throws -> [UInt8] {
        let target = TestImages.renderTarget(Int(t.viewSize.width), Int(t.viewSize.height))
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        renderer.encode(image: image, transform: t, into: commands, target: target)
        commands.commit()
        return try await TestImages.readTexture(target)
    }

    private static func pixel(_ bytes: [UInt8], width: Int, _ x: Int, _ y: Int) -> Px {
        let o = (y * width + x) * 4
        return (bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3])
    }

    /// Whether the centre of view pixel (x, y) lies inside the image's view rect.
    private static func inside(_ t: ViewTransform, _ x: Int, _ y: Int) -> Bool {
        let a = t.viewPoint(forImage: .zero), b = t.viewPoint(forImage: CGPoint(x: t.imageSize.width, y: t.imageSize.height))
        let cx = Double(x) + 0.5, cy = Double(y) + 0.5
        return cx >= a.x && cx < b.x && cy >= a.y && cy < b.y
    }

    /// Premultiplied BGRA bytes as a decoder makes them: the straight colour's encoded bytes times alpha, rounded.
    private static func premultiplied(_ straight: (r: UInt8, g: UInt8, b: UInt8), alpha a: UInt8) -> Px {
        func p(_ c: UInt8) -> UInt8 { UInt8((Double(c) * Double(a) / 255).rounded()) }
        return (p(straight.b), p(straight.g), p(straight.r), a)
    }

    /// The soft-edged test picture, 700 x 460 (two pyramid levels): noise colours under a disc feathered over 12 px, a
    /// band whose alpha ramps left to right, a hard opaque block and a hard half-transparent one; transparent elsewhere.
    private static let softSize = (700, 460)
    private static func softEdged(_ x: Int, _ y: Int) -> Px {
        let d = hypot(Double(x) - 350.5, Double(y) - 230.5)
        var a = min(max((160 - d) / 12 + 0.5, 0), 1)
        if (400..<440).contains(y) { a = max(a, Double(x) / 699) }
        if (20..<90).contains(x), (20..<110).contains(y) { a = 1 }
        if (580..<670).contains(x), (20..<130).contains(y) { a = 0.5 }
        let n = TestImages.noiseAndEdges(x, y)
        return premultiplied((n.r, n.g, n.b), alpha: UInt8((a * 255).rounded()))
    }

    /// Premultiplied linear light and alpha of a decoder's pixel, in double: `lin(s / a) · a`.
    private static func premultipliedLinear(_ p: Px) -> (rgb: (Double, Double, Double), a: Double) {
        guard p.a > 0 else { return ((0, 0, 0), 0) }
        let a = Double(p.a) / 255
        func lin(_ s: UInt8) -> Double { MetalContext.srgbDecode(min(Double(s) / Double(p.a), 1)) * a }
        return ((lin(p.r), lin(p.g), lin(p.b)), a)
    }

    /// The backdrop the renderer draws under view px (x, y), in its Float arithmetic: cells of `cell` px from the image's
    /// view origin, `first` where the cell coordinates sum to an even number.
    private static func backdrop(_ t: ViewTransform, _ settings: TransparencySettings, cell: Double)
        -> (Int, Int) -> (Double, Double, Double) {
        let origin = t.viewPoint(forImage: .zero)
        let ox = Float(origin.x), oy = Float(origin.y), inv = Float(1 / cell)
        let first = settings.colors.0, second = settings.colors.1
        return { x, y in
            let cx = ((Float(x) + 0.5 - ox) * inv).rounded(.down), cy = ((Float(y) + 0.5 - oy) * inv).rounded(.down)
            let c = Int(cx + cy) & 1 == 0 ? first : second
            return (Double(c.x), Double(c.y), Double(c.z))
        }
    }

    // MARK: Against the reference

    @Test(TestLevel.fullOnly, arguments: [TransparencyMode.checker, .background, .black, .white], [0.45, 0.5, 1, 3])
    func alphaCompositeMatchesReference(mode: TransparencyMode, scale: Double) async throws {
        let (width, height) = Self.softSize
        let image = try await TiledImage.make(from: TestImages.synthetic(width, height, pixel: Self.softEdged))
        #expect(image.hasAlpha)
        // Off-centre, so the view holds the disc's edge, the band and the blocks at every scale.
        let t = Self.transform(width, height, .actual(scale), centre: (430.37, 290.71))
        let paths: [(String, ResampleSettings)] = scale > 1 ? [("lanczos3", Self.lanczos), ("ewa", Self.ewa)]
                                                            : [("lanczos3", Self.lanczos)]
        for (name, settings) in paths {
            let renderer = Self.renderer(settings, mode)
            let frame = try await Self.render(image, t, renderer: renderer)
            #expect(renderer.lastHasAlpha)
            let level = try #require(renderer.lastLevel)
            // Level 0 from the decoder's bytes in double; a coarser one as the GPU built it (its bytes are premultiplied
            // linear light already: `alphaPyramidIsPremultipliedLinear` checks how they were made).
            var source: (Int, Int) -> (rgb: (Double, Double, Double), a: Double) = { Self.premultipliedLinear(Self.softEdged($0, $1)) }
            let size = image.grid.levelSize(level)
            if level > 0 {
                let decoded = try await TestImages.readLevel(try #require(image.residentViews()[level]), grid: image.grid,
                                                             level: level)
                let base = decoded.buffer.bytes.assumingMemoryBound(to: UInt8.self), stride = decoded.bytesPerRow
                let bytes = Array(UnsafeBufferPointer(start: base, count: stride * size.height))
                let lin = ResampleReference.linear
                source = { x, y in
                    let o = y * stride + x * 4
                    return ((lin(bytes[o + 2]), lin(bytes[o + 1]), lin(bytes[o])), Double(bytes[o + 3]) / 255)
                }
            }
            let factor = Double(1 << level), origin = t.viewPoint(forImage: .zero)
            let f = { (v: Double) in Double(Float(v)) }
            let m = f(t.scale * factor), offset = SIMD2(f(origin.x), f(origin.y))
            let extent = SIMD2(f(Double(width) / factor), f(Double(height) / factor))
            let back = Self.backdrop(t, renderer.transparency, cell: 16)
            let c = Self.surround.linear, outside = (c.red, c.green, c.blue)
            let w = Int(t.viewSize.width), h = Int(t.viewSize.height)
            let expected = name == "ewa"
                ? ResampleReference.renderEWAComposite(source: { source($0, $1).rgb }, alpha: { source($0, $1).a },
                                                       width: size.width, height: size.height, m: m, offset: offset,
                                                       extent: extent, viewWidth: w, viewHeight: h, background: outside,
                                                       backdrop: back)
                : ResampleReference.renderComposite(source: { source($0, $1).rgb }, alpha: { source($0, $1).a },
                                                    width: size.width, height: size.height, kernel: .lanczos3, m: m,
                                                    offset: offset, extent: extent, viewWidth: w, viewHeight: h,
                                                    background: outside, backdrop: back)
            let psnr = ResampleReference.psnr(frame, expected, width: w)
            #expect(psnr >= 50, "\(mode) x\(scale) \(name) (level \(level)): \(psnr) dB")
        }
    }

    @Test(arguments: [TransparencyMode.checker, .white])
    func tilePathsMatchReference(mode: TransparencyMode) async throws {
        // The fragment paths with alpha against the same CPU reference: bilinear (magnifying and reducing, level 0) in
        // premultiplied linear light, and nearest (pixel art), each composited over the backdrop.
        let (width, height) = Self.softSize
        let image = try await TiledImage.make(from: TestImages.synthetic(width, height, pixel: Self.softEdged))
        let source = { (x: Int, y: Int) in
            Self.premultipliedLinear(Self.softEdged(min(max(x, 0), width - 1), min(max(y, 0), height - 1)))
        }
        for (name, settings, scale) in [("bilinear", Self.bilinear, 1.37), ("bilinear", Self.bilinear, 0.66),
                                        ("nearest", Self.pixelArt, 4.0)] {
            let t = Self.transform(width, height, .actual(scale), centre: (430.37, 290.71))
            let renderer = Self.renderer(settings, mode)
            let frame = try await Self.render(image, t, renderer: renderer)
            #expect(renderer.lastHasAlpha && renderer.lastLevel == 0)
            let origin = t.viewPoint(forImage: .zero), m = Double(Float(t.scale))
            let ox = Double(Float(origin.x)), oy = Double(Float(origin.y))
            let back = Self.backdrop(t, renderer.transparency, cell: 16)
            let c = Self.surround.linear
            let w = Int(t.viewSize.width), h = Int(t.viewSize.height)
            var expected = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    var rgb = (c.red, c.green, c.blue)
                    if Self.inside(t, x, y) {
                        let u = (Double(x) + 0.5 - ox) / m, v = (Double(y) + 0.5 - oy) / m
                        var p: (rgb: (Double, Double, Double), a: Double)
                        if name == "nearest" {
                            p = source(Int(u.rounded(.down)), Int(v.rounded(.down)))
                        } else {
                            // Texel centres at i + 0.5, the sample point clamped half a texel inside the level.
                            let tx = min(max(u, 0.5), Double(width) - 0.5) - 0.5
                            let ty = min(max(v, 0.5), Double(height) - 0.5) - 0.5
                            let ix = Int(tx.rounded(.down)), iy = Int(ty.rounded(.down))
                            let fx = tx - Double(ix), fy = ty - Double(iy)
                            p = ((0, 0, 0), 0)
                            for (dx, dy, wt) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)),
                                                 (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
                                let q = source(ix + dx, iy + dy)
                                p.rgb.0 += wt * q.rgb.0; p.rgb.1 += wt * q.rgb.1; p.rgb.2 += wt * q.rgb.2
                                p.a += wt * q.a
                            }
                        }
                        let b = back(x, y)
                        rgb = (p.rgb.0 + (1 - p.a) * b.0, p.rgb.1 + (1 - p.a) * b.1, p.rgb.2 + (1 - p.a) * b.2)
                    }
                    let o = (y * w + x) * 4
                    expected[o] = ResampleReference.encode(rgb.2)
                    expected[o + 1] = ResampleReference.encode(rgb.1)
                    expected[o + 2] = ResampleReference.encode(rgb.0)
                }
            }
            let psnr = ResampleReference.psnr(frame, expected, width: w)
            #expect(psnr >= 50, "\(mode) \(name) x\(scale): \(psnr) dB")
        }
    }

    @Test func noDarkFringe() async throws {
        // A red disc feathered over 8 px: over white every pixel is exactly red in R and equal in G and B; over the
        // light checker each channel lies between red's and its cell's (2 levels for ringing). Compositing the stored
        // bytes as they are linearised (lin(e·a) instead of lin(e)·a) darkens the feather by 19 (nearest) to 38 levels.
        let disc = { (x: Int, y: Int) -> Px in
            let d = hypot(Double(x) - 64, Double(y) - 48)
            let a = min(max((40 - d) / 8 + 0.5, 0), 1)
            return Self.premultiplied((255, 0, 0), alpha: UInt8((a * 255).rounded()))
        }
        let image = try await TiledImage.make(from: TestImages.synthetic(128, 96, pixel: disc))
        let paths: [(String, ResampleSettings, Double)] = [
            ("bilinear", Self.bilinear, 1.37), ("lanczos3 down", Self.lanczos, 0.66), ("lanczos3 up", Self.lanczos, 2.5),
            ("nearest", Self.pixelArt, 4), ("ewa-lanczos", Self.ewa, 2.5), ("metalfx", Self.metalfx, 2.5),
        ]
        for (name, settings, scale) in paths {
            let t = Self.transform(128, 96, view: (240, 180), .actual(scale), centre: (64.3, 48.6))
            for mode in [TransparencyMode.white, .checker] {
                let renderer = Self.renderer(settings, mode)
                let frame = try await Self.render(image, t, renderer: renderer)
                #expect(renderer.lastHasAlpha, "\(name)")
                let back = Self.backdrop(t, renderer.transparency, cell: 16)
                var worst = 0
                for y in 0..<180 {
                    for x in 0..<240 where Self.inside(t, x, y) {
                        let p = Self.pixel(frame, width: 240, x, y)
                        let cell = Int(ResampleReference.encode(back(x, y).0))
                        // R between cell and 255, G and B between 0 and cell.
                        let off = max(cell - Int(p.r), Int(p.g) - cell, Int(p.b) - cell, 0)
                        worst = max(worst, off, mode == .white ? abs(Int(p.g) - Int(p.b)) : 0)
                    }
                }
                #expect(worst <= (mode == .white ? 1 : 2), "\(name) over \(mode): \(worst) levels outside")
            }
        }
    }

    @Test(arguments: [2.5, 8])
    func metalFXCheckerIsMetalFXOverEachCellColour(scale: Double) async throws {
        // Review probe: under MetalFX each checker cell must be exactly what MetalFX draws of the picture over a solid
        // backdrop of that cell's colour. A grey disc with a hard 0/255 edge and a ring with a 1 px anti-aliased edge,
        // where the scaler's edge is sharper than any bilinear alpha (one run plus a bilinear-alpha correction was 32-78
        // levels off in the second cells).
        let disc = { (x: Int, y: Int) -> Px in
            let d = hypot(Double(x) - 63.5, Double(y) - 47.5)
            let a: Double = d < 30 ? 1 : (d < 38 ? 0 : min(max(45 - d, 0), 1))   // hard disc, then a 1 px soft ring
            return Self.premultiplied((128, 128, 128), alpha: UInt8((a * 255).rounded()))
        }
        let image = try await TiledImage.make(from: TestImages.synthetic(128, 96, pixel: disc))
        // Centred on the disc's right edge, so both edges are in view at x8 too.
        let t = Self.transform(128, 96, view: (320, 240), .actual(scale), centre: (95.3, 50.6))
        let light = CheckerColors.light
        let checker = try await Self.render(image, t, renderer: Self.renderer(Self.metalfx, .checker))
        let first = try await Self.render(image, t, renderer: Self.renderer(Self.metalfx, .checker,
                                                                            colors: CheckerColors(light.first, light.first)))
        let second = try await Self.render(image, t, renderer: Self.renderer(Self.metalfx, .checker,
                                                                             colors: CheckerColors(light.second, light.second)))
        let back = Self.backdrop(t, TransparencySettings(mode: .checker, checkerSizePt: 8, colors: light), cell: 16)
        let white = Float(BackgroundColor(gray: 0xff).linear.red)
        var worst = (first: 0, second: 0), seconds = 0
        for y in 0..<240 {
            for x in 0..<320 where Self.inside(t, x, y) {
                let isFirst = Float(back(x, y).0) == white
                let p = Self.pixel(checker, width: 320, x, y), q = Self.pixel(isFirst ? first : second, width: 320, x, y)
                let d = max(abs(Int(p.r) - Int(q.r)), abs(Int(p.g) - Int(q.g)), abs(Int(p.b) - Int(q.b)))
                if isFirst { worst.first = max(worst.first, d) } else { worst.second = max(worst.second, d); seconds += 1 }
            }
        }
        #expect(seconds > 1000)
        #expect(worst.first <= 2 && worst.second <= 2, "x\(scale): first cells \(worst.first), second \(worst.second) levels")
    }

    @Test(arguments: [2.5, 8])
    func metalFXCheckerOfATurnedPhotoMatchesTheTurnedPixels(scale: Double) async throws {
        // A photo with EXIF 6 (stored 128 x 96, shown 96 x 128) through the two-run checker path: every cell is MetalFX over
        // that cell's solid colour, with no fringe where the turned edge meets the cells, and the frame is the one of the
        // same picture turned beforehand and drawn upright (the CPU turn is the reference for the compose pass's mapping).
        let orientation = ImageOrientation.right
        let disc = { (x: Int, y: Int) -> Px in
            let d = hypot(Double(x) - 63.5, Double(y) - 47.5)
            let a: Double = d < 30 ? 1 : (d < 38 ? 0 : min(max(45 - d, 0), 1))
            return Self.premultiplied((UInt8(60 + x), UInt8(200 - y), 128), alpha: UInt8((a * 255).rounded()))
        }
        let storedSize = CGSize(width: 128, height: 96)
        let shown = { (x: Int, y: Int) -> Px in
            let p = orientation.storedPoint(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), storedSize: storedSize)
            return disc(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
        }
        let turned = try await TiledImage.make(from: TestImages.synthetic(128, 96, pixel: disc))
        let upright = try await TiledImage.make(from: TestImages.synthetic(96, 128, pixel: shown))
        // Shown coordinates of the disc's turned right edge: both the hard edge and the ring are in view.
        let t = Self.transform(96, 128, view: (240, 320), .actual(scale), centre: (48.5, 93.9))
        func frame(_ image: TiledImage, _ turn: ImageOrientation, _ colors: CheckerColors) async throws -> [UInt8] {
            let r = Self.renderer(Self.metalfx, .checker, colors: colors)
            let target = TestImages.renderTarget(240, 320)
            let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
            r.encode(image: image, transform: t, orientation: turn, into: commands, target: target)
            commands.commit()
            return try await TestImages.readTexture(target)
        }
        let light = CheckerColors.light
        let checker = try await frame(turned, orientation, light)
        let first = try await frame(turned, orientation, CheckerColors(light.first, light.first))
        let second = try await frame(turned, orientation, CheckerColors(light.second, light.second))
        let reference = try await frame(upright, .up, light)
        let unturned = try await frame(turned, .up, light)   // the picture is not symmetric: the turn is visible
        let back = Self.backdrop(t, TransparencySettings(mode: .checker, checkerSizePt: 8, colors: light), cell: 16)
        let white = Float(BackgroundColor(gray: 0xff).linear.red)
        var worstCell = 0, worstReference = 0, worstUnturned = 0, seconds = 0
        for y in 0..<320 {
            for x in 0..<240 where Self.inside(t, x, y) {
                let u = Self.pixel(unturned, width: 240, x, y), v = Self.pixel(reference, width: 240, x, y)
                worstUnturned = max(worstUnturned, abs(Int(u.r) - Int(v.r)), abs(Int(u.g) - Int(v.g)), abs(Int(u.b) - Int(v.b)))
                let isFirst = Float(back(x, y).0) == white
                if !isFirst { seconds += 1 }
                let p = Self.pixel(checker, width: 240, x, y), q = Self.pixel(isFirst ? first : second, width: 240, x, y)
                let r = Self.pixel(reference, width: 240, x, y)
                worstCell = max(worstCell, abs(Int(p.r) - Int(q.r)), abs(Int(p.g) - Int(q.g)), abs(Int(p.b) - Int(q.b)))
                worstReference = max(worstReference, abs(Int(p.r) - Int(r.r)), abs(Int(p.g) - Int(r.g)), abs(Int(p.b) - Int(r.b)))
            }
        }
        #expect(seconds > 1000 && worstUnturned > 20, "the check would pass without the turn: \(worstUnturned)")
        #expect(worstCell <= 2, "x\(scale): a cell differs from MetalFX over its colour by \(worstCell) levels")
        #expect(worstReference <= 2, "x\(scale): the frame differs from the pre-turned picture's by \(worstReference) levels")
    }

    @Test func metalFXSecondOutputLifetime() async throws {
        // The second checker output (~85 MB on 6K) exists only while MetalFX draws a photo with alpha over a checkerboard
        // of two colours: a solid backdrop, an equal-coloured checkerboard or an opaque photo lets it go, and so does
        // another path, with the stage.
        let alpha = try await TiledImage.make(from: TestImages.synthetic(128, 96, pixel: Self.softEdged))
        let opaque = try await TiledImage.make(from: TestImages.synthetic(128, 96))
        let t = Self.transform(128, 96, view: (320, 240), .actual(2.5), centre: (64, 48))
        let renderer = Self.renderer(Self.metalfx, .checker)
        let checker = renderer.transparency
        func draw(_ image: TiledImage) async throws { _ = try await Self.render(image, t, renderer: renderer) }
        try await draw(alpha)
        #expect(renderer.lastMode == .metalfx && renderer.holdsMetalFXSecondOutput)
        renderer.transparency = TransparencySettings(mode: .white)
        try await draw(alpha)
        #expect(renderer.lastMode == .metalfx && renderer.holdsMetalFX && !renderer.holdsMetalFXSecondOutput)
        renderer.transparency = TransparencySettings(mode: .checker, colors: CheckerColors(.default, .default))
        try await draw(alpha)
        #expect(!renderer.holdsMetalFXSecondOutput)
        renderer.transparency = checker
        try await draw(alpha)
        #expect(renderer.holdsMetalFXSecondOutput)
        try await draw(opaque)
        #expect(renderer.lastMode == .metalfx && renderer.holdsMetalFX && !renderer.holdsMetalFXSecondOutput)
        try await draw(alpha)
        #expect(renderer.holdsMetalFXSecondOutput)
        renderer.resample = Self.lanczos
        try await draw(alpha)
        #expect(!renderer.holdsMetalFX && !renderer.holdsMetalFXSecondOutput)
    }

    @Test func metalFXSecondOutputFailureIsStickyAndReported() async throws {
        // When the second checker output cannot be made, the frame draws Lanczos-3, the context is told (so the stats
        // line does not name MetalFX), and later frames at that size do not retry the allocation; a frame that MetalFX
        // does draw (an opaque photo) reports MetalFX again.
        let alpha = try await TiledImage.make(from: TestImages.synthetic(128, 96, pixel: Self.softEdged))
        let opaque = try await TiledImage.make(from: TestImages.synthetic(128, 96))
        let t = Self.transform(128, 96, view: (320, 240), .actual(2.5), centre: (64, 48))
        let renderer = Self.renderer(Self.metalfx, .checker)
        renderer.failMetalFXSecondOutput = true
        let frame = try await Self.render(alpha, t, renderer: renderer)
        #expect(renderer.lastMode == MetalContext.metalFXFallback && !renderer.holdsMetalFXSecondOutput)
        #expect(renderer.metalFXSecondFailedSize == SIMD2(320, 240) && renderer.lastMetalFXNote == false)
        #expect(MetalContext.drawnMode(.metalfx, supported: true, stageFailed: renderer.lastMetalFXNote == false)
                == MetalContext.metalFXFallback)
        let fallback = Self.renderer(ResampleSettings(upscale: .kernel(.lanczos3), upscaleHighPercent: 0,
                                                      pixelArtPercent: 0), .checker)
        #expect(frame == (try await Self.render(alpha, t, renderer: fallback)))
        renderer.failMetalFXSecondOutput = false
        _ = try await Self.render(alpha, t, renderer: renderer)
        #expect(renderer.lastMode == MetalContext.metalFXFallback && !renderer.holdsMetalFXSecondOutput)   // no retry
        _ = try await Self.render(opaque, t, renderer: renderer)
        #expect(renderer.lastMode == .metalfx && renderer.lastMetalFXNote == true)
        // The photo with alpha again at the same size: still the fallback, reported again, still no retry (the hook is
        // off, so a retry would succeed and hold the output).
        _ = try await Self.render(alpha, t, renderer: renderer)
        #expect(renderer.lastMode == MetalContext.metalFXFallback && renderer.lastMetalFXNote == false)
        #expect(!renderer.holdsMetalFXSecondOutput && renderer.metalFXSecondFailedSize == SIMD2(320, 240))
        // Checker -> solid -> checker at that size: MetalFX, then the fallback reported once more.
        renderer.transparency = TransparencySettings(mode: .white)
        _ = try await Self.render(alpha, t, renderer: renderer)
        #expect(renderer.lastMode == .metalfx && renderer.lastMetalFXNote == true)
        renderer.transparency = TransparencySettings(mode: .checker)
        _ = try await Self.render(alpha, t, renderer: renderer)
        #expect(renderer.lastMode == MetalContext.metalFXFallback && renderer.lastMetalFXNote == false)
        #expect(!renderer.holdsMetalFXSecondOutput)
        // A new view size makes the stage again, and with it the second output.
        let other = Self.transform(128, 96, view: (321, 241), .actual(2.5), centre: (64, 48))
        _ = try await Self.render(alpha, other, renderer: renderer)
        #expect(renderer.lastMode == .metalfx && renderer.holdsMetalFXSecondOutput && renderer.metalFXSecondFailedSize == nil)
    }

    @Test func checkerCellSizeAndAnchor() async throws {
        // checker-size 8 at backing scale 2: 16 px cells from the image's top-left corner on screen, white first; a
        // pan by 5 px moves them with the picture. The image is fully transparent and covers the view, so the frame is
        // the backdrop; a smaller one shows the background around it.
        let image = try await TiledImage.make(from: TestImages.synthetic(600, 400) { _, _ in (0, 0, 0, 0) })
        let renderer = Self.renderer(Self.lanczos, .checker)
        for (pan, centreX) in [(0, 300.0), (5, 295.0)] {
            let t = Self.transform(600, 400, view: (320, 200), .actual(1), centre: (centreX, 200))
            let origin = t.viewPoint(forImage: .zero)
            #expect(origin == CGPoint(x: -140 + pan, y: -100))
            let frame = try await Self.render(image, t, renderer: renderer)
            var wrong = 0
            for y in 0..<200 {
                for x in 0..<320 {
                    let cell = ((x + 140 - pan) / 16 + (y + 100) / 16) % 2
                    let expected: UInt8 = cell == 0 ? 0xff : 0xcc, p = Self.pixel(frame, width: 320, x, y)
                    if p.r != expected || p.g != expected || p.b != expected { wrong += 1 }
                }
            }
            #expect(wrong == 0, "pan \(pan): \(wrong) pixels off the checkerboard")
        }
        // Around a smaller picture, the background; the cells start at its corner. 8 pt at 1x are 8 px.
        let small = try await TiledImage.make(from: TestImages.synthetic(200, 120) { _, _ in (0, 0, 0, 0) })
        let t = Self.transform(200, 120, view: (320, 200), .actual(1), centre: (100, 60))
        #expect(t.viewPoint(forImage: .zero) == CGPoint(x: 60, y: 40))
        let oneX = try await Self.render(small, t, renderer: Self.renderer(Self.lanczos, .checker, scale: 1))
        let p = { (x: Int, y: Int) in Self.pixel(oneX, width: 320, x, y) }
        #expect(p(59, 40).r == 0x20 && p(59, 40).g == 0x60 && p(60, 39).b == 0xa0)
        #expect(p(60, 40).r == 0xff && p(67, 47).r == 0xff && p(68, 40).r == 0xcc && p(60, 48).r == 0xcc)
        #expect(p(68, 48).r == 0xff && p(259, 159).r == 0xff && p(260, 159).r == 0x20)
        // Turned (EXIF 6), the cells start at the corner of the picture as shown: 120 x 200, at (100, 0).
        let turned = Self.transform(120, 200, view: (320, 200), .actual(1), centre: (60, 100))
        let target = TestImages.renderTarget(320, 200)
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        Self.renderer(Self.lanczos, .checker).encode(image: small, transform: turned, orientation: .right,
                                                     into: commands, target: target)
        commands.commit()
        let r = try await TestImages.readTexture(target)
        let q = { (x: Int, y: Int) in Self.pixel(r, width: 320, x, y).r }
        #expect(q(99, 0) == 0x20 && q(100, 0) == 0xff && q(115, 15) == 0xff && q(116, 0) == 0xcc && q(100, 16) == 0xcc)
    }

    // MARK: Upload

    @Test func opaqueAlphaChannelUsesFastPath() async throws {
        // Review focus 3: a PNG whose alpha channel is all 255 has an alpha channel but no transparency, so the photo
        // keeps the ordinary pipelines (and its bytes); one pixel at 254 makes it a photo with alpha.
        func png(_ alpha: (Int, Int) -> CGFloat) throws -> DecodedImage {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            for y in 0..<48 {
                for x in 0..<64 {
                    context.setFillColor(CGColor(colorSpace: space, components: [CGFloat(x) / 63, CGFloat(y) / 47, 0.5,
                                                                                 alpha(x, y)])!)
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            try #require(CGImageDestinationFinalize(destination))
            return try ImageIODecoder.decodeFull(data as Data)
        }
        let opaque = try png { _, _ in 1 }
        #expect(opaque.hasAlphaChannel)
        let image = try await TiledImage.make(from: opaque)
        #expect(!image.hasAlpha)
        let renderer = Self.renderer(Self.lanczos, .checker)
        let t = Self.transform(64, 48, view: (100, 80), .actual(1), centre: (32, 24))
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(!renderer.lastHasAlpha && renderer.lastMode == .kernel(.lanczos3, upscale: false))
        // 100 % through Lanczos-3 is the source bytes.
        let base = opaque.buffer.bytes.assumingMemoryBound(to: UInt8.self)
        let p = Self.pixel(frame, width: 100, 18 + 10, 16 + 7), o = 7 * opaque.bytesPerRow + 10 * 4
        #expect(p.r == base[o + 2] && p.g == base[o + 1] && p.b == base[o])

        let translucent = try await TiledImage.make(from: try png { x, y in x == 63 && y == 47 ? 254.0 / 255 : 1 })
        #expect(translucent.hasAlpha)
        _ = try await Self.render(translucent, t, renderer: renderer)
        #expect(renderer.lastHasAlpha)
    }

    @Test func hasAlphaFromAnyUploadAndNoScanWithoutAChannel() async throws {
        // An opaque preview first, then a level 0 with transparency: the photo has alpha once that level is published.
        let grid = TileGrid(imageSize: PixelSize(width: 1200, height: 800))
        let image = TiledImage.empty(grid: grid, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let preview = grid.levelSize(1)
        try await image.upload(LevelImage(image: TestImages.synthetic(preview.width, preview.height), level: 1))
        #expect(!image.hasAlpha)
        let full = TestImages.synthetic(1200, 800) { x, y in x == 1199 && y == 799 ? (0, 0, 0, 0) : TestImages.pattern(x, y) }
        try await image.upload(LevelImage(image: full, level: 0))
        #expect(image.hasAlpha)
        // A decoder that reports no alpha channel is taken at its word: no scan, ordinary pipelines.
        let src = TestImages.synthetic(64, 64) { _, _ in (0, 0, 0, 0) }
        let declared = DecodedImage(pixelSize: src.pixelSize, bytesPerRow: src.bytesPerRow, buffer: src.buffer,
                                    colorSpace: src.colorSpace, hasAlphaChannel: false)
        #expect(!(try await TiledImage.make(from: declared)).hasAlpha)
    }

    @Test(arguments: [PyramidFilter.box, .lanczos3])
    func alphaPyramidIsPremultipliedLinear(filter: PyramidFilter) async throws {
        // Every pixel straight red at alpha 128 (bytes 128, 0, 0, 128): level 0 holds lin(1)·128/255 = 0.502 linear,
        // encoded 188, and so does level 1 (an average of equal pixels), alpha 128 throughout. Linearising the stored
        // byte would give lin(128/255) = 0.216, encoded 128.
        let image = try await TiledImage.make(from: TestImages.synthetic(600, 300) { _, _ in (0, 0, 128, 128) },
                                              filter: filter)
        for level in [0, 1] {
            let slice = try await TestImages.readSlice(image.levels[level], slice: 0)
            let p = TestImages.texel(slice, x: 8 + 20, y: 8 + 20)
            #expect(p.r == 188 && p.g == 0 && p.b == 0 && p.a == 128, "level \(level): \(p)")
        }
    }

    @Test func premultipliedLinearTable() {
        let table = MetalContext.premultipliedLinearTable()
        for s in 0..<256 { #expect(table[255 * 256 + s] == UInt8(s), "opaque \(s)") }
        for s in 0..<256 { #expect(table[s] == 0) }
        for (s, a) in [(128, 128), (1, 3), (60, 200), (200, 100)] {
            let straight = min(Double(s) / Double(a), 1)
            let expected = MetalContext.srgbEncode(MetalContext.srgbDecode(straight) * Double(a) / 255) * 255
            #expect(table[a * 256 + s] == UInt8(expected.rounded()), "s \(s) a \(a)")
        }
        #expect(table[128 * 256 + 128] == 188)
    }
}
