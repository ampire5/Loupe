import CoreGraphics
import Foundation
import ImageIO
import LoupeCore
import Metal
import QuartzCore
import Testing
import UniformTypeIdentifiers
@testable import LoupeRender

/// The photo's own transfer curve (M3b spec §4): a ProPhoto (pure γ 1.8) or Adobe RGB (γ 2.2) photo is filtered in its
/// profile's linear light and written back through the inverse table, against a CPU double reference in that light;
/// with alpha too; every path; the measured cost of the levels' 8-bit storage; sRGB photos bit-identical to before.
@Suite struct CurveRendererTests {
    private typealias Px = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

    private static let lanczos = ResampleSettings(upscale: .kernel(.lanczos3), upscaleHighPercent: 0,
                                                  downscale: .kernel(.lanczos3), antiringing: false, pixelArtPercent: 0)
    private static let ewa = ResampleSettings(upscale: .ewaLanczos, upscaleHighPercent: 0, pixelArtPercent: 0)
    private static let metalfx = ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0)
    private static let bilinear = ResampleSettings(upscale: .bilinear, downscale: .bilinear, pixelArtPercent: 0)
    private static let pixelArt = ResampleSettings(upscaleHighPercent: 0, pixelArtPercent: 400)

    private static let proPhoto = CGColorSpace(name: CGColorSpace.rommrgb)!
    private static let adobeRGB = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Around the picture: its bytes are the same whatever the photo's curve.
    private static let surround = BackgroundColor(red: 0x20, green: 0x60, blue: 0xa0)

    private static func renderer(_ settings: ResampleSettings, _ mode: TransparencyMode = .checker,
                                 background: BackgroundColor = surround) -> TileRenderer {
        let r = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
        r.resample = settings
        let c = background.linear
        r.background = MTLClearColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        r.transparency = TransparencySettings(mode: mode, checkerSizePt: 8, colors: .light, background: surround)
        r.backingScale = 2
        return r
    }

    private static func transform(_ width: Int, _ height: Int, view: (Int, Int) = (401, 263), _ mode: ZoomMode,
                                  centre: (Double, Double)) -> ViewTransform {
        ViewTransform(imageSize: CGSize(width: width, height: height), viewSize: CGSize(width: view.0, height: view.1),
                      mode: mode, center: CGPoint(x: centre.0 / Double(width), y: centre.1 / Double(height)))
    }

    private static func render(_ image: TiledImage, _ t: ViewTransform, _ orientation: ImageOrientation = .up,
                               renderer: TileRenderer) async throws -> [UInt8] {
        let target = TestImages.renderTarget(Int(t.viewSize.width), Int(t.viewSize.height))
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        renderer.encode(image: image, transform: t, orientation: orientation, into: commands, target: target)
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

    /// A pure gamma curve in double: code to linear light, and linear light to the nearest code.
    private static func decode(_ code: UInt8, gamma: Double) -> Double { pow(Double(code) / 255, gamma) }
    private static func encoder(gamma: Double) -> (Double) -> UInt8 {
        { UInt8((pow(min(max($0, 0), 1), 1 / gamma) * 255).rounded()) }
    }

    /// Gradients and hard edges, 37 x 29 px blocks: white, a ramp per channel (x, y and their sum), black, hashed noise
    /// and the ramps again, so the edges, the smooth ramps and the dark codes all reach the filters.
    private static func gradientAndEdges(_ x: Int, _ y: Int) -> Px {
        switch (x / 37 + y / 29) % 6 {
        case 0: return (255, 255, 255, 255)
        case 2: return (0, 0, 0, 255)
        case 3: return TestImages.noiseAndEdges(x * 7 + 3, y * 5 + 1)   // its noise, and its own (smaller) blocks
        default:
            return (UInt8((x + y) * 255 / 1159), UInt8(y * 255 / 459), UInt8(x * 255 / 699), 255)
        }
    }

    /// FNV-1a over a frame's bytes.
    private static func fnv(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0100_0000_01b3 }
    }

    // MARK: Against the reference

    @Test func proPhotoFitMatchesReference() async throws {
        // Fit (Lanczos-3 reducing, level 0) and x2.5 (Lanczos-3 and EWA Lanczos magnifying, with and without
        // antiringing) of a ProPhoto picture against the CPU reference in γ 1.8 linear light, written back with γ 1.8.
        let (width, height) = (700, 460)
        let image = try await TiledImage.make(from: TestImages.synthetic(width, height, colorSpace: Self.proPhoto,
                                                                         pixel: Self.gradientAndEdges))
        #expect(image.curve.map { $0 != .srgb } == true)
        let source = { (x: Int, y: Int) -> (Double, Double, Double) in
            let p = Self.gradientAndEdges(x, y)
            return (Self.decode(p.r, gamma: 1.8), Self.decode(p.g, gamma: 1.8), Self.decode(p.b, gamma: 1.8))
        }
        var antiring = Self.lanczos, ewaAntiring = Self.ewa
        antiring.antiringing = true
        ewaAntiring.antiringing = true
        let cases: [(String, ResampleSettings, ZoomMode, ResampleMode)] = [
            ("lanczos3 Fit", Self.lanczos, .fit, .kernel(.lanczos3, upscale: false)),
            ("lanczos3 x2.5", Self.lanczos, .actual(2.5), .kernel(.lanczos3, upscale: true)),
            ("lanczos3 x2.5, antiringing", antiring, .actual(2.5), .kernel(.lanczos3, upscale: true)),
            ("ewa x2.5", Self.ewa, .actual(2.5), .ewaLanczos),
            ("ewa x2.5, antiringing", ewaAntiring, .actual(2.5), .ewaLanczos),
        ]
        for (name, settings, mode, drawn) in cases {
            let t = Self.transform(width, height, mode, centre: (430.37, 290.71))
            let renderer = Self.renderer(settings)
            let frame = try await Self.render(image, t, renderer: renderer)
            #expect(renderer.lastCurveTable && renderer.lastMode == drawn && renderer.lastLevel == 0, "\(name)")
            let origin = t.viewPoint(forImage: .zero), f = { (v: Double) in Double(Float(v)) }
            let m = f(t.scale), offset = SIMD2(f(origin.x), f(origin.y))
            let extent = SIMD2(Double(width), Double(height))
            let c = Self.surround.linear, outside = (c.red, c.green, c.blue)
            let w = Int(t.viewSize.width), h = Int(t.viewSize.height)
            let expected = name.hasPrefix("ewa")
                ? ResampleReference.renderEWA(source: source, width: width, height: height, m: m, offset: offset,
                                              extent: extent, viewWidth: w, viewHeight: h, background: outside,
                                              antiringing: settings.antiringing, curve: Self.encoder(gamma: 1.8))
                : ResampleReference.render(source: source, width: width, height: height, kernel: .lanczos3, m: m,
                                           offset: offset, extent: extent, viewWidth: w, viewHeight: h,
                                           background: outside, antiringing: settings.antiringing,
                                           curve: Self.encoder(gamma: 1.8))
            let psnr = ResampleReference.psnr(frame, expected, width: w)
            print("PSNR ProPhoto \(name): \(psnr) dB")
            #expect(psnr >= 50, "\(name): \(psnr) dB")
        }
    }

    /// A PNG of `width` x `height` in `space` whose straight colour and alpha are `pixel(x, y)` (r, g, b, a), decoded by
    /// ImageIO as the app decodes one.
    private static func png(_ width: Int, _ height: Int, space: CGColorSpace,
                            pixel: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) throws -> DecodedImage {
        let info = CGImageAlphaInfo.last.rawValue
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixel(x, y), o = (y * width + x) * 4
                bytes[o] = p.r; bytes[o + 1] = p.g; bytes[o + 2] = p.b; bytes[o + 3] = p.a
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return try ImageIODecoder.decodeFull(data as Data)
    }

    /// Noise colours under a disc feathered over 12 px and a band whose alpha ramps left to right; transparent elsewhere.
    private static func softDisc(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let d = hypot(Double(x) - 350.5, Double(y) - 230.5)
        var a = min(max((160 - d) / 12 + 0.5, 0), 1)
        if (400..<440).contains(y) { a = max(a, Double(x) / 699) }
        let n = Self.gradientAndEdges(x, y)
        return (n.r, n.g, n.b, UInt8((a * 255).rounded()))
    }

    @Test(arguments: [TransparencyMode.checker, .white])
    func alphaAndCurveTogether(mode: TransparencyMode) async throws {
        // A ProPhoto PNG with alpha: each decoded texel is premultiplied in γ 1.8 linear light, `lin(s / a) · a`,
        // filtered, composited over the backdrop (its bytes in the photo's space, so linearised with γ 1.8 too) and
        // written with γ 1.8; Lanczos-3 both ways and EWA, against the CPU reference.
        let (width, height) = (700, 460)
        let decoded = try Self.png(width, height, space: Self.proPhoto, pixel: Self.softDisc)
        #expect(ColorCurve.of(decoded.colorSpace) != .srgb && decoded.hasAlphaChannel)
        let image = try await TiledImage.make(from: decoded)
        #expect(image.hasAlpha && image.curve.map { $0 != .srgb } == true)
        let base = decoded.buffer.bytes.assumingMemoryBound(to: UInt8.self), stride = decoded.bytesPerRow
        func texel(_ x: Int, _ y: Int) -> (rgb: (Double, Double, Double), a: Double) {
            let o = y * stride + x * 4, a = base[o + 3]
            guard a > 0 else { return ((0, 0, 0), 0) }
            func lin(_ s: UInt8) -> Double { pow(min(Double(s) / Double(a), 1), 1.8) * Double(a) / 255 }
            return ((lin(base[o + 2]), lin(base[o + 1]), lin(base[o])), Double(a) / 255)
        }
        for (name, settings, scale) in [("lanczos3 down", Self.lanczos, 0.6), ("lanczos3 up", Self.lanczos, 2.5),
                                        ("ewa", Self.ewa, 2.5)] {
            let t = Self.transform(width, height, .actual(scale), centre: (430.37, 290.71))
            let renderer = Self.renderer(settings, mode)
            let frame = try await Self.render(image, t, renderer: renderer)
            #expect(renderer.lastHasAlpha && renderer.lastCurveTable && renderer.lastLevel == 0, "\(name)")
            let origin = t.viewPoint(forImage: .zero), f = { (v: Double) in Double(Float(v)) }
            let m = f(t.scale), offset = SIMD2(f(origin.x), f(origin.y))
            let ox = Float(origin.x), oy = Float(origin.y)
            // The cells as the renderer counts them (16 px from the image's view origin), in γ 1.8 linear light.
            let cells = CheckerColors.light
            let colours = mode == .white ? (1.0, 1.0)
                                         : (Self.decode(cells.first.red, gamma: 1.8), Self.decode(cells.second.red, gamma: 1.8))
            let back = { (x: Int, y: Int) -> (Double, Double, Double) in
                let cx = ((Float(x) + 0.5 - ox) / 16).rounded(.down), cy = ((Float(y) + 0.5 - oy) / 16).rounded(.down)
                let v = Int(cx + cy) & 1 == 0 ? colours.0 : colours.1
                return (v, v, v)
            }
            let c = Self.surround.linear, outside = (c.red, c.green, c.blue)
            let w = Int(t.viewSize.width), h = Int(t.viewSize.height)
            let extent = SIMD2(Double(width), Double(height))
            let expected = name == "ewa"
                ? ResampleReference.renderEWAComposite(source: { texel($0, $1).rgb }, alpha: { texel($0, $1).a },
                                                       width: width, height: height, m: m, offset: offset,
                                                       extent: extent, viewWidth: w, viewHeight: h, background: outside,
                                                       backdrop: back, curve: Self.encoder(gamma: 1.8))
                : ResampleReference.renderComposite(source: { texel($0, $1).rgb }, alpha: { texel($0, $1).a },
                                                    width: width, height: height, kernel: .lanczos3, m: m,
                                                    offset: offset, extent: extent, viewWidth: w, viewHeight: h,
                                                    background: outside, backdrop: back,
                                                    curve: Self.encoder(gamma: 1.8))
            let psnr = ResampleReference.psnr(frame, expected, width: w)
            print("PSNR ProPhoto with alpha over \(mode), \(name): \(psnr) dB")
            #expect(psnr >= 50, "\(mode) \(name): \(psnr) dB")
        }
    }

    // MARK: Every path

    @Test(arguments: [false, true])
    func tablePathsDrawWhatSRGBDrawsOfTheSameLight(turned: Bool) async throws {
        // Every path of a ProPhoto photo against the same path of an sRGB one holding the same light (each code as the
        // sRGB byte of its γ 1.8 light, which is what the upload stores for it), read back in γ 1.8: the paths sum the
        // same texels, so only the last encode differs, the inverse table against the sRGB byte converted on the CPU.
        // MetalFX included, which no reference can check. Turned (EXIF 6), the stored picture is the upright one
        // turned back, so the frames are the same.
        let stored = turned ? PixelSize(width: 460, height: 700) : PixelSize(width: 700, height: 460)
        let orientation: ImageOrientation = turned ? .right : .up
        let storedSize = CGSize(width: stored.width, height: stored.height)
        let upright = { (x: Int, y: Int) -> Px in
            guard turned else { return Self.gradientAndEdges(x, y) }
            let p = orientation.orientedPoint(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), storedSize: storedSize)
            return Self.gradientAndEdges(Int(p.x), Int(p.y))
        }
        func srgbByte(_ code: UInt8) -> UInt8 { ResampleReference.encode(Self.decode(code, gamma: 1.8)) }
        let table = try await TiledImage.make(from: TestImages.synthetic(stored.width, stored.height,
                                                                         colorSpace: Self.proPhoto, pixel: upright))
        let same = try await TiledImage.make(from: TestImages.synthetic(stored.width, stored.height) { x, y in
            let p = upright(x, y)
            return (srgbByte(p.b), srgbByte(p.g), srgbByte(p.r), 255)
        })
        let toProPhoto = (0..<256).map { Self.encoder(gamma: 1.8)(ResampleReference.linear(UInt8($0))) }
        let cases: [(String, ResampleSettings, Double, ResampleMode)] = [
            ("bilinear", Self.bilinear, 0.66, .bilinear),
            ("lanczos3 down", Self.lanczos, 0.66, .kernel(.lanczos3, upscale: false)),
            ("lanczos3 up", Self.lanczos, 2.5, .kernel(.lanczos3, upscale: true)),
            ("nearest", Self.pixelArt, 4, .nearest), ("ewa", Self.ewa, 2.5, .ewaLanczos),
            ("metalfx", Self.metalfx, 2.5, .metalfx),
        ]
        for (name, settings, scale, mode) in cases {
            let t = Self.transform(700, 460, .actual(scale), centre: (430.37, 290.71))
            let r = Self.renderer(settings)
            let frame = try await Self.render(table, t, orientation, renderer: r)
            #expect(r.lastCurveTable && r.lastMode == mode, "\(name)")
            let s = Self.renderer(settings)
            var expected = try await Self.render(same, t, orientation, renderer: s)
            #expect(!s.lastCurveTable)
            var worst = 0
            for y in 0..<263 {
                for x in 0..<401 where Self.inside(t, x, y) {
                    let o = (y * 401 + x) * 4
                    for ch in 0..<3 {
                        expected[o + ch] = toProPhoto[Int(expected[o + ch])]
                        worst = max(worst, abs(Int(frame[o + ch]) - Int(expected[o + ch])))
                    }
                }
            }
            let psnr = ResampleReference.psnr(frame, expected, width: 401)
            print("ProPhoto \(name)\(turned ? " turned" : ""): \(psnr) dB against sRGB of the same light, worst \(worst)")
            // Outside the picture both are the background's bytes; inside, the sRGB byte's own rounding (its steps are
            // up to 1.3 ProPhoto codes wide in the highlights) is all that differs.
            #expect(psnr >= 50 && worst <= 2, "\(name): \(psnr) dB, worst \(worst)")
        }
    }

    @Test func checkerKeepsItsBytesOverATablePhoto() async throws {
        // A fully transparent ProPhoto photo shows only the backdrop: its cells are their bytes, #FFFFFF and #CCCCCC, in
        // every path, and the background around the picture is its own bytes too. A backdrop linearised with the sRGB
        // curve and written with γ 1.8 would come out at 0xC1 instead of 0xCC. MetalFX passes the light through its 8-bit
        // sRGB input and output as well, which may move a cell by one (0xCC's light lies half way between two sRGB bytes).
        let image = try await TiledImage.make(from: TestImages.synthetic(200, 120, colorSpace: Self.proPhoto) { _, _ in
            (0, 0, 0, 0)
        })
        let paths: [(String, ResampleSettings, Double)] = [
            ("bilinear", Self.bilinear, 0.8), ("lanczos3 down", Self.lanczos, 0.8), ("lanczos3 up", Self.lanczos, 1.5),
            ("nearest", Self.pixelArt, 4), ("ewa", Self.ewa, 1.5), ("metalfx", Self.metalfx, 1.5),
        ]
        for (name, settings, scale) in paths {
            let t = Self.transform(200, 120, view: (320, 200), .actual(scale), centre: (100, 60))
            let renderer = Self.renderer(settings)
            let frame = try await Self.render(image, t, renderer: renderer)
            #expect(renderer.lastHasAlpha && renderer.lastCurveTable, "\(name)")
            let origin = t.viewPoint(forImage: .zero)
            var wrong = 0
            for y in 0..<200 {
                for x in 0..<320 {
                    let p = Self.pixel(frame, width: 320, x, y)
                    let expected: (UInt8, UInt8, UInt8)
                    if Self.inside(t, x, y) {
                        let cx = ((Float(x) + 0.5 - Float(origin.x)) / 16).rounded(.down)
                        let cy = ((Float(y) + 0.5 - Float(origin.y)) / 16).rounded(.down)
                        let v: UInt8 = Int(cx + cy) & 1 == 0 ? 0xff : 0xcc
                        expected = (v, v, v)
                    } else {
                        expected = (0x20, 0x60, 0xa0)
                    }
                    let tolerance = name == "metalfx" && Self.inside(t, x, y) ? 1 : 0
                    if abs(Int(p.r) - Int(expected.0)) > tolerance || abs(Int(p.g) - Int(expected.1)) > tolerance
                        || abs(Int(p.b) - Int(expected.2)) > tolerance { wrong += 1 }
                }
            }
            #expect(wrong == 0, "\(name): \(wrong) pixels off")
        }
    }

    @Test(arguments: [PyramidFilter.box, .lanczos3])
    func pyramidAveragesTheProfilesLight(filter: PyramidFilter) async throws {
        // A 1 px checkerboard of ProPhoto codes 0 and 255 averages to half the light: level 1 holds it as the sRGB byte
        // of 0.5 (188), and a frame drawn from that level shows ProPhoto's code of 0.5, 255 · 0.5^(1 / 1.8) = 174.5 (the
        // sRGB curve would show 188).
        let image = try await TiledImage.make(from: TestImages.synthetic(1024, 512, colorSpace: Self.proPhoto) { x, y in
            let v: UInt8 = (x + y) & 1 == 0 ? 0 : 255
            return (v, v, v, 255)
        }, filter: filter)
        let slice = try await TestImages.readSlice(image.levels[1], slice: 0)
        let texel = TestImages.texel(slice, x: 8 + 100, y: 8 + 100)
        #expect(texel.r == 188 && texel.g == 188 && texel.b == 188, "\(filter): \(texel)")
        let t = Self.transform(1024, 512, view: (200, 100), .actual(0.4), centre: (512, 256))
        let renderer = Self.renderer(Self.lanczos)
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastLevel == 1 && renderer.lastCurveTable)
        let p = Self.pixel(frame, width: 200, 100, 50)
        #expect([174, 175].contains(p.r) && p.r == p.g && p.g == p.b, "\(filter): \(p)")
    }

    @Test func metalFXFallbackKeepsTheCurve() async throws {
        // A ProPhoto photo with alpha over the checkerboard whose second MetalFX output cannot be made: the frame is the
        // Lanczos-3 fallback's, reported as such, in the photo's light (the same bytes as a Lanczos-3 renderer draws).
        let image = try await TiledImage.make(from: try Self.png(700, 460, space: Self.proPhoto, pixel: Self.softDisc))
        let t = Self.transform(700, 460, .actual(2.5), centre: (430.37, 290.71))
        let renderer = Self.renderer(Self.metalfx)
        renderer.failMetalFXSecondOutput = true
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == MetalContext.metalFXFallback && renderer.lastCurveTable && renderer.lastHasAlpha)
        let lanczos = Self.renderer(ResampleSettings(upscale: .kernel(.lanczos3), upscaleHighPercent: 0, pixelArtPercent: 0))
        #expect(frame == (try await Self.render(image, t, renderer: lanczos)))
        #expect(lanczos.lastCurveTable)
    }

    @Test func previewThenFullThenEvictionKeepTheCurve() async throws {
        // The curve is resolved by the first upload, a preview (level 1) here: its frame takes the table path. Level 0
        // then, evicted and uploaded again: the same frames as before the eviction, at 100 % and from level 1.
        let grid = TileGrid(imageSize: PixelSize(width: 1300, height: 900))
        let full = TestImages.synthetic(1300, 900, colorSpace: Self.proPhoto) { Self.gradientAndEdges($0 % 700, $1 % 460) }
        let image = TiledImage.empty(grid: grid, colorSpace: Self.proPhoto)
        let size = grid.levelSize(1)
        try await image.upload(LevelImage(image: TestImages.synthetic(size.width, size.height, colorSpace: Self.proPhoto) {
            Self.gradientAndEdges($0 % 350, $1 % 230)
        }, level: 1))
        #expect(image.curve.map { $0 != .srgb } == true)
        let actual = Self.transform(1300, 900, .actual(1), centre: (512.37, 450.71))
        let reduced = Self.transform(1300, 900, .actual(0.4), centre: (512.37, 450.71))
        func draw(_ t: ViewTransform, level: Int) async throws -> [UInt8] {
            let r = Self.renderer(Self.lanczos)
            let frame = try await Self.render(image, t, renderer: r)
            #expect(r.lastCurveTable && r.lastLevel == level)
            return frame
        }
        _ = try await draw(reduced, level: 1)
        try await image.upload(LevelImage(image: full, level: 0))
        let before = (try await draw(actual, level: 0), try await draw(reduced, level: 1))
        image.evict(finerThan: 1)
        try await image.upload(LevelImage(image: full, level: 0))
        #expect(try await draw(actual, level: 0) == before.0)
        #expect(try await draw(reduced, level: 1) == before.1)
    }

    @Test func drawsIntoALayersDrawable() async throws {
        // The app's target: a CAMetalLayer drawable (bgra8Unorm_srgb, not framebufferOnly, no .pixelFormatView usage),
        // whose bgra8Unorm view the table frame writes. Same bytes as into a private texture of that format.
        let image = try await TiledImage.make(from: TestImages.synthetic(700, 460, colorSpace: Self.proPhoto,
                                                                         pixel: Self.gradientAndEdges))
        let layer = CAMetalLayer()
        layer.device = MetalContext.shared.device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 401, height: 263)
        let drawable = try #require(layer.nextDrawable())
        let t = Self.transform(700, 460, .actual(1.37), centre: (430.37, 290.71))
        let renderer = Self.renderer(Self.lanczos)
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        renderer.encode(image: image, transform: t, into: commands, target: drawable.texture)
        commands.commit()
        #expect(renderer.lastCurveTable)
        let frame = try await TestImages.readTexture(drawable.texture)
        #expect(frame == (try await Self.render(image, t, renderer: Self.renderer(Self.lanczos))))
    }

    // MARK: Precision of the levels

    @Test(arguments: [(CGColorSpace.adobeRGB1998 as String, 2.2), (CGColorSpace.rommrgb as String, 1.8)])
    func codesAt100PercentKeepTheMeasuredStorageError(name: String, gamma: Double) async throws {
        // The cost of the levels' storage (Shaders.source, «Colour»): each code is stored as the sRGB byte of its linear
        // light, so at 100 % (Lanczos-3 at m = 1 returns the texel) a code comes back as the code of that byte's light.
        // Where the sRGB byte is coarser than the profile's step, codes merge: γ 2.2's darkest (code 1 is 5e-6 linear,
        // a 60th of the first sRGB byte's 3e-4, so codes 1-4 come back 0) and a few of γ 1.8's (one code). The frame
        // is that model (from the curve's own tables) within one code: the row buffer's half floats and the curve's
        // rounding at a code's edge (10 and 14 codes of 256 measured).
        let space = try #require(CGColorSpace(name: name as CFString))
        let curve = ColorCurve.of(space)
        let image = try await TiledImage.make(from: TestImages.synthetic(256, 64, colorSpace: space) { x, _ in
            (UInt8(x), UInt8(x), UInt8(x), 255)
        })
        let t = Self.transform(256, 64, view: (256, 64), .actual(1), centre: (128, 32))
        let renderer = Self.renderer(Self.lanczos)
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastCurveTable && renderer.lastMode == .kernel(.lanczos3, upscale: false))
        var off: [Int: Int] = [:], fromModel = 0, darkLight = 0.0
        for code in 0..<256 {
            let p = Self.pixel(frame, width: 256, code, 32)
            #expect(p.r == p.g && p.g == p.b)
            let stored = ResampleReference.encode(Double(curve.decode(Float(code) / 255)))
            let model = Int((curve.encode(Float(ResampleReference.linear(stored))) * 255).rounded())
            #expect(abs(Int(p.r) - model) <= 1, "code \(code): \(p.r), the model \(model)")
            if Int(p.r) != model { fromModel += 1 }
            off[Int(p.r) - code, default: 0] += 1
            #expect(abs(Int(p.r) - code) <= (code < 16 && gamma > 2 ? 4 : 1), "code \(code) came back \(p.r)")
            if code < 16 { darkLight = max(darkLight, abs(pow(Double(p.r) / 255, gamma) - pow(Double(code) / 255, gamma))) }
        }
        print("\(name) at 100 %: codes off by \(off.sorted { $0.key < $1.key }), \(fromModel) a code from the model; "
              + "codes 0-15 at most \(darkLight) linear off")
    }

    // MARK: Tables

    @Test func curveTablesAreSharedMadeOnDemandAndBounded() throws {
        // One set of tables per curve, shared; the sRGB curve has no inverse table (its frames are the _srgb drawable's),
        // and its upload table, made on first use, is the one Task 4 built at launch. At most `curveTableLimit` curves
        // stay cached: the oldest is made again after that.
        let c = MetalContext.shared
        let adobe = ColorCurve.of(Self.adobeRGB)
        let tables = try #require(c.curveTables(for: adobe))
        #expect(c.curveTables(for: adobe) === tables && tables.inverse?.width == ColorCurve.inverseCount)
        let srgb = try #require(c.curveTables(for: .srgb))
        #expect(srgb.inverse == nil)
        let upload = try #require(srgb.upload())
        #expect(srgb.upload() === upload)
        let bytes = UnsafeBufferPointer(start: upload.contents().assumingMemoryBound(to: UInt8.self), count: upload.length)
        #expect(Array(bytes) == MetalContext.premultipliedLinearTable())
        guard case .table(let forward, let inverse) = adobe else { throw CancellationError() }
        let first = ColorCurve.table(forward: forward.map { $0 * 0.5 }, inverse: inverse)
        let made = try #require(c.curveTables(for: first))
        for i in 1...MetalContext.curveTableLimit {
            _ = c.curveTables(for: .table(forward: forward.map { $0 * (0.5 + Float(i) / 64) }, inverse: inverse))
        }
        #expect(c.curveTables(for: first) !== made)
    }

    // MARK: sRGB unchanged

    /// `space`'s ICC profile made unnamed: CoreGraphics names a profile it recognises (the system sRGB and P3 come back
    /// as `kCGColorSpaceSRGB` / `DisplayP3` from their own data), so the profile ID (bytes 84-99) is cleared and the
    /// CMM type (byte 4) changed; the curves stay.
    private static func unnamed(_ space: CGColorSpace) throws -> CGColorSpace {
        let data = NSMutableData(data: try #require(space.copyICCData()) as Data)
        let bytes = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        for i in 84..<100 { bytes[i] = 0 }
        bytes[4] ^= 0x20
        let made = try #require(CGColorSpace(iccData: data as CFData))
        #expect(made.name == nil)
        #expect(ColorCurve.of(made) == .srgb)
        return made
    }

    @Test func srgbImagesUnchanged() async throws {
        // Photos whose curve is sRGB (named sRGB and Display P3, and both as unnamed ICC profiles, which `ColorCurve.of`
        // compares within its tolerance) draw the bytes they drew before the table path existed, on every path, with
        // and without alpha: hashes recorded at 45ccc76 on this
        // Mac (Apple M4 Max; the opaque ones are `orientationUpIsUnchanged`'s, recorded at 260f466). Re-record them from
        // that commit on another GPU or macOS.
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let spaces = [Self.srgb, p3, try Self.unnamed(Self.srgb), try Self.unnamed(p3)]
        let lanczosAntiring = ResampleSettings(upscale: .kernel(.lanczos3), upscaleHighPercent: 0, antiringing: true,
                                               pixelArtPercent: 0)
        let magenta = BackgroundColor(red: 0xff, green: 0, blue: 0xff)
        let opaque: [(String, ResampleSettings, Double, UInt64)] = [
            ("bilinear", Self.bilinear, 0.66, 0xf9fa_8747_8226_8081),
            ("lanczos3 down", Self.lanczos, 0.66, 0xfada_ef82_ddd8_c2df),
            ("lanczos3 down, level 1", Self.lanczos, 0.37, 0xdc97_12fc_9223_5cc2),
            ("lanczos3 up", Self.lanczos, 2.5, 0x91e3_990d_b070_5f31),
            ("lanczos3 up, antiringing", lanczosAntiring, 2.5, 0xbbb0_b6ea_6397_1f83),
            ("nearest", Self.pixelArt, 4, 0x0d1e_62d7_8c10_ee80),
            ("ewa-lanczos", Self.ewa, 2.5, 0x47e1_6844_7388_4283),
            ("metalfx", Self.metalfx, 2.5, 0x78ac_bcd3_4e56_4bc2),
        ]
        // The soft disc over the checkerboard (MetalFX: two runs) and over white (one run).
        let alpha: [(String, ResampleSettings, Double, TransparencyMode, UInt64)] = [
            ("bilinear", Self.bilinear, 0.66, .checker, 0x68de_18c1_0775_e8d5),
            ("lanczos3 down", Self.lanczos, 0.66, .checker, 0x8052_aa0b_2407_6fad),
            ("lanczos3 down, level 1", Self.lanczos, 0.37, .checker, 0x5880_882a_e234_aae1),
            ("lanczos3 up", Self.lanczos, 2.5, .checker, 0x5cbf_5191_8071_eb54),
            ("nearest", Self.pixelArt, 4, .checker, 0x2deb_a975_6ddc_23e4),
            ("ewa-lanczos", Self.ewa, 2.5, .checker, 0xd241_8f70_f7fc_87ee),
            ("metalfx", Self.metalfx, 2.5, .checker, 0xeb4c_6328_1a61_98cf),
            ("metalfx over white", Self.metalfx, 2.5, .white, 0x6068_98ed_8dc1_66fb),
        ]
        for space in spaces {
            let image = try await TiledImage.make(from: TestImages.synthetic(1300, 900, colorSpace: space,
                                                                             pixel: TestImages.noiseAndEdges))
            #expect(image.curve == .srgb)
            for (name, settings, scale, hash) in opaque {
                let t = Self.transform(1300, 900, view: (641, 403), .actual(scale), centre: (512.37, 450.71))
                let r = Self.renderer(settings, background: magenta)
                let frame = try await Self.render(image, t, renderer: r)
                #expect(!r.lastCurveTable && !r.lastHasAlpha)
                let label = "\(space.name ?? "ICC" as CFString) \(name)"
                #expect(Self.fnv(frame) == hash, "\(label): 0x\(String(Self.fnv(frame), radix: 16))")
            }
            let soft = try await TiledImage.make(from: TestImages.synthetic(1300, 900, colorSpace: space) { x, y in
                let p = Self.softDisc(x / 2, y / 2)
                func premultiplied(_ c: UInt8) -> UInt8 { UInt8((Double(c) * Double(p.a) / 255).rounded()) }
                return (premultiplied(p.b), premultiplied(p.g), premultiplied(p.r), p.a)
            })
            #expect(soft.hasAlpha && soft.curve == .srgb)
            for (name, settings, scale, mode, hash) in alpha {
                let t = Self.transform(1300, 900, view: (641, 403), .actual(scale), centre: (512.37, 450.71))
                let r = Self.renderer(settings, mode, background: magenta)
                let frame = try await Self.render(soft, t, renderer: r)
                #expect(!r.lastCurveTable && r.lastHasAlpha)
                let label = "\(space.name ?? "ICC" as CFString) alpha \(name)"
                #expect(Self.fnv(frame) == hash, "\(label): 0x\(String(Self.fnv(frame), radix: 16))")
            }
        }
    }
}
