import CoreGraphics
import Foundation
import ImageIO
import LoupeCore
import Metal
import Testing
import UniformTypeIdentifiers
@testable import LoupeRender

/// EXIF orientation in every drawing path (M3b spec §2.1): the stored pyramid drawn with an orientation against the
/// picture CoreGraphics orients, through the same reference filter; the image's edge on the magnifying paths; and
/// orientation 1 frames bit-identical to the renderer before orientation existed.
@Suite struct OrientationRendererTests {
    private typealias Px = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

    private static let magenta = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
    private static let black = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// Lanczos-3 both ways, `upscale-high` and pixel-art off.
    private static let lanczos = ResampleSettings(upscale: .kernel(.lanczos3), upscaleHighPercent: 0,
                                                  downscale: .kernel(.lanczos3), antiringing: false, pixelArtPercent: 0)
    private static let metalfx = ResampleSettings(upscale: .metalfx, upscaleHighPercent: 0, pixelArtPercent: 0)
    private static let ewa = ResampleSettings(upscale: .ewaLanczos, upscaleHighPercent: 0, pixelArtPercent: 0)
    private static let bilinear = ResampleSettings(upscale: .bilinear, downscale: .bilinear)
    /// The defaults with pixel art from 400 %: a frame at x4 of level 0 is nearest.
    private static var pixelArt: ResampleSettings {
        var s = ResampleSettings()
        s.pixelArtPercent = 400
        return s
    }

    private static func renderer(_ settings: ResampleSettings, background: MTLClearColor = magenta) -> TileRenderer {
        let r = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
        r.resample = settings
        r.background = background
        return r
    }

    /// A transform of the oriented picture (`size`, oriented px) centred on its point `centre`.
    private static func transform(_ size: PixelSize, view: (Int, Int) = (641, 403), _ mode: ZoomMode,
                                  centre: (Double, Double)) -> ViewTransform {
        ViewTransform(imageSize: CGSize(width: size.width, height: size.height),
                      viewSize: CGSize(width: view.0, height: view.1), mode: mode,
                      center: CGPoint(x: centre.0 / Double(size.width), y: centre.1 / Double(size.height)))
    }

    private static func render(_ image: TiledImage, _ t: ViewTransform, _ orientation: ImageOrientation,
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
        let a = t.viewPoint(forImage: .zero)
        let b = t.viewPoint(forImage: CGPoint(x: t.imageSize.width, y: t.imageSize.height))
        let cx = Double(x) + 0.5, cy = Double(y) + 0.5
        return cx >= a.x && cx < b.x && cy >= a.y && cy < b.y
    }

    /// The stored picture `pixel` (`width` x `height`) as CoreGraphics shows it with EXIF `orientation`: written as an
    /// sRGB TIFF with that tag, read back through `CGImageSourceCreateThumbnailWithTransform` at full size.
    private static func coreGraphicsOriented(_ width: Int, _ height: Int, _ orientation: ImageOrientation,
                                             pixel: (Int, Int) -> Px) throws -> DecodedImage {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        let source = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: srgb, bitmapInfo: info))
        let bytes = try #require(source.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixel(x, y), o = (y * width + x) * 4
                bytes[o] = p.r; bytes[o + 1] = p.g; bytes[o + 2] = p.b; bytes[o + 3] = 255
            }
        }
        let data = NSMutableData()
        let tiff = UTType.tiff.identifier as CFString
        let destination = try #require(CGImageDestinationCreateWithData(data, tiff, 1, nil))
        CGImageDestinationAddImage(destination, try #require(source.makeImage()),
                                   [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let file = try #require(CGImageSourceCreateWithData(data, nil))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        let image = try #require(CGImageSourceCreateThumbnailAtIndex(file, 0, options as CFDictionary))
        let size = orientation.orientedSize(PixelSize(width: width, height: height))
        #expect(image.width == size.width && image.height == size.height)
        let shown = try #require(CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                           bytesPerRow: size.width * 4, space: srgb, bitmapInfo: info))
        shown.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let oriented = try #require(shown.data).assumingMemoryBound(to: UInt8.self)
        return TestImages.synthetic(size.width, size.height) { x, y in
            let o = (y * size.width + x) * 4
            return (oriented[o + 2], oriented[o + 1], oriented[o], 255)
        }
    }

    /// The BGRA pixel function of a `DecodedImage`.
    private static func pixels(_ image: DecodedImage) -> (Int, Int) -> Px {
        let base = image.buffer.bytes.assumingMemoryBound(to: UInt8.self), stride = image.bytesPerRow
        let bytes = Array(UnsafeBufferPointer(start: base, count: stride * image.pixelSize.height))
        return { x, y in
            let o = y * stride + x * 4
            return (bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3])
        }
    }

    // MARK: Against CoreGraphics

    /// PSNR of the renderer's Lanczos-3 frame of `stored` noise drawn with `orientation` at `scale` (fractional pan,
    /// odd 641 x 403 view) against the CPU reference over what CoreGraphics shows: the drawn level as stored (level 0
    /// the picture, a coarser one read back from the pyramid), turned through CoreGraphics' EXIF orientation, through
    /// the same `ResampleReference` Lanczos-3. An odd-size level mirrored about the image's extent starts half a level
    /// px before the image on that axis, which the reference's `phase` gives it.
    private static func psnrAgainstCoreGraphics(_ orientation: ImageOrientation, stored: (Int, Int), scale: Double,
                                                level expectedLevel: Int, antiringing: Bool = false) async throws
        -> Double {
        let (width, height) = stored, view = (641, 403)
        let size = orientation.orientedSize(PixelSize(width: width, height: height))
        let picture = TestImages.synthetic(width, height, pixel: TestImages.noiseAndEdges)
        let image = try await TiledImage.make(from: picture)
        let centre = (Double(size.width) * 0.41 + 0.37, Double(size.height) * 0.56 + 0.71)
        let t = Self.transform(size, view: view, .actual(scale), centre: centre)
        let origin = t.viewPoint(forImage: .zero)
        let level = image.grid.drawnLevel(forScale: t.scale, finestResident: 0)
        #expect(level == expectedLevel)

        var settings = Self.lanczos
        settings.antiringing = antiringing
        let renderer = Self.renderer(settings)
        let frame = try await Self.render(image, t, orientation, renderer: renderer)
        #expect(renderer.lastMode == .kernel(.lanczos3, upscale: scale > 1) && renderer.lastLevel == level)

        let levelSize = image.grid.levelSize(level)
        var storedLevel: (Int, Int) -> Px = TestImages.noiseAndEdges
        if level > 0 {
            let view = try #require(image.residentViews()[level])
            storedLevel = Self.pixels(try await TestImages.readLevel(view, grid: image.grid, level: level))
        }
        let shown = Self.pixels(try Self.coreGraphicsOriented(levelSize.width, levelSize.height, orientation,
                                                              pixel: storedLevel))
        let factor = Double(1 << level), f = { (v: Double) in Double(Float(v)) }
        // Oriented x runs along stored x when a != 0 (sign a), else along stored y (sign c); oriented y along stored x
        // when b != 0 (sign b), else along stored y (sign d). On a mirrored stored axis the level's px grid starts
        // levelSize - extent before the image.
        let m = orientation.matrix
        let overhang = (Double(levelSize.width) - Double(width) / factor,
                        Double(levelSize.height) - Double(height) / factor)
        func phase(_ alongX: Int, _ alongY: Int) -> Double {
            alongX != 0 ? (alongX < 0 ? overhang.0 : 0) : (alongY < 0 ? overhang.1 : 0)
        }
        let lin = ResampleReference.linear, oriented = orientation.orientedSize(levelSize)
        let expected = ResampleReference.render(
            source: { x, y in let p = shown(x, y); return (lin(p.r), lin(p.g), lin(p.b)) },
            width: oriented.width, height: oriented.height, kernel: .lanczos3, m: f(t.scale * factor),
            offset: SIMD2(f(origin.x), f(origin.y)),
            extent: SIMD2(f(Double(size.width) / factor), f(Double(size.height) / factor)),
            viewWidth: view.0, viewHeight: view.1, background: (1, 0, 1),
            phase: SIMD2(phase(m.a, m.c), phase(m.b, m.d)), antiringing: antiringing)
        return ResampleReference.psnr(frame, expected, width: view.0)
    }

    @Test(TestLevel.fullOnly, arguments: ImageOrientation.allCases, [0.37, 1, 2.5])
    func orientedFrameMatchesCoreGraphics(orientation: ImageOrientation, scale: Double) async throws {
        // 1300 x 900 stored (3 x 2 tiles, so turned frames cross seams on the other axis), drawn turned into an odd
        // 641 x 403 view at a fractional pan. At 0.37 the frame draws level 1.
        let size = orientation.orientedSize(PixelSize(width: 1300, height: 900))
        let centre = (Double(size.width) * 0.41 + 0.37, Double(size.height) * 0.56 + 0.71)
        let origin = Self.transform(size, .actual(scale), centre: centre).viewPoint(forImage: .zero)
        // A fractional pan; at 0.37 the picture is smaller than the view and centred at a whole px, where m = 0.74
        // still puts the sample points between level px.
        #expect(scale < 0.5 || origin.x != origin.x.rounded() && origin.y != origin.y.rounded())
        let all = try await Self.psnrAgainstCoreGraphics(orientation, stored: (1300, 900), scale: scale,
                                                         level: scale < 0.5 ? 1 : 0)
        print("PSNR orientation \(orientation.rawValue) x\(scale): \(all) dB")
        #expect(all >= 40, "orientation \(orientation.rawValue) x\(scale): \(all) dB")
    }

    @Test(arguments: ImageOrientation.allCases)
    func orientedSmallFrameMatchesCoreGraphics(orientation: ImageOrientation) async throws {
        // 151 x 97 at x2.5 is 377.5 x 242.5 view px either way round, inside the 641 x 403 view: all four image edges
        // are in the frame, where the taps clamp at the level's edge and the background starts at the image's.
        let all = try await Self.psnrAgainstCoreGraphics(orientation, stored: (151, 97), scale: 2.5, level: 0)
        print("PSNR orientation \(orientation.rawValue) 151x97 x2.5 (edges in view): \(all) dB")
        #expect(all >= 40, "orientation \(orientation.rawValue): \(all) dB")
    }

    @Test(arguments: [ImageOrientation.leftMirrored, .right, .rightMirrored, .left])
    func oddLevelTurnedMatchesCoreGraphics(orientation: ImageOrientation) async throws {
        // 1301 x 903 at 0.37 draws level 1, 651 x 452 px whose last column and row overhang the image by half a px;
        // turned, the mirrored stored axis (both for 7) runs from that overhang, half a level px before the image.
        let all = try await Self.psnrAgainstCoreGraphics(orientation, stored: (1301, 903), scale: 0.37, level: 1)
        print("PSNR orientation \(orientation.rawValue) 1301x903 x0.37 L1: \(all) dB")
        #expect(all >= 40, "orientation \(orientation.rawValue): \(all) dB")
    }

    @Test(arguments: [ImageOrientation.upMirrored, .right, .rightMirrored])
    func orientedAntiringingMatchesCoreGraphics(orientation: ImageOrientation) async throws {
        // lanczos-antiring at x2.5: the clamp's 2 x 2 neighbourhood is taken on the stored axes, which must be the
        // oriented picture's 2 x 2 turned (mirrored, rotated, and both).
        let all = try await Self.psnrAgainstCoreGraphics(orientation, stored: (1300, 900), scale: 2.5, level: 0,
                                                         antiringing: true)
        print("PSNR orientation \(orientation.rawValue) x2.5 antiringing: \(all) dB")
        #expect(all >= 40, "orientation \(orientation.rawValue): \(all) dB")
    }

    @Test(TestLevel.fullOnly, arguments: ImageOrientation.allCases)
    func orientedPathsMatchTheOrientedPicture(orientation: ImageOrientation) async throws {
        // The other paths, against the same frame of the picture CoreGraphics orients drawn as stored: bilinear tiles
        // (zoomed out, so tile selection in stored coordinates matters: part of the picture is off screen), nearest
        // (exact: the same level px under every pixel centre), EWA Lanczos (radial, so the same taps up to summation
        // order) and MetalFX (the composed input is the oriented picture's, so the frame is the same to the bit).
        let stored = PixelSize(width: 1300, height: 900), size = orientation.orientedSize(stored)
        let image = try await TiledImage.make(from: TestImages.synthetic(1300, 900, pixel: TestImages.noiseAndEdges))
        let upright = try await TiledImage.make(from: try Self.coreGraphicsOriented(1300, 900, orientation,
                                                                                     pixel: TestImages.noiseAndEdges))
        let centre = (Double(size.width) * 0.41 + 0.37, Double(size.height) * 0.56 + 0.71)
        let cases: [(String, ResampleSettings, Double, ResampleMode, Double)] = [
            ("bilinear", Self.bilinear, 0.66, .bilinear, 50),
            ("nearest", Self.pixelArt, 4, .nearest, .infinity),
            ("ewa-lanczos", Self.ewa, 2.5, .ewaLanczos, 55),
            ("metalfx", Self.metalfx, 2.5, .metalfx, .infinity),
        ]
        for (name, settings, scale, mode, floor) in cases {
            let t = Self.transform(size, .actual(scale), centre: centre)
            let r = Self.renderer(settings)
            let frame = try await Self.render(image, t, orientation, renderer: r)
            #expect(r.lastMode == mode, "\(name)")
            let expected = try await Self.render(upright, t, .up, renderer: Self.renderer(settings))
            let psnr = ResampleReference.psnr(frame, expected, width: 641)
            print("PSNR orientation \(orientation.rawValue) \(name) x\(scale) vs oriented picture: \(psnr) dB")
            #expect(psnr >= floor, "orientation \(orientation.rawValue) \(name): \(psnr) dB")
        }
    }

    @Test(arguments: [ImageOrientation.down, .upMirrored, .downMirrored])
    func mirroredOddLevelMirrorsAboutTheImage(orientation: ImageOrientation) async throws {
        // 1301 x 903 at 0.3 draws level 1, 651 x 452 px of which the last column and row overhang the image by half a
        // level px. Mirrored about the image's extent (not the level's edge), the centred frame is the as-stored frame
        // mirrored in the view: the same stored position under every mirrored pixel. About the level's edge it would
        // be half a level px off.
        let image = try await TiledImage.make(from: TestImages.synthetic(1301, 903, pixel: TestImages.noiseAndEdges))
        let t = ViewTransform(imageSize: CGSize(width: 1301, height: 903), viewSize: CGSize(width: 640, height: 400),
                              mode: .actual(0.3))
        let frame = try await Self.render(image, t, orientation, renderer: Self.renderer(Self.lanczos))
        let up = try await Self.render(image, t, .up, renderer: Self.renderer(Self.lanczos))
        let m = orientation.matrix
        var mirrored = [UInt8](repeating: 0, count: up.count)
        for y in 0..<400 {
            for x in 0..<640 {
                let sx = m.a < 0 ? 639 - x : x, sy = m.d < 0 ? 399 - y : y
                for ch in 0..<4 { mirrored[(y * 640 + x) * 4 + ch] = up[(sy * 640 + sx) * 4 + ch] }
            }
        }
        let psnr = ResampleReference.psnr(frame, mirrored, width: 640)
        print("PSNR orientation \(orientation.rawValue) L1 odd size vs mirrored frame: \(psnr) dB")
        #expect(psnr >= 50, "orientation \(orientation.rawValue): \(psnr) dB")
    }

    @Test(arguments: [ImageOrientation.down, .right, .rightMirrored])
    func mirroredOddLevelMetalFXLandsWithLanczos(orientation: ImageOrientation) async throws {
        // MetalFX composes whole stored px, whose grid on a mirrored axis of an odd-size level 1 starts half a level px
        // before the image (the overhang): with only level 1 resident (a preview), at m 1.2, the frame must still land
        // where the Lanczos-3 one does. A lone Gaussian blob in blue pins the geometry: its centroids agree within
        // 0.1 view px (half a level px off would be 0.6).
        let full = try await TiledImage.make(from: TestImages.synthetic(1001, 601) { x, y in
            let dx = Double(x) - 520, dy = Double(y) - 280
            let b = 60 + 160 * exp(-(dx * dx + dy * dy) / (2 * 40 * 40))
            return (UInt8(b.rounded()), 90, 120, 255)
        })
        let level1 = try await TestImages.readLevel(try #require(full.residentViews()[1]), grid: full.grid, level: 1)
        let preview = TiledImage.empty(grid: full.grid, colorSpace: full.colorSpace)
        try await preview.upload(LevelImage(image: level1, level: 1))
        let size = orientation.orientedSize(PixelSize(width: 1001, height: 601))
        let t = Self.transform(size, view: (640, 400), .actual(0.6), centre: (Double(size.width) / 2 + 0.37,
                                                                              Double(size.height) / 2 + 0.71))
        let fx = Self.renderer(Self.metalfx, background: Self.black)
        let a = try await Self.render(preview, t, orientation, renderer: fx)
        #expect(fx.lastMode == .metalfx && fx.lastLevel == 1)
        let lanczos = Self.renderer(Self.lanczos, background: Self.black)
        let b = try await Self.render(preview, t, orientation, renderer: lanczos)
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
        let drift = centroid(a) - centroid(b)
        print("metalfx orientation \(orientation.rawValue) L1 odd size: centroid drift \(drift)")
        #expect(abs(drift.x) <= 0.1 && abs(drift.y) <= 0.1, "orientation \(orientation.rawValue): drift \(drift)")
    }

    // MARK: Edges (Review Focus 2)

    @Test(TestLevel.fullOnly, arguments: [ImageOrientation.down, .right, .rightMirrored], ["metalfx", "nearest", "ewa-lanczos", "lanczos3"])
    func orientedEdgesHaveNoFringe(orientation: ImageOrientation, path: String) async throws {
        // A uniform odd-size picture smaller than the view, turned, at x4 on black: every pixel whose centre is inside
        // the oriented image rect keeps the picture's colour (no background filtered in, no half-pixel shift of the
        // edge), every pixel whose centre is outside is the background exactly.
        let colour: Px = (160, 180, 200, 255)
        let image = try await TiledImage.make(from: TestImages.synthetic(61, 37) { _, _ in colour })
        let size = orientation.orientedSize(PixelSize(width: 61, height: 37))
        let t = Self.transform(size, view: (640, 400), .actual(4), centre: (Double(size.width) / 2 + 0.37,
                                                                            Double(size.height) / 2 + 0.29))
        let settings = ["metalfx": Self.metalfx, "nearest": Self.pixelArt, "ewa-lanczos": Self.ewa][path]
            ?? Self.lanczos
        let r = Self.renderer(settings, background: Self.black)
        let frame = try await Self.render(image, t, orientation, renderer: r)
        let mode: ResampleMode = ["metalfx": .metalfx, "nearest": .nearest, "ewa-lanczos": .ewaLanczos][path]
            ?? .kernel(.lanczos3, upscale: true)
        #expect(r.lastMode == mode)
        var off = 0, inside = 0, fringe = 0, edge = 0
        for y in 0..<400 {
            for x in 0..<640 {
                let p = Self.pixel(frame, width: 640, x, y)
                if Self.inside(t, x, y) {
                    inside += 1
                    if abs(Int(p.b) - Int(colour.b)) > 2 || abs(Int(p.g) - Int(colour.g)) > 2
                        || abs(Int(p.r) - Int(colour.r)) > 2 { off += 1 }
                } else {
                    if p != (0, 0, 0, 255) { fringe += 1 }
                    // A pixel just outside: a neighbour is inside.
                    let neighbours = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                    if neighbours.contains(where: { Self.inside(t, $0.0, $0.1) }) { edge += 1 }
                }
            }
        }
        #expect(inside > 1000 && edge > 4 * (size.width + size.height))
        #expect(off == 0, "orientation \(orientation.rawValue) \(path): \(off) of \(inside) inside pixels off colour")
        #expect(fringe == 0, "orientation \(orientation.rawValue) \(path): \(fringe) outside pixels not background")
    }

    @Test(arguments: ImageOrientation.allCases)
    func orientedPixelArtIsExact(orientation: ImageOrientation) async throws {
        // 200 x 150 at 400 % with a fractional pan: every view pixel is exactly the stored pixel under its centre's
        // stored point (squares stay squares, nothing blends), and pixels outside the picture are background.
        let image = try await TiledImage.make(from: TestImages.synthetic(200, 150))
        let size = orientation.orientedSize(PixelSize(width: 200, height: 150))
        let t = Self.transform(size, view: (640, 400), .actual(4), centre: (Double(size.width) / 2 + 0.37,
                                                                            Double(size.height) / 2 + 0.71))
        let r = Self.renderer(Self.pixelArt)
        let frame = try await Self.render(image, t, orientation, renderer: r)
        #expect(r.lastMode == .nearest)
        let origin = t.viewPoint(forImage: .zero), storedSize = CGSize(width: 200, height: 150)
        var wrong = 0, covered = 0
        for y in 0..<400 {
            for x in 0..<640 {
                // The oriented level px under the centre, mapped to stored by its centre.
                let u = CGPoint(x: ((Double(x) + 0.5 - origin.x) / 4).rounded(.down) + 0.5,
                                y: ((Double(y) + 0.5 - origin.y) / 4).rounded(.down) + 0.5)
                let s = orientation.storedPoint(u, storedSize: storedSize)
                let sx = Int(s.x.rounded(.down)), sy = Int(s.y.rounded(.down))
                let p = Self.pixel(frame, width: 640, x, y)
                if Self.inside(t, x, y) {
                    covered += 1
                    if p != TestImages.pattern(sx, sy) { wrong += 1 }
                } else if p != (255, 0, 255, 255) { wrong += 1 }
            }
        }
        #expect(covered > 640 * 400 / 2)
        #expect(wrong == 0, "orientation \(orientation.rawValue): \(wrong) pixels")
    }

    @Test(arguments: ImageOrientation.allCases, [5, 10.25])
    func pixelArtTiesFallInOrientedSpace(orientation: ImageOrientation, scale: Double) async throws {
        // 61 x 37 at 500 % centred in 640 x 400: the picture starts at view x 167.5 (227.5 turned) and y 107.5 (47.5),
        // so every block edge falls exactly on a view px centre, a tie. 36 x 28 at 1025 % starts at 135.5 / 56.5
        // (176.5 / 15.5 turned), every fourth edge a tie, and there 1 / m rounds k·m / m below k (k = 4, 8, ...).
        // Chosen in oriented space, every orientation draws the very frame `.up` draws of the picture as it shows it,
        // and block k spans the view px whose centre's oriented position has floor k exactly (5 px each at 500 %,
        // 10 or 11 at 1025 %), across a row and down a column. Floored in stored space, a mirrored axis would break
        // each tie the other way (a 6 px first block at 500 %).
        let stored = scale == 5 ? (61, 37) : (36, 28)
        let image = try await TiledImage.make(from: TestImages.synthetic(stored.0, stored.1))
        let size = orientation.orientedSize(PixelSize(width: stored.0, height: stored.1))
        let storedSize = CGSize(width: stored.0, height: stored.1)
        let shown = try await TiledImage.make(from: TestImages.synthetic(size.width, size.height) { x, y in
            let s = orientation.storedPoint(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), storedSize: storedSize)
            return TestImages.pattern(Int(s.x.rounded(.down)), Int(s.y.rounded(.down)))
        })
        let t = ViewTransform(imageSize: CGSize(width: size.width, height: size.height),
                              viewSize: CGSize(width: 640, height: 400), mode: .actual(scale))
        let origin = t.viewPoint(forImage: .zero)
        #expect(origin.x - origin.x.rounded(.down) == 0.5 && origin.y - origin.y.rounded(.down) == 0.5)
        let r = Self.renderer(Self.pixelArt)
        let frame = try await Self.render(image, t, orientation, renderer: r)
        #expect(r.lastMode == .nearest)
        let up = try await Self.render(shown, t, .up, renderer: Self.renderer(Self.pixelArt))

        /// The widths of the runs of equal pixels along view row y (or column x) inside the picture.
        func blocks(_ f: [UInt8], row y: Int? = nil, column x: Int? = nil) -> [Int] {
            var widths: [Int] = [], last: Px?
            for i in 0..<(y != nil ? 640 : 400) {
                let (px, py) = y != nil ? (i, y!) : (x!, i)
                guard Self.inside(t, px, py) else { continue }
                let p = Self.pixel(f, width: 640, px, py)
                if let l = last, l == p { widths[widths.count - 1] += 1 } else { widths.append(1) }
                last = p
            }
            return widths
        }
        /// Block k: the view px v with k <= (v + 0.5 - start) / m < k + 1 (exact in Double: start and m are dyadic).
        func expected(_ count: Int, start: Double) -> [Int] {
            let first = { (k: Int) in Int((start + Double(k) * scale - 0.5).rounded(.up)) }
            return (0..<count).map { k in first(k + 1) - first(k) }
        }
        let row = blocks(frame, row: 200), column = blocks(frame, column: 320)
        print("pixel-art ties orientation \(orientation.rawValue) x\(scale): row \(row), column \(column)")
        #expect(row == blocks(up, row: 200) && column == blocks(up, column: 320))
        #expect(row == expected(size.width, start: origin.x), "orientation \(orientation.rawValue): row \(row)")
        #expect(column == expected(size.height, start: origin.y),
                "orientation \(orientation.rawValue): column \(column)")
        #expect(frame == up, "orientation \(orientation.rawValue): frame differs from .up of the shown picture")
    }

    // MARK: Orientation 1 unchanged

    /// FNV-1a over a frame's bytes.
    private static func fnv(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0100_0000_01b3 }
    }

    @Test func orientationUpIsUnchanged() async throws {
        // Orientation 1 frames of every path are the bytes the renderer drew before orientation existed (commit
        // 260f466): hashes recorded there on this Mac (Apple M4 Max; another GPU or a new macOS may round MetalFX or
        // the sRGB encode differently, then re-record them from that commit). 1300 x 900 noise in an odd 641 x 403
        // view at a fractional pan (centred, smaller than the view, at 0.37).
        let image = try await TiledImage.make(from: TestImages.synthetic(1300, 900, pixel: TestImages.noiseAndEdges))
        let lanczosAntiring = ResampleSettings(upscale: .kernel(.lanczos3), upscaleHighPercent: 0, antiringing: true,
                                               pixelArtPercent: 0)
        let cases: [(String, ResampleSettings, Double, UInt64)] = [
            ("bilinear", Self.bilinear, 0.66, 0xf9fa_8747_8226_8081),
            ("lanczos3 down", Self.lanczos, 0.66, 0xfada_ef82_ddd8_c2df),
            ("lanczos3 down, level 1", Self.lanczos, 0.37, 0xdc97_12fc_9223_5cc2),
            ("lanczos3 up", Self.lanczos, 2.5, 0x91e3_990d_b070_5f31),
            ("lanczos3 up, antiringing", lanczosAntiring, 2.5, 0xbbb0_b6ea_6397_1f83),
            ("nearest", Self.pixelArt, 4, 0x0d1e_62d7_8c10_ee80),
            ("ewa-lanczos", Self.ewa, 2.5, 0x47e1_6844_7388_4283),
            ("metalfx", Self.metalfx, 2.5, 0x78ac_bcd3_4e56_4bc2),
        ]
        for (name, settings, scale, hash) in cases {
            let t = Self.transform(PixelSize(width: 1300, height: 900), .actual(scale), centre: (512.37, 450.71))
            let frame = try await Self.render(image, t, .up, renderer: Self.renderer(settings))
            #expect(Self.fnv(frame) == hash, "\(name): 0x\(String(Self.fnv(frame), radix: 16))")
        }
    }
}
