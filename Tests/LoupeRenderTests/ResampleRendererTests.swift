import CoreGraphics
import Foundation
import LoupeCore
import Metal
import Testing
@testable import LoupeRender

/// The `resample` compute path of `TileRenderer` against the CPU reference (spec §3.2, §8). Every renderer here sets
/// `resample` explicitly, with `pixel-art` off where the scale would otherwise route the frame to nearest (the pixel-art
/// tests at the end set it on purpose).
@Suite struct ResampleRendererTests {
    private typealias Px = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

    private static let magenta = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)

    /// One kernel for both directions, `upscale-high` and pixel-art off: whatever the scale, the frame goes through
    /// the kernel path with that kernel.
    private static func settings(_ kernel: ResampleKernel, antiringing: Bool = false) -> ResampleSettings {
        ResampleSettings(upscale: .kernel(kernel), upscaleHighPercent: 0, downscale: .kernel(kernel),
                         antiringing: antiringing, pixelArtPercent: 0)
    }

    private static func renderer(_ settings: ResampleSettings, background: MTLClearColor = magenta) -> TileRenderer {
        let r = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
        r.resample = settings
        r.background = background
        return r
    }

    /// A transform centred on image point `centre` (image px rather than relative), so a test names the spot it
    /// looks at; the image centre when nil.
    private static func transform(image: (Int, Int), view: (Int, Int) = (640, 400), _ mode: ZoomMode,
                                  centre: (Double, Double)? = nil) -> ViewTransform {
        let c = centre.map { CGPoint(x: $0.0 / Double(image.0), y: $0.1 / Double(image.1)) } ?? CGPoint(x: 0.5, y: 0.5)
        return ViewTransform(imageSize: CGSize(width: image.0, height: image.1),
                             viewSize: CGSize(width: view.0, height: view.1), mode: mode, center: c)
    }

    /// Encodes one frame into a fresh target (first filled with `prefill`, if given, so unwritten pixels show) and
    /// reads it back.
    private static func render(_ image: TiledImage, _ t: ViewTransform, renderer: TileRenderer,
                               prefill: MTLClearColor? = nil) async throws -> [UInt8] {
        let target = TestImages.renderTarget(Int(t.viewSize.width), Int(t.viewSize.height))
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        if let prefill {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = prefill
            pass.colorAttachments[0].storeAction = .store
            try #require(commands.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        }
        renderer.encode(image: image, transform: t, into: commands, target: target)
        commands.commit()
        return try await TestImages.readTexture(target)
    }

    /// The geometry the renderer hands the kernel, in the Float precision it hands it in.
    private struct Geometry {
        let level: Int, m: Double, offset: SIMD2<Double>, extent: SIMD2<Double>
    }

    private static func geometry(_ image: TiledImage, _ t: ViewTransform, level: Int) -> Geometry {
        let factor = Double(1 << level), origin = t.viewPoint(forImage: .zero)
        let f = { (v: Double) in Double(Float(v)) }
        return Geometry(level: level, m: f(t.scale * factor), offset: SIMD2(f(origin.x), f(origin.y)),
                        extent: SIMD2(f(Double(image.grid.imageSize.width) / factor),
                                      f(Double(image.grid.imageSize.height) / factor)))
    }

    /// The reference frame for what `renderer` drew: level 0 from `pixel`, a coarser level read back from the GPU
    /// (the pyramid is the GPU's; the reference only checks the resampling of it).
    private static func reference(_ image: TiledImage, _ t: ViewTransform, level: Int, kernel: ResampleKernel,
                                  pixel: @escaping (Int, Int) -> Px, background: MTLClearColor = magenta) async throws -> [UInt8] {
        let size = image.grid.levelSize(level)
        var source = pixel
        if level > 0 {
            let decoded = try await TestImages.readLevel(try #require(image.residentViews()[level]), grid: image.grid, level: level)
            let base = decoded.buffer.bytes.assumingMemoryBound(to: UInt8.self), stride = decoded.bytesPerRow
            let bytes = Array(UnsafeBufferPointer(start: base, count: stride * size.height))
            source = { x, y in
                let o = y * stride + x * 4
                return (bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3])
            }
        }
        let g = geometry(image, t, level: level)
        let lin = ResampleReference.linear
        return ResampleReference.render(
            source: { x, y in let p = source(x, y); return (lin(p.r), lin(p.g), lin(p.b)) },
            width: size.width, height: size.height, kernel: kernel, m: g.m, offset: g.offset, extent: g.extent,
            viewWidth: Int(t.viewSize.width), viewHeight: Int(t.viewSize.height),
            background: (background.red, background.green, background.blue))
    }

    /// Pixels within 16 view px of a tile seam of `level` (level px multiples of 512 inside the level).
    private static func seamBands(_ image: TiledImage, _ t: ViewTransform, level: Int) -> (Int, Int) -> Bool {
        let g = geometry(image, t, level: level), size = image.grid.levelSize(level)
        let xs = stride(from: 512, to: size.width, by: 512).map { g.offset.x + Double($0) * g.m }
        let ys = stride(from: 512, to: size.height, by: 512).map { g.offset.y + Double($0) * g.m }
        return { x, y in
            xs.contains { abs(Double(x) + 0.5 - $0) <= 16 } || ys.contains { abs(Double(y) + 0.5 - $0) <= 16 }
        }
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

    // MARK: Against the reference

    @Test(TestLevel.fullOnly, arguments: ResampleKernel.allCases, [3, 1.25, 0.66, 0.51])
    func matchesReference(kernel: ResampleKernel, scale: Double) async throws {
        let image = try await TiledImage.make(from: TestImages.synthetic(1300, 900, pixel: TestImages.noiseAndEdges))
        #expect(image.grid.columns(0) == 3 && image.grid.rows(0) == 2)
        // Magnified: around the (512, 512) seam corner; reduced: the middle, so every seam and two image edges show.
        let t = Self.transform(image: (1300, 900), .actual(scale), centre: scale > 1 ? (512.37, 512.71) : (650.37, 450.71))
        let origin = t.viewPoint(forImage: .zero)
        #expect(origin.x != origin.x.rounded() && origin.y != origin.y.rounded())   // fractional pan
        let level = image.grid.drawnLevel(forScale: t.scale, finestResident: 0)

        let renderer = Self.renderer(Self.settings(kernel))
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .kernel(kernel, upscale: scale > 1))
        #expect(renderer.lastLevel == level)

        let expected = try await Self.reference(image, t, level: level, kernel: kernel, pixel: TestImages.noiseAndEdges)
        let bands = Self.seamBands(image, t, level: level)
        let all = ResampleReference.psnr(frame, expected, width: 640)
        let seams = ResampleReference.psnr(frame, expected, width: 640, mask: bands)
        print("PSNR \(kernel) x\(scale) L\(level): frame \(all) dB, seams \(seams) dB")
        #expect(all >= 55, "\(kernel) x\(scale): frame \(all) dB")
        #expect(seams >= 55, "\(kernel) x\(scale): seams \(seams) dB")
    }

    @Test func matchesReferenceAboveLevelZero() async throws {
        // An odd-size image at 0.3 draws level 1 (651 x 452 of 1301 x 903, whose last level px overhangs the image by
        // half a pixel): extent < levelSize on a coarser level, which the level-0 cases above never reach.
        let image = try await TiledImage.make(from: TestImages.synthetic(1301, 903, pixel: TestImages.noiseAndEdges))
        let t = Self.transform(image: (1301, 903), .actual(0.3), centre: (650.37, 451.71))
        let renderer = Self.renderer(Self.settings(.lanczos3))
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastLevel == 1)
        #expect(renderer.lastMode == .kernel(.lanczos3, upscale: false))
        let expected = try await Self.reference(image, t, level: 1, kernel: .lanczos3, pixel: TestImages.noiseAndEdges)
        let all = ResampleReference.psnr(frame, expected, width: 640)
        print("PSNR lanczos3 x0.3 L1 (1301x903): frame \(all) dB")
        #expect(all >= 55, "frame \(all) dB")
    }

    @Test(arguments: [ResampleKernel.lanczos3, .catmullRom])
    func actualSizeIsExact(kernel: ResampleKernel) async throws {
        // The integer-aligned pan of TileRendererTests.actualSizeMatchesSource: an interpolating kernel at m = 1
        // has weight 1 on the centre tap and 0 on every other, so the source bytes come back unchanged.
        let image = try await TiledImage.make(from: TestImages.synthetic(1100, 700))
        let t = Self.transform(image: (1100, 700), .actual(1))
        #expect(t.visibleRect.origin == CGPoint(x: 230, y: 150))
        let renderer = Self.renderer(Self.settings(kernel))
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .kernel(kernel, upscale: false))
        var wrong = 0
        for y in 0..<400 {
            for x in 0..<640 where Self.pixel(frame, width: 640, x, y) != TestImages.pattern(x + 230, y + 150) { wrong += 1 }
        }
        #expect(wrong == 0)
    }

    @Test func backgroundOutside() async throws {
        // Fit of a wide strip: the image covers view y 126.2 ..< 273.8, so threadgroup rows 0-6 (y < 112) and 17+
        // (y >= 272 partly, 288+ wholly) lie entirely outside it and take the early-out.
        let image = try await TiledImage.make(from: TestImages.synthetic(1300, 300, pixel: TestImages.noiseAndEdges))
        let t = Self.transform(image: (1300, 300), .fit)
        let renderer = Self.renderer(Self.settings(.lanczos3))
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .kernel(.lanczos3, upscale: false))
        #expect(renderer.lastLevel == 1)
        #expect(t.viewPoint(forImage: .zero).y > 112)
        var wrong = 0, outside = 0
        for y in 0..<400 {
            for x in 0..<640 where !Self.inside(t, x, y) {
                outside += 1
                if Self.pixel(frame, width: 640, x, y) != (255, 0, 255, 255) { wrong += 1 }
            }
        }
        #expect(outside > 640 * 200)
        #expect(wrong == 0)
    }

    @Test func oddViewSize() async throws {
        // 641 x 403: the last threadgroup column has 1 thread inside the drawable, the last row 3. Every pixel must
        // be written (green would show through) and every barrier reached (else the group's output is garbage).
        let image = try await TiledImage.make(from: TestImages.synthetic(1300, 900, pixel: TestImages.noiseAndEdges))
        let t = Self.transform(image: (1300, 900), view: (641, 403), .actual(0.66), centre: (650.37, 450.71))
        let renderer = Self.renderer(Self.settings(.lanczos3))
        let frame = try await Self.render(image, t, renderer: renderer, prefill: MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1))
        #expect(renderer.lastMode == .kernel(.lanczos3, upscale: false))
        let expected = try await Self.reference(image, t, level: 0, kernel: .lanczos3, pixel: TestImages.noiseAndEdges)
        let all = ResampleReference.psnr(frame, expected, width: 641)
        let edges = ResampleReference.psnr(frame, expected, width: 641) { x, y in x == 640 || y == 402 }
        print("PSNR odd view 641x403 x0.66: frame \(all) dB, last column and row \(edges) dB")
        #expect(all >= 55)
        #expect(edges >= 55)
        var green = 0
        for y in 0..<403 where Self.pixel(frame, width: 641, 640, y) == (0, 255, 0, 255) { green += 1 }
        for x in 0..<641 where Self.pixel(frame, width: 641, x, 402) == (0, 255, 0, 255) { green += 1 }
        #expect(green == 0)
    }

    @Test func tinyImageFarOut() async throws {
        // 300 x 200 has one level; zoomed out to the transform's limit (0.25) it draws that level at m < 0.5,
        // which is the bilinear path (the kernel's row buffer would not hold the rows), with background around it.
        let image = try await TiledImage.make(from: TestImages.synthetic(300, 200, pixel: TestImages.noiseAndEdges))
        let t = Self.transform(image: (300, 200), .actual(0.1))
        #expect(t.scale < 0.5)
        let renderer = Self.renderer(ResampleSettings())
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .bilinear)
        var wrong = 0, inside = 0
        for y in 0..<400 {
            for x in 0..<640 {
                if Self.inside(t, x, y) { inside += 1 } else if Self.pixel(frame, width: 640, x, y) != (255, 0, 255, 255) { wrong += 1 }
            }
        }
        #expect(inside > 0)
        #expect(wrong == 0)
    }

    @Test(TestLevel.fullOnly, arguments: ResampleKernel.allCases, [64, 0.501])
    func extremeZoom(kernel: ResampleKernel, scale: Double) async throws {
        // 64: the transform's limit, 10 x 6 level px on screen. 0.501: just above the kernel path's floor, where a
        // threadgroup needs the most level rows (15 / m + taps = 42 of the buffer's 48).
        let image = try await TiledImage.make(from: TestImages.synthetic(600, 400, pixel: TestImages.noiseAndEdges))
        let t = Self.transform(image: (600, 400), .actual(scale), centre: (300.37, 200.71))
        #expect(t.scale == scale)
        let renderer = Self.renderer(Self.settings(kernel))
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .kernel(kernel, upscale: scale > 1))
        #expect(renderer.lastLevel == 0)
        let expected = try await Self.reference(image, t, level: 0, kernel: kernel, pixel: TestImages.noiseAndEdges)
        let all = ResampleReference.psnr(frame, expected, width: 640)
        print("PSNR \(kernel) x\(scale) (600x400): frame \(all) dB")
        #expect(all >= 55, "\(kernel) x\(scale): \(all) dB")
    }

    // MARK: Pixel art (nearest)

    /// Default settings except for the pixel-art threshold.
    private static func pixelArtRenderer(percent: Int = 400) -> TileRenderer {
        var settings = ResampleSettings()
        settings.pixelArtPercent = percent
        return renderer(settings)
    }

    @Test func pixelArtIsNearest() async throws {
        // 200 x 150 at 400 %: every view pixel is exactly the source pixel under its centre (no blending across the
        // 4 x 4 blocks, none across the tile-free image), at a fractional pan so the blocks do not start on view px.
        let image = try await TiledImage.make(from: TestImages.synthetic(200, 150))
        let t = Self.transform(image: (200, 150), .actual(4), centre: (100.37, 75.71))
        let origin = t.viewPoint(forImage: .zero)
        #expect(origin.x != origin.x.rounded() && origin.y != origin.y.rounded())
        let renderer = Self.pixelArtRenderer()
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .nearest)
        #expect(renderer.lastLevel == 0)
        var wrong = 0, covered = 0
        for y in 0..<400 {
            for x in 0..<640 {
                let sx = Int(((Double(x) + 0.5 - origin.x) / 4).rounded(.down))
                let sy = Int(((Double(y) + 0.5 - origin.y) / 4).rounded(.down))
                guard (0..<200).contains(sx), (0..<150).contains(sy) else { continue }
                covered += 1
                if Self.pixel(frame, width: 640, x, y) != TestImages.pattern(sx, sy) { wrong += 1 }
            }
        }
        #expect(covered > 640 * 400 / 2)
        #expect(wrong == 0)
    }

    @Test func pixelArtWaitsForLevelZero() async throws {
        // Only level 2 resident (a preview), 400 %: the stretched coarse level goes through the smooth kernel, not
        // nearest, whose blocks would be 16 image px wide.
        let full = try await TiledImage.make(from: TestImages.synthetic(1300, 900))
        let level2 = try await TestImages.readLevel(try #require(full.residentViews()[2]), grid: full.grid, level: 2)
        let preview = TiledImage.empty(grid: full.grid, colorSpace: full.colorSpace)
        try await preview.upload(LevelImage(image: level2, level: 2))
        #expect(preview.finestResidentLevel == 2)
        let t = Self.transform(image: (1300, 900), .actual(4))
        let renderer = Self.pixelArtRenderer()
        _ = try await Self.render(preview, t, renderer: renderer)
        #expect(renderer.lastLevel == 2)
        #expect(renderer.lastMode == .kernel(.mitchell, upscale: true))   // m 16: upscale-high's default
        // With level 0 resident the same frame is nearest.
        _ = try await Self.render(full, t, renderer: renderer)
        #expect(renderer.lastLevel == 0)
        #expect(renderer.lastMode == .nearest)
    }

    @Test func pixelArtThreshold() async throws {
        let image = try await TiledImage.make(from: TestImages.synthetic(200, 150))
        let renderer = Self.pixelArtRenderer(percent: 800)
        _ = try await Self.render(image, Self.transform(image: (200, 150), .actual(4)), renderer: renderer)
        #expect(renderer.lastMode == .kernel(.mitchell, upscale: true))   // upscale-high from 300 %
        _ = try await Self.render(image, Self.transform(image: (200, 150), .actual(8)), renderer: renderer)
        #expect(renderer.lastMode == .nearest)
    }

    // MARK: MetalFX (spec §3.5)

    /// A smooth picture MetalFX's edge-adaptive sharpening barely changes: two gradients and two Gaussian blobs of
    /// different size, so the alignment below has one clear optimum on both axes.
    private static func gradientAndBlobs(_ x: Int, _ y: Int) -> Px {
        let fx = Double(x), fy = Double(y)
        func blob(_ cx: Double, _ cy: Double, _ sigma: Double) -> Double {
            exp(-((fx - cx) * (fx - cx) + (fy - cy) * (fy - cy)) / (2 * sigma * sigma))
        }
        let r = 40 + 150 * fx / 600 + 50 * blob(260, 230, 10)
        let g = 60 + 120 * fy / 400
        let b = 60 + 140 * blob(330, 180, 20)
        return (UInt8(b.rounded()), UInt8(g.rounded()), UInt8(r.rounded()), 255)
    }

    /// PSNR of `reference` against `frame` sampled bilinearly at (x + dx, y + dy), over the pixels at least
    /// `margin` px inside the frame, every fourth pixel on both axes (the search below calls it 289 times a scale).
    private static func shiftedPSNR(_ frame: [UInt8], _ reference: [UInt8], width: Int, height: Int,
                                    dx: Double, dy: Double, margin: Int = 8) -> Double {
        var se = 0.0, n = 0.0
        for y in stride(from: margin, to: height - margin, by: 4) {
            for x in stride(from: margin, to: width - margin, by: 4) {
                let sx = Double(x) + dx, sy = Double(y) + dy
                let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                let ax = sx - Double(x0), ay = sy - Double(y0)
                for ch in 0..<3 {
                    func at(_ px: Int, _ py: Int) -> Double { Double(frame[(py * width + px) * 4 + ch]) }
                    let top = at(x0, y0) * (1 - ax) + at(x0 + 1, y0) * ax
                    let bottom = at(x0, y0 + 1) * (1 - ax) + at(x0 + 1, y0 + 1) * ax
                    let d = top * (1 - ay) + bottom * ay - Double(reference[(y * width + x) * 4 + ch])
                    se += d * d
                    n += 1
                }
            }
        }
        return se == 0 ? .infinity : 10 * log10(255 * 255 / (se / n))
    }

    @Test(TestLevel.fullOnly, arguments: [1.25, 2, 2.5, 4, 8]) func metalfxGeometry(scale: Double) async throws {
        // With a fractional pan the MetalFX frame lands where the Lanczos-3 frame does: the shift that aligns them
        // best, searched over ±2 view px in 0.25 steps, is within half a view px (spec §8). The view is centred near
        // the blue blob, so even at x8 (80 x 50 image px on screen) most of it is in the frame.
        let image = try await TiledImage.make(from: TestImages.synthetic(600, 400, pixel: Self.gradientAndBlobs))
        let t = Self.transform(image: (600, 400), .actual(scale), centre: (325.37, 178.71))
        let origin = t.viewPoint(forImage: .zero)
        #expect(origin.x != origin.x.rounded() && origin.y != origin.y.rounded())
        let fxRenderer = Self.renderer(ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0))
        let fx = try await Self.render(image, t, renderer: fxRenderer)
        #expect(fxRenderer.lastMode == .metalfx)
        let lanczos = try await Self.render(image, t, renderer: Self.renderer(Self.settings(.lanczos3)))

        var best = (dx: 0.0, dy: 0.0, psnr: -Double.infinity)
        for i in -8...8 {
            for j in -8...8 {
                let dx = Double(i) / 4, dy = Double(j) / 4
                let p = Self.shiftedPSNR(fx, lanczos, width: 640, height: 400, dx: dx, dy: dy)
                if p > best.psnr { best = (dx, dy, p) }
            }
        }
        // The search is biased toward half-pixel shifts: shifting the sharper MetalFX frame bilinearly also blurs it
        // toward Lanczos, which pays more than the misalignment costs. The centroid of the blue channel (a lone
        // Gaussian blob on a flat 60) has no such bias and pins the geometry tighter.
        func centroid(_ frame: [UInt8]) -> SIMD2<Double> {
            var sum = SIMD2<Double>(0, 0), weight = 0.0
            for y in 0..<400 {
                for x in 0..<640 {
                    let w = max(Double(frame[(y * 640 + x) * 4]) - 60, 0)
                    sum += w * SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                    weight += w
                }
            }
            return sum / weight
        }
        let drift = centroid(fx) - centroid(lanczos)
        #expect(abs(best.dx) <= 0.5 && abs(best.dy) <= 0.5, "x\(scale): best shift (\(best.dx), \(best.dy))")
        #expect(best.psnr >= 30, "x\(scale): \(best.psnr) dB at the best shift")
        #expect(abs(drift.x) <= 0.1 && abs(drift.y) <= 0.1, "x\(scale): centroid drift (\(drift.x), \(drift.y))")
    }

    @Test(arguments: [1.25, 8.0]) func metalfxReadsOnlyComposedTexels(scale: Double) async throws {
        // The compose pass writes only the content region and a margin (the input is not cleared): filling the rest
        // of the input with magenta between two frames must change nothing, so the scaler reads no texel beyond it.
        let image = try await TiledImage.make(from: TestImages.synthetic(600, 400, pixel: Self.gradientAndBlobs))
        let t = Self.transform(image: (600, 400), .actual(scale), centre: (300.37, 200.71))
        let r = Self.renderer(ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0))
        let a = try await Self.render(image, t, renderer: r)
        let input = try #require(r.metalFX?.input)
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = input
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = Self.magenta
        pass.colorAttachments[0].storeAction = .store
        try #require(commands.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let b = try await Self.render(image, t, renderer: r)
        var diff = 0
        for i in 0..<a.count where a[i] != b[i] { diff += 1 }
        #expect(diff == 0, "x\(scale): \(diff) bytes differ")
    }

    @Test func metalfxBackgroundOutside() async throws {
        // 200 x 100 at 2.5 covers 500 x 250 of a 641 x 403 view (odd, so the textures are not the size of an earlier
        // test's): every pixel whose centre is outside the image is exactly the background, as on the other paths, and
        // every pixel is written (the smooth picture never is pure green, noise could be by chance).
        let image = try await TiledImage.make(from: TestImages.synthetic(200, 100, pixel: Self.gradientAndBlobs))
        let t = Self.transform(image: (200, 100), view: (641, 403), .actual(2.5), centre: (100.37, 50.71))
        let renderer = Self.renderer(ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0))
        let frame = try await Self.render(image, t, renderer: renderer, prefill: MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1))
        #expect(renderer.lastMode == .metalfx)
        var wrong = 0, outside = 0, green = 0
        for y in 0..<403 {
            for x in 0..<641 {
                let p = Self.pixel(frame, width: 641, x, y)
                if p == (0, 255, 0, 255) { green += 1 }
                guard !Self.inside(t, x, y) else { continue }
                outside += 1
                if p != (255, 0, 255, 255) { wrong += 1 }
            }
        }
        #expect(outside > 641 * 403 / 3)
        #expect(wrong == 0)
        #expect(green == 0)
    }

    /// Pixels whose centre is inside the image rect that differ from `colour` by more than 2 levels on some channel,
    /// and how many inside pixels there are.
    private static func offColour(_ frame: [UInt8], _ t: ViewTransform, colour: Px) -> (off: Int, inside: Int) {
        var off = 0, inside = 0
        for y in 0..<400 {
            for x in 0..<640 where Self.inside(t, x, y) {
                inside += 1
                let p = Self.pixel(frame, width: 640, x, y)
                if abs(Int(p.b) - Int(colour.b)) > 2 || abs(Int(p.g) - Int(colour.g)) > 2
                    || abs(Int(p.r) - Int(colour.r)) > 2 { off += 1 }
            }
        }
        return (off, inside)
    }

    @Test(arguments: [2.5, 8.0]) func metalfxEdgeKeepsImageColour(scale: Double) async throws {
        // A uniform odd-size image smaller than the view, on black: every pixel inside the image rect keeps the
        // image's colour up to the edge, as the Lanczos-3 path (which clamps its reads into the level) does. The
        // background must not bleed in through the scaler's and the final pass's filters.
        let colour: Px = (160, 180, 200, 255)
        let image = try await TiledImage.make(from: TestImages.synthetic(61, 37) { _, _ in colour })
        let t = Self.transform(image: (61, 37), .actual(scale), centre: (30.37, 18.71))
        let black = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let fx = Self.renderer(ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0),
                               background: black)
        let frame = try await Self.render(image, t, renderer: fx)
        #expect(fx.lastMode == .metalfx)
        let lanczos = try await Self.render(image, t, renderer: Self.renderer(Self.settings(.lanczos3), background: black))
        let a = Self.offColour(frame, t, colour: colour), b = Self.offColour(lanczos, t, colour: colour)
        #expect(a.inside > 1000)
        #expect(b.off == 0, "lanczos3: \(b.off) of \(b.inside) inside pixels off the image colour")
        #expect(a.off == 0, "metalfx x\(scale): \(a.off) of \(a.inside) inside pixels off the image colour")
    }

    @Test func metalfxEdgeKeepsOverhangingLevelPixel() async throws {
        // 1001 x 601 with only level 1 resident (501 x 301, the last column and row overhanging the image by half a
        // level px) at 0.6: m 1.2 through MetalFX. The overhanging level px is image, not background, as on the
        // Lanczos-3 path.
        let colour: Px = (160, 180, 200, 255)
        let full = try await TiledImage.make(from: TestImages.synthetic(1001, 601) { _, _ in colour })
        let level1 = try await TestImages.readLevel(try #require(full.residentViews()[1]), grid: full.grid, level: 1)
        let preview = TiledImage.empty(grid: full.grid, colorSpace: full.colorSpace)
        try await preview.upload(LevelImage(image: level1, level: 1))
        #expect(preview.finestResidentLevel == 1)
        let t = Self.transform(image: (1001, 601), .actual(0.6), centre: (500.37, 300.71))
        let black = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let fx = Self.renderer(ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0),
                               background: black)
        let frame = try await Self.render(preview, t, renderer: fx)
        #expect(fx.lastMode == .metalfx && fx.lastLevel == 1)
        let a = Self.offColour(frame, t, colour: colour)
        #expect(a.inside > 1000)
        #expect(a.off == 0, "metalfx m 1.2 on level 1: \(a.off) of \(a.inside) inside pixels off the image colour")
    }

    @Test func metalfxReleasesTextures() async throws {
        // The scaler and its two view-size textures (~85 MB each on 6K) live only while frames use MetalFX.
        let image = try await TiledImage.make(from: TestImages.synthetic(600, 400, pixel: Self.gradientAndBlobs))
        let t = Self.transform(image: (600, 400), .actual(2.5))
        let renderer = Self.renderer(ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0))
        #expect(!renderer.holdsMetalFX)
        _ = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .metalfx)
        #expect(renderer.holdsMetalFX)
        renderer.resample = Self.settings(.lanczos3)
        _ = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .kernel(.lanczos3, upscale: true))
        #expect(!renderer.holdsMetalFX)
    }

    @Test func metalfxStageFailureDrawsLanczos() async throws {
        // When the scaler or its textures cannot be made for the view size, the frame draws Lanczos-3, and so does
        // the next one without a retry; a new size tries again.
        let image = try await TiledImage.make(from: TestImages.synthetic(600, 400, pixel: Self.gradientAndBlobs))
        let t = Self.transform(image: (600, 400), .actual(2.5), centre: (300.37, 200.71))
        let renderer = Self.renderer(ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0))
        renderer.failMetalFXStage = true
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == MetalContext.metalFXFallback && !renderer.holdsMetalFX)
        #expect(renderer.metalFXFailedSize == SIMD2(640, 400))
        let lanczos = try await Self.render(image, t, renderer: Self.renderer(Self.settings(.lanczos3)))
        #expect(frame == lanczos)
        renderer.failMetalFXStage = false
        _ = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == MetalContext.metalFXFallback && !renderer.holdsMetalFX)   // same size: no retry
        let other = Self.transform(image: (600, 400), view: (641, 403), .actual(2.5), centre: (300.37, 200.71))
        _ = try await Self.render(image, other, renderer: renderer)
        #expect(renderer.lastMode == .metalfx && renderer.holdsMetalFX && renderer.metalFXFailedSize == nil)
    }

    @Test func drawnModeFollowsTheFallbacks() {
        // What the stats line names: MetalFX unless the GPU has none or the last scaler could not be made.
        typealias C = MetalContext
        #expect(C.drawnMode(.metalfx, supported: true, stageFailed: false) == .metalfx)
        #expect(C.drawnMode(.metalfx, supported: false, stageFailed: false) == C.metalFXFallback)
        #expect(C.drawnMode(.metalfx, supported: true, stageFailed: true) == C.metalFXFallback)
        #expect(C.drawnMode(.kernel(.mitchell, upscale: true), supported: false, stageFailed: true)
                == .kernel(.mitchell, upscale: true))
    }

    @Test func metalfxUnsupportedDrawsLanczos() async throws {
        // A device without the spatial scaler draws Lanczos-3 instead, and lastMode says so.
        let image = try await TiledImage.make(from: TestImages.synthetic(600, 400, pixel: Self.gradientAndBlobs))
        let t = Self.transform(image: (600, 400), .actual(2.5), centre: (300.37, 200.71))
        let renderer = Self.renderer(ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0))
        renderer.metalFXSupported = false
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .kernel(.lanczos3, upscale: true))
        #expect(!renderer.holdsMetalFX)
        let lanczos = try await Self.render(image, t, renderer: Self.renderer(Self.settings(.lanczos3)))
        #expect(frame == lanczos)
    }

    @Test func antiringingClamps() async throws {
        // A dark/light step (sRGB 30 | 220) magnified 4x: Lanczos-3 over- and undershoots next to it, the clamp to
        // the four nearest texels keeps every value within the step's two levels.
        let (dark, light): (UInt8, UInt8) = (30, 220)
        let image = try await TiledImage.make(from: TestImages.synthetic(200, 100) { x, _ in
            let v = x < 100 ? dark : light
            return (v, v, v, 255)
        })
        let t = Self.transform(image: (200, 100), .actual(4), centre: (100.13, 50))
        let step = Int(t.viewPoint(forImage: CGPoint(x: 100, y: 0)).x)
        #expect(step > 100 && step < 540)

        func values(antiringing: Bool) async throws -> [Int] {
            let renderer = Self.renderer(Self.settings(.lanczos3, antiringing: antiringing))
            let frame = try await Self.render(image, t, renderer: renderer)
            #expect(renderer.lastMode == .kernel(.lanczos3, upscale: true))
            var result: [Int] = []
            for y in 0..<400 {
                for x in max(step - 24, 0)..<min(step + 24, 640) {
                    let p = Self.pixel(frame, width: 640, x, y)
                    result += [Int(p.b), Int(p.g), Int(p.r)]
                }
            }
            return result
        }
        let clamped = try await values(antiringing: true)
        #expect(clamped.allSatisfy { $0 >= Int(dark) && $0 <= Int(light) })
        let ringing = try await values(antiringing: false)
        #expect(ringing.contains { $0 <= Int(dark) - 2 || $0 >= Int(light) + 2 })
        print("antiringing: off \(ringing.min()!)...\(ringing.max()!), on \(clamped.min()!)...\(clamped.max()!)")
    }

    // MARK: EWA Lanczos (spec §3.7)

    /// `upscale = ewa-lanczos` with `upscale-high` and pixel-art off, so every magnifying frame takes the EWA path.
    private static func ewaSettings(antiringing: Bool = false) -> ResampleSettings {
        ResampleSettings(upscale: .ewaLanczos, upscaleHighPercent: 0, antiringing: antiringing, pixelArtPercent: 0)
    }

    /// The EWA reference frame for level 0 of `image` (magnified frames always draw level 0 here).
    private static func ewaReference(_ image: TiledImage, _ t: ViewTransform, pixel: @escaping (Int, Int) -> Px,
                                     antiringing: Bool = false, background: MTLClearColor = magenta) -> [UInt8] {
        let size = image.grid.levelSize(0), g = geometry(image, t, level: 0)
        let lin = ResampleReference.linear
        return ResampleReference.renderEWA(
            source: { x, y in let p = pixel(x, y); return (lin(p.r), lin(p.g), lin(p.b)) },
            width: size.width, height: size.height, m: g.m, offset: g.offset, extent: g.extent,
            viewWidth: Int(t.viewSize.width), viewHeight: Int(t.viewSize.height),
            background: (background.red, background.green, background.blue), antiringing: antiringing)
    }

    @Test(arguments: [2.5, 4.5]) func ewaMatchesReference(scale: Double) async throws {
        // Around the (512, 512) seam corner at a fractional pan: every tap window there spans two or four tiles.
        let image = try await TiledImage.make(from: TestImages.synthetic(1300, 900, pixel: TestImages.noiseAndEdges))
        let t = Self.transform(image: (1300, 900), .actual(scale), centre: (512.37, 512.71))
        let origin = t.viewPoint(forImage: .zero)
        #expect(origin.x != origin.x.rounded() && origin.y != origin.y.rounded())
        let renderer = Self.renderer(Self.ewaSettings())
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .ewaLanczos)
        #expect(renderer.lastLevel == 0)
        let expected = Self.ewaReference(image, t, pixel: TestImages.noiseAndEdges)
        let all = ResampleReference.psnr(frame, expected, width: 640)
        let seams = ResampleReference.psnr(frame, expected, width: 640, mask: Self.seamBands(image, t, level: 0))
        print("PSNR ewa-lanczos x\(scale): frame \(all) dB, seams \(seams) dB")
        #expect(all >= 55, "ewa x\(scale): frame \(all) dB")
        #expect(seams >= 55, "ewa x\(scale): seams \(seams) dB")
    }

    @Test func ewaExtremeZoom() async throws {
        // 64, the transform's limit: 10 x 6 level px on screen, one threadgroup's tap block is 7 x 7 texels.
        let image = try await TiledImage.make(from: TestImages.synthetic(600, 400, pixel: TestImages.noiseAndEdges))
        let t = Self.transform(image: (600, 400), .actual(64), centre: (300.37, 200.71))
        #expect(t.scale == 64)
        let renderer = Self.renderer(Self.ewaSettings())
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .ewaLanczos)
        let all = ResampleReference.psnr(frame, Self.ewaReference(image, t, pixel: TestImages.noiseAndEdges), width: 640)
        print("PSNR ewa-lanczos x64: frame \(all) dB")
        #expect(all >= 55, "ewa x64: \(all) dB")
    }

    @Test func ewaOddViewSize() async throws {
        // 641 x 403 (the last threadgroup column has 1 thread in the drawable, the last row 3) around a 200 x 100 image
        // at 2.5 (500 x 250 view px): every pixel written (no stray green), the background exact outside the image,
        // its edge texels clamped as in the reference.
        let image = try await TiledImage.make(from: TestImages.synthetic(200, 100, pixel: TestImages.noiseAndEdges))
        let t = Self.transform(image: (200, 100), view: (641, 403), .actual(2.5), centre: (100.37, 50.71))
        let renderer = Self.renderer(Self.ewaSettings())
        let frame = try await Self.render(image, t, renderer: renderer, prefill: MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1))
        #expect(renderer.lastMode == .ewaLanczos)
        let expected = Self.ewaReference(image, t, pixel: TestImages.noiseAndEdges)
        let all = ResampleReference.psnr(frame, expected, width: 641)
        let inside = ResampleReference.psnr(frame, expected, width: 641) { x, y in Self.inside(t, x, y) }
        print("PSNR ewa-lanczos odd view 641x403 x2.5: frame \(all) dB, image \(inside) dB")
        #expect(inside >= 55)
        // Clipped ringing on the noise can be pure green by chance (the separable path has one such pixel here), so
        // only a green the reference does not have counts as unwritten.
        var green = 0, wrong = 0, outside = 0
        for y in 0..<403 {
            for x in 0..<641 {
                let p = Self.pixel(frame, width: 641, x, y)
                if p == (0, 255, 0, 255), Self.pixel(expected, width: 641, x, y) != p { green += 1 }
                guard !Self.inside(t, x, y) else { continue }
                outside += 1
                if p != (255, 0, 255, 255) { wrong += 1 }
            }
        }
        #expect(outside > 641 * 403 / 3)
        #expect(wrong == 0 && green == 0)
    }

    @Test func ewaAntiringingMatchesReference() async throws {
        let image = try await TiledImage.make(from: TestImages.synthetic(1300, 900, pixel: TestImages.noiseAndEdges))
        let t = Self.transform(image: (1300, 900), .actual(2.5), centre: (512.37, 512.71))
        let renderer = Self.renderer(Self.ewaSettings(antiringing: true))
        let frame = try await Self.render(image, t, renderer: renderer)
        #expect(renderer.lastMode == .ewaLanczos)
        let all = ResampleReference.psnr(frame, Self.ewaReference(image, t, pixel: TestImages.noiseAndEdges, antiringing: true),
                                         width: 640)
        print("PSNR ewa-lanczos+antiring x2.5: frame \(all) dB")
        #expect(all >= 55, "ewa+antiring x2.5: \(all) dB")
    }

    @Test func ewaAntiringingClamps() async throws {
        // The dark/light step of antiringingClamps: EWA Lanczos rings next to it, the clamp to the four nearest texels
        // keeps every value within the step's two levels.
        let (dark, light): (UInt8, UInt8) = (30, 220)
        let image = try await TiledImage.make(from: TestImages.synthetic(200, 100) { x, _ in
            let v = x < 100 ? dark : light
            return (v, v, v, 255)
        })
        let t = Self.transform(image: (200, 100), .actual(4), centre: (100.13, 50))
        let step = Int(t.viewPoint(forImage: CGPoint(x: 100, y: 0)).x)
        #expect(step > 100 && step < 540)

        func values(antiringing: Bool) async throws -> [Int] {
            let renderer = Self.renderer(Self.ewaSettings(antiringing: antiringing))
            let frame = try await Self.render(image, t, renderer: renderer)
            #expect(renderer.lastMode == .ewaLanczos)
            var result: [Int] = []
            for y in 0..<400 {
                for x in max(step - 24, 0)..<min(step + 24, 640) {
                    let p = Self.pixel(frame, width: 640, x, y)
                    result += [Int(p.b), Int(p.g), Int(p.r)]
                }
            }
            return result
        }
        let clamped = try await values(antiringing: true)
        #expect(clamped.allSatisfy { $0 >= Int(dark) && $0 <= Int(light) })
        let ringing = try await values(antiringing: false)
        #expect(ringing.contains { $0 <= Int(dark) - 2 || $0 >= Int(light) + 2 })
        print("ewa antiringing: off \(ringing.min()!)...\(ringing.max()!), on \(clamped.min()!)...\(clamped.max()!)")
    }

    @Test func ewaLUTAccuracy() {
        // The table itself: linearly interpolated in Float over r² in [0, cutoff²], against the formula in double, at
        // 10 000 random r in [0, cutoff).
        let table = MetalContext.ewaWeightTable()
        #expect(table.count == MetalContext.ewaTableCount)
        let cutoff = ResampleReference.ewaCutoff
        #expect(abs(Double(MetalContext.ewaCutoffSquared) - cutoff * cutoff) < 1e-5)
        var generator = SystemRandomNumberGenerator()
        var worst = 0.0
        for _ in 0..<10_000 {
            let r = Double.random(in: 0..<cutoff, using: &generator)
            let t = Float(r * r) * (Float(table.count - 1) / MetalContext.ewaCutoffSquared)
            let i = min(Int(t), table.count - 2), f = t - Float(i)
            let lut = table[i] + (table[i + 1] - table[i]) * f
            worst = max(worst, abs(Double(lut) - ResampleReference.ewaWeight(r)))
        }
        print("EWA LUT (CPU interpolation): max abs error \(worst)")
        #expect(worst <= 1e-4)
        #expect(table[0] == 1 && table[table.count - 1] == 0)
    }

    @Test func ewaLUTAccuracyOnGPU() async throws {
        // What resampleEWA really gets: the texture sampler's linear filter (whose blend weight has limited precision)
        // at 10 000 random r in [0, cutoff), through the shader's own coordinate (ewaWeightProbe), against the formula.
        let c = MetalContext.shared
        #expect(c.supportsEWA)
        let cutoff = ResampleReference.ewaCutoff, count = 10_000
        var generator = SystemRandomNumberGenerator()
        let rs = (0..<count).map { _ in Double.random(in: 0..<cutoff, using: &generator) }
        let r2 = rs.map { Float($0 * $0) }
        let function = try #require(c.library.makeFunction(name: "ewaWeightProbe"))
        let pipeline = try await c.device.makeComputePipelineState(function: function)
        let input = try #require(c.device.makeBuffer(bytes: r2, length: count * 4, options: .storageModeShared))
        let output = try #require(c.device.makeBuffer(length: count * 4, options: .storageModeShared))
        let commands = try #require(c.queue.makeCommandBuffer())
        let encoder = try #require(commands.makeComputeCommandEncoder())
        var cutoff2 = MetalContext.ewaCutoffSquared, n = UInt32(count)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(c.ewaWeights, index: 0)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBytes(&cutoff2, length: 4, index: 2)
        encoder.setBytes(&n, length: 4, index: 3)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            commands.addCompletedHandler { _ in k.resume() }
            commands.commit()
        }
        let w = output.contents().assumingMemoryBound(to: Float.self)
        var worst = 0.0
        for i in 0..<count { worst = max(worst, abs(Double(w[i]) - ResampleReference.ewaWeight(rs[i]))) }
        print("EWA LUT (GPU texture filter): max abs error \(worst)")
        #expect(worst <= 1e-4)
    }

    @Test func ewaDrawnModeFallsBack() {
        // A GPU that cannot filter the weight table draws (and names) Lanczos-3.
        typealias C = MetalContext
        #expect(C.drawnMode(.ewaLanczos, supported: true, stageFailed: false, ewa: true) == .ewaLanczos)
        #expect(C.drawnMode(.ewaLanczos, supported: true, stageFailed: false, ewa: false) == C.metalFXFallback)
        #expect(C.drawnMode(.metalfx, supported: true, stageFailed: false, ewa: false) == .metalfx)
    }
}
