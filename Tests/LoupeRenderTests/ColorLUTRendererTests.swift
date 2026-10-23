import CoreGraphics
import Foundation
import LoupeCore
import Metal
import simd
import Testing
@testable import LoupeRender

/// The photo's colour cube (M3c spec §5): the `COLOR_LUT` variant of every output path samples it after the filter and
/// before the backdrop, against a CPU trilinear reference over the cube's own half floats; the identity cube changes
/// nothing; transparent pixels and the backdrop stay as they were; a `.table` curve; the transition's `mix`; frames
/// without a cube keep the pipelines and bytes of before.
@Suite struct ColorLUTRendererTests {
    private typealias Px = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

    private static let lanczos = ResampleSettings(upscale: .kernel(.lanczos3), upscaleHighPercent: 0,
                                                  downscale: .kernel(.lanczos3), antiringing: false, pixelArtPercent: 0)
    private static let ewa = ResampleSettings(upscale: .ewaLanczos, upscaleHighPercent: 0, pixelArtPercent: 0)
    private static let metalfx = ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0)
    private static let bilinear = ResampleSettings(upscale: .bilinear, downscale: .bilinear, pixelArtPercent: 0)
    private static let pixelArt = ResampleSettings(upscaleHighPercent: 0, pixelArtPercent: 400)

    /// Every output path once, at a scale that takes it (MetalFX only where the GPU has the scaler).
    private static let paths: [(String, ResampleSettings, Double, ResampleMode)] = [
        ("bilinear", bilinear, 0.66, .bilinear),
        ("nearest", pixelArt, 4, .nearest),
        ("lanczos3 down", lanczos, 0.66, .kernel(.lanczos3, upscale: false)),
        ("lanczos3 up", lanczos, 2.5, .kernel(.lanczos3, upscale: true)),
        ("ewa", ewa, 2.5, .ewaLanczos),
    ] + (MetalContext.shared.supportsMetalFX ? [("metalfx", metalfx, 2.5, .metalfx)] : [])

    /// Around the picture.
    private static let surround = BackgroundColor(red: 0x20, green: 0x60, blue: 0xa0)

    private static func renderer(_ settings: ResampleSettings, _ mode: TransparencyMode = .checker,
                                 color: ColorFrame? = nil, background: BackgroundColor = surround) -> TileRenderer {
        let r = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
        r.resample = settings
        let c = background.linear
        r.background = MTLClearColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        r.transparency = TransparencySettings(mode: mode, checkerSizePt: 8, colors: .light, background: surround)
        r.backingScale = 2
        r.color = color
        return r
    }

    private static func transform(_ width: Int, _ height: Int, view: (Int, Int) = (401, 263), _ mode: ZoomMode,
                                  centre: (Double, Double)) -> ViewTransform {
        ViewTransform(imageSize: CGSize(width: width, height: height), viewSize: CGSize(width: view.0, height: view.1),
                      mode: mode, center: CGPoint(x: centre.0 / Double(width), y: centre.1 / Double(height)))
    }

    /// 100 % with the image's px on whole view px (origin (-150, -100)): Lanczos-3 returns each texel as it is, so the
    /// frame is the picture's own pixels and the reference needs no filter.
    private static let actual = transform(700, 460, view: (400, 260), .actual(1), centre: (350, 230))

    private static func render(_ image: TiledImage, _ t: ViewTransform, renderer: TileRenderer) async throws -> [UInt8] {
        let target = TestImages.renderTarget(Int(t.viewSize.width), Int(t.viewSize.height))
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        renderer.encode(image: image, transform: t, into: commands, target: target)
        commands.commit()
        return try await TestImages.readTexture(target)
    }

    /// Whether the centre of view pixel (x, y) lies inside the image's view rect.
    private static func inside(_ t: ViewTransform, _ x: Int, _ y: Int) -> Bool {
        let a = t.viewPoint(forImage: .zero), b = t.viewPoint(forImage: CGPoint(x: t.imageSize.width, y: t.imageSize.height))
        let cx = Double(x) + 0.5, cy = Double(y) + 0.5
        return cx >= a.x && cx < b.x && cy >= a.y && cy < b.y
    }

    /// The image position under the centre of view pixel (x, y).
    private static func imagePoint(_ t: ViewTransform, _ x: Int, _ y: Int) -> (Double, Double) {
        let p = t.imagePoint(forView: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
        return (p.x, p.y)
    }

    /// FNV-1a over a frame's bytes.
    private static func fnv(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0100_0000_01b3 }
    }

    // MARK: The cube and its CPU lookup

    /// A cube far from the identity: the channels rotate and each gets its own curve on the encoded values,
    /// r' = g^1.3, g' = b, b' = 0.15 + 0.7·r (slope ≤ 1.3, so a code of input moves the output by ~1 code at most).
    private static let testCube: ColorCube = {
        let n = ColorCube.dimension, last = Double(n - 1)
        var values = [Half](repeating: 1, count: n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = ((b * n + g) * n + r) * 4
                    values[i] = Half(pow(Double(g) / last, 1.3))
                    values[i + 1] = Half(Double(b) / last)
                    values[i + 2] = Half(0.15 + 0.7 * Double(r) / last)
                }
            }
        }
        return ColorCube(values: values)
    }()

    /// The cube applied on the CPU as the shader applies it: encoded input `e` (clamped to 0...1) looked up
    /// trilinearly at `e · (n − 1)` among the stored half floats, the result decoded to linear light.
    private static func apply(_ cube: ColorCube, _ e: SIMD3<Double>) -> SIMD3<Double> {
        let n = ColorCube.dimension
        let x = simd_clamp(e, SIMD3(repeating: 0), SIMD3(repeating: 1)) * Double(n - 1)
        let i0 = SIMD3<Int>(min(Int(x.x), n - 2), min(Int(x.y), n - 2), min(Int(x.z), n - 2))
        let f = x - SIMD3(Double(i0.x), Double(i0.y), Double(i0.z))
        var out = SIMD3<Double>(repeating: 0)
        for corner in 0..<8 {
            let d = SIMD3(corner & 1, (corner >> 1) & 1, corner >> 2)
            let w = (d.x == 1 ? f.x : 1 - f.x) * (d.y == 1 ? f.y : 1 - f.y) * (d.z == 1 ? f.z : 1 - f.z)
            let node = (((i0.z + d.z) * n + i0.y + d.y) * n + i0.x + d.x) * 4
            out += w * SIMD3(Double(cube.values[node]), Double(cube.values[node + 1]), Double(cube.values[node + 2]))
        }
        return SIMD3(MetalContext.srgbDecode(out.x), MetalContext.srgbDecode(out.y), MetalContext.srgbDecode(out.z))
    }

    /// `apply` to an sRGB-encoded byte triple (what a frame without the cube shows), back to sRGB bytes.
    private static func applyToBytes(_ cube: ColorCube, r: UInt8, g: UInt8, b: UInt8) -> (UInt8, UInt8, UInt8) {
        let out = apply(cube, SIMD3(Double(r), Double(g), Double(b)) / 255)
        return (ResampleReference.encode(out.x), ResampleReference.encode(out.y), ResampleReference.encode(out.z))
    }

    private static func lut(_ cube: ColorCube) throws -> ColorLUT { try #require(ColorLUT.make(cube)) }

    /// The largest difference of any colour channel over the pixels `mask` selects.
    private static func worst(_ a: [UInt8], _ b: [UInt8], width: Int, mask: (Int, Int) -> Bool = { _, _ in true }) -> Int {
        var worst = 0
        for i in stride(from: 0, to: a.count, by: 4) where mask((i / 4) % width, (i / 4) / width) {
            for ch in 0..<3 { worst = max(worst, abs(Int(a[i + ch]) - Int(b[i + ch]))) }
        }
        return worst
    }

    // MARK: Pictures

    /// Noise colours under a disc feathered over 12 px and a band whose alpha ramps left to right; transparent elsewhere.
    private static func softDisc(_ x: Int, _ y: Int) -> Px {
        let d = hypot(Double(x) - 350.5, Double(y) - 230.5)
        var a = min(max((160 - d) / 12 + 0.5, 0), 1)
        if (400..<440).contains(y) { a = max(a, Double(x) / 699) }
        let n = TestImages.noiseAndEdges(x, y), alpha = UInt8((a * 255).rounded())
        func p(_ c: UInt8) -> UInt8 { UInt8((Double(c) * Double(alpha) / 255).rounded()) }
        return (p(n.b), p(n.g), p(n.r), alpha)
    }

    // MARK: Tests

    @Test func identityCubeMatchesNoCube() async throws {
        // A cube made from the identity's values is not the shared identity (`isIdentity` is false), so its frames take
        // the COLOR_LUT pipelines: encode, look up, decode is the identity within a code on every path, opaque or not.
        let identity = try Self.lut(.identity)
        #expect(!identity.isIdentity)
        let opaque = try await TiledImage.make(from: TestImages.synthetic(700, 460, pixel: TestImages.noiseAndEdges))
        let soft = try await TiledImage.make(from: TestImages.synthetic(700, 460, pixel: Self.softDisc))
        #expect(soft.hasAlpha && !opaque.hasAlpha)
        for (picture, image) in [("opaque", opaque), ("alpha", soft)] {
            for (name, settings, scale, mode) in Self.paths {
                let t = Self.transform(700, 460, .actual(scale), centre: (430.37, 290.71))
                let plain = Self.renderer(settings)
                let without = try await Self.render(image, t, renderer: plain)
                let cubed = Self.renderer(settings, color: ColorFrame(lut: identity))
                let with = try await Self.render(image, t, renderer: cubed)
                #expect(!plain.lastColorLUT && cubed.lastColorLUT && cubed.lastMode == mode, "\(picture) \(name)")
                let worst = Self.worst(with, without, width: 401)
                guard picture == "alpha", mode == .metalfx else {
                    print("identity cube, \(picture) \(name): worst \(worst)")
                    #expect(worst <= 1, "\(picture) \(name): worst \(worst)")
                    continue
                }
                // With alpha MetalFX corrects in the compose pass, before its scaler, whose output is not linear in its
                // input: the identity's rounding moves a few input bytes by one, and those move up to 6 codes of
                // the output in ~0.2 % of the pixels (Apple M4 Max).
                var moved = 0
                for i in stride(from: 0, to: with.count, by: 4)
                where (0..<3).contains(where: { abs(Int(with[i + $0]) - Int(without[i + $0])) > 1 }) { moved += 1 }
                print("identity cube, alpha metalfx: worst \(worst), \(moved) px off by more than 1")
                #expect(worst <= 8 && moved * 200 <= with.count / 4, "alpha metalfx: worst \(worst), \(moved) px")
            }
        }
    }

    @Test func cubeMatchesCPU() async throws {
        // 100 % Lanczos-3, the frame being the picture's own pixels: every pixel is the CPU lookup of its source byte.
        let image = try await TiledImage.make(from: TestImages.synthetic(700, 460, pixel: TestImages.noiseAndEdges))
        let t = Self.actual
        #expect(t.viewPoint(forImage: .zero) == CGPoint(x: -150, y: -100))
        let renderer = Self.renderer(Self.lanczos, color: ColorFrame(lut: try Self.lut(Self.testCube)))
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastColorLUT && renderer.lastMode == .kernel(.lanczos3, upscale: false))
        var expected = frame
        for y in 0..<260 {
            for x in 0..<400 {
                let p = TestImages.noiseAndEdges(x + 150, y + 100), o = (y * 400 + x) * 4
                (expected[o + 2], expected[o + 1], expected[o]) = Self.applyToBytes(Self.testCube, r: p.r, g: p.g, b: p.b)
            }
        }
        let worst = Self.worst(frame, expected, width: 400)
        print("cube at 100 %: worst \(worst), \(ResampleReference.psnr(frame, expected, width: 400)) dB")
        #expect(worst <= 2)

        // Every path: its frame with the cube is the CPU lookup of its frame without (whose bytes are a half code off
        // the filtered light at most); around the picture the background, untouched.
        for (name, settings, scale, mode) in Self.paths {
            let t = Self.transform(700, 460, .actual(scale), centre: (430.37, 290.71))
            let without = try await Self.render(image, t, renderer: Self.renderer(settings))
            let cubed = Self.renderer(settings, color: ColorFrame(lut: try Self.lut(Self.testCube)))
            let with = try await Self.render(image, t, renderer: cubed)
            #expect(cubed.lastColorLUT && cubed.lastMode == mode, "\(name)")
            var expected = without
            for y in 0..<263 {
                for x in 0..<401 where Self.inside(t, x, y) {
                    let o = (y * 401 + x) * 4
                    (expected[o + 2], expected[o + 1], expected[o]) =
                        Self.applyToBytes(Self.testCube, r: without[o + 2], g: without[o + 1], b: without[o])
                }
            }
            let worst = Self.worst(with, expected, width: 401)
            let outside = Self.worst(with, without, width: 401) { !Self.inside(t, $0, $1) }
            print("cube, \(name): worst \(worst) against the CPU lookup of the plain frame; outside \(outside)")
            #expect(worst <= 2 && outside == 0, "\(name): worst \(worst), outside \(outside)")
        }
    }

    /// Left of x = 300 transparent; right of it, above y = 230, one colour (200, 100, 50) at alpha 128; below, noise
    /// colours whose alpha ramps from 0 at x = 300 to 1 at the right edge.
    private static func halfAndRamp(_ x: Int, _ y: Int) -> Px {
        guard x >= 300 else { return (0, 0, 0, 0) }
        let straight: (r: UInt8, g: UInt8, b: UInt8)
        let alpha: UInt8
        if y < 230 {
            straight = (200, 100, 50)
            alpha = 128
        } else {
            let n = TestImages.noiseAndEdges(x, y)
            straight = (n.r, n.g, n.b)
            alpha = UInt8((Double(x - 300) / 399 * 255).rounded())
        }
        func p(_ c: UInt8) -> UInt8 { UInt8((Double(c) * Double(alpha) / 255).rounded()) }
        return (p(straight.b), p(straight.g), p(straight.r), alpha)
    }

    /// The texel the renderer holds for a decoder's pixel (`uploadPremultipliedLinear`, exact table) as linear light,
    /// premultiplied, and its alpha.
    private static func storedTexel(_ p: Px) -> (rgb: SIMD3<Double>, a: Double) {
        let table = premultipliedTable, row = Int(p.a) * 256
        func lin(_ s: UInt8) -> Double { ResampleReference.linear(table[row + Int(s)]) }
        return (SIMD3(lin(p.r), lin(p.g), lin(p.b)), Double(p.a) / 255)
    }
    private static let premultipliedTable = MetalContext.premultipliedLinearTable()

    @Test(arguments: [TransparencyMode.checker, .white])
    func alphaBackdropUntouched(mode: TransparencyMode) async throws {
        // Review focus 3. Over the backdrop the cube corrects the photo's straight colour, never the backdrop: transparent
        // pixels are the frame without the cube to the byte on every path (MetalFX included, whose compose pass
        // composites); a flat half-transparent colour is `cube(colour) · a + (1 − a) · back`; at 100 % every texel of
        // an alpha ramp from 0 (unpremultiplied by tiny alphas: no NaN, no blow-up) is the CPU reference.
        let image = try await TiledImage.make(from: TestImages.synthetic(700, 460, pixel: Self.halfAndRamp))
        #expect(image.hasAlpha)
        let settings = TransparencySettings(mode: mode, checkerSizePt: 8, colors: .light, background: Self.surround)
        func back(_ t: ViewTransform) -> (Int, Int) -> SIMD3<Double> {
            let origin = t.viewPoint(forImage: .zero)
            let ox = Float(origin.x), oy = Float(origin.y)
            return { x, y in
                let cx = ((Float(x) + 0.5 - ox) / 16).rounded(.down), cy = ((Float(y) + 0.5 - oy) / 16).rounded(.down)
                let c = Int(cx + cy) & 1 == 0 ? settings.colors.0 : settings.colors.1
                return SIMD3(Double(c.x), Double(c.y), Double(c.z))
            }
        }
        func composite(_ texel: (rgb: SIMD3<Double>, a: Double), _ back: SIMD3<Double>) -> (UInt8, UInt8, UInt8) {
            // The shader's form: the straight colour clamped, looked up, and the change times alpha added.
            var rgb = texel.rgb
            if texel.a > 0 {
                let straight = simd_clamp(texel.rgb / texel.a, SIMD3(repeating: 0), SIMD3(repeating: 1))
                let e = SIMD3(MetalContext.srgbEncode(straight.x), MetalContext.srgbEncode(straight.y),
                              MetalContext.srgbEncode(straight.z))
                rgb += (Self.apply(Self.testCube, e) - straight) * texel.a
            }
            let out = rgb + (1 - texel.a) * back
            return (ResampleReference.encode(out.x), ResampleReference.encode(out.y), ResampleReference.encode(out.z))
        }

        // 100 %: every texel.
        let t = Self.actual
        let full = Self.renderer(Self.lanczos, mode, color: ColorFrame(lut: try Self.lut(Self.testCube)))
        let frame = try await Self.render(image, t, renderer: full)
        #expect(full.lastColorLUT && full.lastHasAlpha)
        var expected = frame
        let cells = back(t)
        for y in 0..<260 {
            for x in 0..<400 {
                let o = (y * 400 + x) * 4
                (expected[o + 2], expected[o + 1], expected[o]) =
                    composite(Self.storedTexel(Self.halfAndRamp(x + 150, y + 100)), cells(x, y))
            }
        }
        let worst = Self.worst(frame, expected, width: 400)
        print("alpha over \(mode) at 100 %: worst \(worst)")
        #expect(worst <= 2, "100 %: worst \(worst)")

        // Every path: the transparent region and the flat half-transparent one, 8 image px from any edge.
        let half = Self.storedTexel(Self.halfAndRamp(400, 100))
        for (name, settings, scale, _) in Self.paths {
            let t = Self.transform(700, 460, .actual(scale), centre: (300.37, 230.71))
            let without = try await Self.render(image, t, renderer: Self.renderer(settings, mode))
            let cubed = Self.renderer(settings, mode, color: ColorFrame(lut: try Self.lut(Self.testCube)))
            let with = try await Self.render(image, t, renderer: cubed)
            #expect(cubed.lastColorLUT && cubed.lastHasAlpha, "\(name)")
            let cells = back(t)
            var transparent = 0, flat = 0, worstClear = 0, worstFlat = 0
            for y in 0..<263 {
                for x in 0..<401 where Self.inside(t, x, y) {
                    let (ix, iy) = Self.imagePoint(t, x, y), o = (y * 401 + x) * 4
                    if ix < 292 {
                        transparent += 1
                        for ch in 0..<3 { worstClear = max(worstClear, abs(Int(with[o + ch]) - Int(without[o + ch]))) }
                    } else if ix >= 308, iy < 222 {
                        flat += 1
                        let e = composite(half, cells(x, y))
                        for (ch, v) in [(2, e.0), (1, e.1), (0, e.2)] {
                            worstFlat = max(worstFlat, abs(Int(with[o + ch]) - Int(v)))
                        }
                    }
                }
            }
            print("alpha over \(mode), \(name): transparent \(transparent) px worst \(worstClear), flat \(flat) px worst \(worstFlat)")
            #expect(transparent > 1000 && flat > 1000, "\(name)")
            #expect(worstClear == 0 && worstFlat <= 2, "\(name): transparent \(worstClear), flat \(worstFlat)")
        }
    }

    @Test func tableCurveWithCube() async throws {
        // Review focus 5. An Adobe RGB photo's levels hold enc_srgb(lin_γ2.2(s)) (rounded to a byte), which is the
        // cube's input as it is; its output, decoded to linear light, goes out through the inverse table: at 100 % each
        // pixel is γ 2.2's code of the CPU lookup of its stored byte.
        let space = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        let curve = ColorCurve.of(space)
        let image = try await TiledImage.make(from: TestImages.synthetic(700, 460, colorSpace: space,
                                                                         pixel: TestImages.noiseAndEdges))
        #expect(image.curve.map { $0 != .srgb } == true)
        let renderer = Self.renderer(Self.lanczos, color: ColorFrame(lut: try Self.lut(Self.testCube)))
        let frame = try await Self.render(image, Self.actual, renderer: renderer)
        #expect(renderer.lastColorLUT && renderer.lastCurveTable)
        func code(_ light: Double) -> UInt8 { UInt8((Double(curve.encode(Float(light))) * 255).rounded()) }
        func stored(_ s: UInt8) -> Double { Double(ResampleReference.encode(Double(curve.decode(Float(s) / 255)))) / 255 }
        var expected = frame
        for y in 0..<260 {
            for x in 0..<400 {
                let p = TestImages.noiseAndEdges(x + 150, y + 100), o = (y * 400 + x) * 4
                let out = Self.apply(Self.testCube, SIMD3(stored(p.r), stored(p.g), stored(p.b)))
                (expected[o + 2], expected[o + 1], expected[o]) = (code(out.x), code(out.y), code(out.z))
            }
        }
        let worst = Self.worst(frame, expected, width: 400)
        print("Adobe RGB with the cube at 100 %: worst \(worst)")
        #expect(worst <= 2)
    }

    @Test func mixHalf() async throws {
        // The transition: from the identity to the cube at mix 0.5 is half way in linear light; `from: nil` means the
        // identity; mix 0 is the frame without the cube.
        let image = try await TiledImage.make(from: TestImages.synthetic(700, 460, pixel: TestImages.noiseAndEdges))
        let cube = try Self.lut(Self.testCube)
        let half = Self.renderer(Self.lanczos, color: ColorFrame(lut: cube, from: ColorLUT.identity(), mix: 0.5))
        let frame = try await Self.render(image, Self.actual, renderer: half)
        #expect(half.lastColorLUT)
        var expected = frame
        for y in 0..<260 {
            for x in 0..<400 {
                let p = TestImages.noiseAndEdges(x + 150, y + 100), o = (y * 400 + x) * 4
                let source = SIMD3(ResampleReference.linear(p.r), ResampleReference.linear(p.g), ResampleReference.linear(p.b))
                let corrected = Self.apply(Self.testCube, SIMD3(Double(p.r), Double(p.g), Double(p.b)) / 255)
                let out = 0.5 * source + 0.5 * corrected
                (expected[o + 2], expected[o + 1], expected[o]) =
                    (ResampleReference.encode(out.x), ResampleReference.encode(out.y), ResampleReference.encode(out.z))
            }
        }
        let worst = Self.worst(frame, expected, width: 400)
        print("mix 0.5: worst \(worst)")
        #expect(worst <= 2)
        let implicit = Self.renderer(Self.lanczos, color: ColorFrame(lut: cube, from: nil, mix: 0.5))
        #expect(try await Self.render(image, Self.actual, renderer: implicit) == frame)
        let none = Self.renderer(Self.lanczos, color: ColorFrame(lut: cube, mix: 0))
        let plain = try await Self.render(image, Self.actual, renderer: Self.renderer(Self.lanczos))
        let start = try await Self.render(image, Self.actual, renderer: none)
        #expect(none.lastColorLUT && Self.worst(start, plain, width: 400) <= 1)
    }

    @Test func nilColorKeepsPipeline() async throws {
        // Review focus 4. Without a cube, and with the shared identity at mix 1 (correction faded out), frames take the
        // pipelines of before: `lastColorLUT` is false and the bytes are the hashes recorded before M3c
        // (`CurveRendererTests.srgbImagesUnchanged`, Apple M4 Max), also right after a frame with a cube.
        let image = try await TiledImage.make(from: TestImages.synthetic(1300, 900, pixel: TestImages.noiseAndEdges))
        let magenta = BackgroundColor(red: 0xff, green: 0, blue: 0xff)
        var cases: [(String, ResampleSettings, Double, UInt64)] = [
            ("lanczos3 down", Self.lanczos, 0.66, 0xfada_ef82_ddd8_c2df),
            ("ewa-lanczos", Self.ewa, 2.5, 0x47e1_6844_7388_4283),
        ]
        if MetalContext.shared.supportsMetalFX { cases.append(("metalfx", Self.metalfx, 2.5, 0x78ac_bcd3_4e56_4bc2)) }
        let identity = ColorLUT.identity()
        #expect(identity.isIdentity && ColorLUT.identity() === identity)
        for (name, settings, scale, hash) in cases {
            let t = Self.transform(1300, 900, view: (641, 403), .actual(scale), centre: (512.37, 450.71))
            for color in [nil, ColorFrame(lut: identity), ColorFrame(lut: identity, from: try Self.lut(Self.testCube), mix: 1)] {
                let r = Self.renderer(settings, background: magenta)
                r.color = ColorFrame(lut: try Self.lut(Self.testCube))
                let corrected = try await Self.render(image, t, renderer: r)
                #expect(r.lastColorLUT && Self.fnv(corrected) != hash, "\(name)")
                r.color = color
                let frame = try await Self.render(image, t, renderer: r)
                #expect(!r.lastColorLUT, "\(name)")
                #expect(Self.fnv(frame) == hash, "\(name): 0x\(String(Self.fnv(frame), radix: 16))")
            }
        }
    }

    @Test func colorLUTVariantsBindTheCubeAtTextures4And5() throws {
        // Every COLOR_LUT function takes the cube at texture 4, the transition's `from` at 5 and ColorLUTParams at its
        // next free buffer (2 for the fragments, 3 for the kernels), where TileRenderer binds them; MetalFX's compose
        // pass only with HAS_ALPHA (it composites there).
        let c = MetalContext.shared
        let members = ["scale": 0, "offset": 4, "mix": 8, "pad": 12]
        func check(_ bindings: [any MTLBinding], buffer: Int, _ name: String) {
            #expect(bindings.first { $0.name == "lut" }?.index == 4, "\(name)")
            #expect(bindings.first { $0.name == "from" }?.index == 5, "\(name)")
            let params = bindings.first { $0.name == "cube" } as? MTLBufferBinding
            #expect(params?.index == buffer && params?.bufferDataSize == MemoryLayout<ColorLUTParams>.stride, "\(name)")
            let found = (params?.bufferStructType?.members ?? []).map { ($0.name, $0.offset) }
            #expect(Dictionary(uniqueKeysWithValues: found) == members, "\(name)")
        }
        #expect(MemoryLayout<ColorLUTParams>.size == 16 && MemoryLayout<ColorLUTParams>.alignment == 4)
        var compute: MTLComputePipelineReflection?
        for alpha in [false, true] {
            _ = try c.device.makeComputePipelineState(function: MetalContext.resampleFunction(
                c.library, kernel: .lanczos3, upscale: false, alpha: alpha, curveTable: true, colorLUT: true),
                options: [.bindingInfo, .bufferTypeInfo], reflection: &compute)
            check(compute?.bindings ?? [], buffer: 3, "resample alpha \(alpha)")
            _ = try c.device.makeComputePipelineState(function: MetalContext.function(c.library, "resampleEWA", alpha: alpha,
                                                                                      colorLUT: true),
                                                      options: [.bindingInfo, .bufferTypeInfo], reflection: &compute)
            check(compute?.bindings ?? [], buffer: 3, "resampleEWA alpha \(alpha)")
            for (vertex, fragment) in [("tileVertex", "tileFragment"), ("tileVertex", "tileFragmentNearest"),
                                       ("metalfxVertex", "metalfxFragment"), ("metalfxVertex", "metalfxComposeFragment")] {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = c.library.makeFunction(name: vertex)
                d.fragmentFunction = MetalContext.function(c.library, fragment, alpha: alpha, colorLUT: true)
                d.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
                var render: MTLRenderPipelineReflection?
                _ = try c.device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo],
                                                         reflection: &render)
                check(render?.fragmentBindings ?? [], buffer: 2, "\(fragment) alpha \(alpha)")
            }
        }
        // The cache keys: a COLOR_LUT pipeline is its own, the plain one stays the one of before.
        #expect(c.tilePipeline(pixelFormat: .bgra8Unorm_srgb) === c.tilePipeline(pixelFormat: .bgra8Unorm_srgb, colorLUT: false))
        #expect(c.tilePipeline(pixelFormat: .bgra8Unorm_srgb) !== c.tilePipeline(pixelFormat: .bgra8Unorm_srgb, colorLUT: true))
        #expect(c.resamplePipeline(kernel: .lanczos3, upscale: true)
                    !== c.resamplePipeline(kernel: .lanczos3, upscale: true, colorLUT: true))
        #expect(c.ewaPipeline() !== c.ewaPipeline(colorLUT: true))
        #expect(c.metalFXPipeline(pixelFormat: .bgra8Unorm_srgb) !== c.metalFXPipeline(pixelFormat: .bgra8Unorm_srgb,
                                                                                         colorLUT: true))
        // The opaque compose pass has no cube: its variant is the plain one.
        #expect(c.metalFXPipeline(pixelFormat: .bgra8Unorm_srgb, compose: true)
                    === c.metalFXPipeline(pixelFormat: .bgra8Unorm_srgb, compose: true, colorLUT: true))
    }

    @Test func cubeTexture() throws {
        // The cube as a 3D rgba16Float texture of n³ texels, r along width, g along height, b along depth.
        let lut = try Self.lut(Self.testCube)
        let n = ColorCube.dimension
        #expect(lut.texture.textureType == .type3D && lut.texture.pixelFormat == .rgba16Float)
        #expect(lut.texture.width == n && lut.texture.height == n && lut.texture.depth == n)
        var texel = [Half](repeating: 0, count: 4)
        let (r, g, b) = (5, 17, 29)
        lut.texture.getBytes(&texel, bytesPerRow: 8, bytesPerImage: 8, from: MTLRegionMake3D(r, g, b, 1, 1, 1),
                             mipmapLevel: 0, slice: 0)
        let node = ((b * n + g) * n + r) * 4
        #expect(Array(texel) == Array(Self.testCube.values[node..<node + 4]))
    }
}
