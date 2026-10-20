import CoreGraphics
import Foundation
import LoupeCore
import Metal
import Testing
@testable import LoupeRender

private typealias Px = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

private let viewSize = CGSize(width: 640, height: 400)

private func toLinear(_ v: UInt8) -> Double {
    let c = Double(v) / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

private func toSRGB(_ l: Double) -> Double {
    255 * (l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055)
}

/// A read-back render target.
private struct Frame {
    let bytes: [UInt8]
    let width: Int

    func px(_ x: Int, _ y: Int) -> Px {
        let o = (y * width + x) * 4
        return (bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3])
    }
}

private func same(_ a: Px, _ b: Px, tolerance: Int = 0) -> Bool {
    abs(Int(a.b) - Int(b.b)) <= tolerance && abs(Int(a.g) - Int(b.g)) <= tolerance
        && abs(Int(a.r) - Int(b.r)) <= tolerance && abs(Int(a.a) - Int(b.a)) <= tolerance
}

/// Encodes one frame into a fresh `bgra8Unorm_srgb` target of the transform's view size and reads it back.
/// The read-back blit goes to the same queue after the frame is committed, so it sees the finished frame.
private func render(_ image: TiledImage?, _ transform: ViewTransform,
                    renderer: TileRenderer = TileRenderer(pixelFormat: .bgra8Unorm_srgb)) async throws -> Frame {
    let target = TestImages.renderTarget(Int(transform.viewSize.width), Int(transform.viewSize.height))
    let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
    renderer.encode(image: image, transform: transform, into: commands, target: target)
    commands.commit()
    return Frame(bytes: try await TestImages.readTexture(target), width: target.width)
}

/// A renderer pinned to the bilinear fragment path, for the tests whose expectations are bilinear's (or that exercise
/// the instance buffers only the fragment path uses); the others run on the default (Lanczos-3) settings.
private func bilinearRenderer() -> TileRenderer {
    let renderer = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
    renderer.resample = ResampleSettings(upscale: .bilinear, downscale: .bilinear)
    return renderer
}

private func transform(_ size: (Int, Int), _ mode: ZoomMode, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> ViewTransform {
    ViewTransform(imageSize: CGSize(width: size.0, height: size.1), viewSize: viewSize, mode: mode, center: center)
}

@Test func actualSizeMatchesSource() async throws {
    let image = try await TiledImage.make(from: TestImages.synthetic(1100, 700))
    let t = transform((1100, 700), .actual(1))
    #expect(t.visibleRect.origin == CGPoint(x: 230, y: 150))
    let frame = try await render(image, t)
    #expect(same(frame.px(320, 200), TestImages.pattern(550, 350)))
    // Across the x = 512 tile seam (view x 281.5 samples image 511.5, view 282.5 samples 512.5).
    #expect(same(frame.px(281, 200), TestImages.pattern(511, 350)))
    #expect(same(frame.px(282, 200), TestImages.pattern(512, 350)))
    // A whole row and a whole column, crossing both seams: 100 % is a pixel-exact copy.
    var mismatches = 0
    for x in 0..<640 where !same(frame.px(x, 200), TestImages.pattern(x + 230, 350)) { mismatches += 1 }
    for y in 0..<400 where !same(frame.px(320, y), TestImages.pattern(550, y + 150)) { mismatches += 1 }
    #expect(mismatches == 0)
}

@Test func noSeamAtFit() async throws {
    let colour: Px = (40, 120, 200, 255)
    let image = try await TiledImage.make(from: TestImages.synthetic(1100, 700) { _, _ in colour })
    let t = transform((1100, 700), .fit)
    let frame = try await render(image, t)
    // Fit: 0.5714 view px per image px, image spans view x 5.7 ... 634.3 and the full height.
    let x0 = Int(t.viewPoint(forImage: .zero).x.rounded(.up)) + 1
    let x1 = Int(t.viewPoint(forImage: CGPoint(x: 1100, y: 700)).x.rounded(.down)) - 1
    var off = 0
    for y in 0..<400 {
        for x in x0..<x1 where !same(frame.px(x, y), colour, tolerance: 1) { off += 1 }
    }
    #expect(off == 0)
    #expect(same(frame.px(0, 200), (0, 0, 0, 255)) && same(frame.px(639, 200), (0, 0, 0, 255)))
}

@Test(arguments: [false, true])
func renderEdgeNoGarbage(bilinear: Bool) async throws {
    // An odd-sized image (the shape of a 13468×10100 grid scaled down) whose last `band` columns and rows are one
    // colour: any sample that strays into an edge tile's uninitialised apron shows up as a different value. The
    // bilinear fragment path (clamped to half a pixel inside the level) needs the apron's 8; the default Lanczos-3
    // reaches 6 level px from the sample point when reducing, 12 image px on level 1, so it gets 24.
    let (w, h) = (1347, 1010)
    let band = bilinear ? 8 : 24
    let edge: Px = (10, 200, 90, 255)
    let image = try await TiledImage.make(from: TestImages.synthetic(w, h) { x, y in
        x >= w - band || y >= h - band ? edge : TestImages.pattern(x, y)
    })
    let renderer = bilinear ? bilinearRenderer() : TileRenderer(pixelFormat: .bgra8Unorm_srgb)

    // Zoomed in and panned to the bottom-right: the image edge lands exactly on the view edge.
    let zoomed = transform((w, h), .free(1.7), center: CGPoint(x: 1, y: 1))
    #expect(TileGrid.level(forScale: zoomed.scale, levelCount: image.grid.levelCount) == 0)
    let corner = zoomed.viewPoint(forImage: CGPoint(x: w, y: h))
    #expect(abs(corner.x - 640) < 1e-6 && abs(corner.y - 400) < 1e-6)
    let a = try await render(image, zoomed, renderer: renderer)
    var bad = 0
    for y in 0..<400 where !same(a.px(639, y), edge, tolerance: 1) { bad += 1 }
    for x in 0..<640 where !same(a.px(x, 399), edge, tolerance: 1) { bad += 1 }
    #expect(bad == 0)

    // Zoomed out (level 1, whose 674×505 size overhangs the 1347×1010 image by half a level pixel): the last
    // pixels inside the image are the edge colour and everything past the image edge is background.
    let small = transform((w, h), .free(0.8), center: CGPoint(x: 1, y: 1))
    #expect(TileGrid.level(forScale: small.scale, levelCount: image.grid.levelCount) == 1)
    let b = try await render(image, small, renderer: renderer)
    let topLeft = small.viewPoint(forImage: .zero), bottomRight = small.viewPoint(forImage: CGPoint(x: w, y: h))
    let lastInX = Int(bottomRight.x.rounded(.down)) - 1, firstOutX = Int(bottomRight.x.rounded(.up))
    let lastInY = Int(bottomRight.y.rounded(.down)) - 1, firstOutY = Int(bottomRight.y.rounded(.up))
    bad = 0
    for y in Int(topLeft.y.rounded(.up))..<lastInY {
        if !same(b.px(lastInX, y), edge, tolerance: 1) { bad += 1 }
        if !same(b.px(firstOutX, y), (0, 0, 0, 255)) { bad += 1 }
    }
    for x in Int(topLeft.x.rounded(.up))..<lastInX {
        if !same(b.px(x, lastInY), edge, tolerance: 1) { bad += 1 }
        if !same(b.px(x, firstOutY), (0, 0, 0, 255)) { bad += 1 }
    }
    #expect(bad == 0)
}

@Test func letterboxBackground() async throws {
    let image = try await TiledImage.make(from: TestImages.synthetic(300, 200))
    let frame = try await render(image, transform((300, 200), .actual(1)))
    let black: Px = (0, 0, 0, 255)
    for (x, y) in [(0, 0), (639, 0), (0, 399), (639, 399)] { #expect(same(frame.px(x, y), black)) }
    // The image occupies view x 170 ..< 470, y 100 ..< 300.
    #expect(same(frame.px(169, 150), black) && same(frame.px(470, 299), black))
    #expect(same(frame.px(320, 99), black) && same(frame.px(320, 300), black))
    #expect(same(frame.px(170, 100), TestImages.pattern(0, 0)))
    #expect(same(frame.px(469, 299), TestImages.pattern(299, 199)))
}

@Test func backgroundColour() async throws {
    let renderer = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
    // No image: the target is just cleared.
    renderer.background = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
    let empty = try await render(nil, transform((300, 200), .fit), renderer: renderer)
    var wrong = 0
    for y in stride(from: 0, to: 400, by: 7) {
        for x in stride(from: 0, to: 640, by: 7) where !same(empty.px(x, y), (0, 0, 255, 255)) { wrong += 1 }
    }
    #expect(wrong == 0)
    // The clear colour is linear light, like the fragment output: 0.5 is stored as sRGB 188.
    renderer.background = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    let image = try await TiledImage.make(from: TestImages.synthetic(300, 200))
    let frame = try await render(image, transform((300, 200), .actual(1)), renderer: renderer)
    #expect(same(frame.px(0, 0), (188, 188, 188, 255), tolerance: 1))
    #expect(same(frame.px(170, 100), TestImages.pattern(0, 0)))
}

@Test func noSeamAtFractionalScaleAndOffset() async throws {
    // A ramp of 4 sRGB steps per image pixel around the x = 512 seam (0 below x = 480, 255 from x = 544).
    func ramp(_ x: Int) -> UInt8 { UInt8(min(max(4 * (x - 480), 0), 255)) }
    let image = try await TiledImage.make(from: TestImages.synthetic(1100, 64) { x, _ in
        let v = ramp(x)
        return (v, v, v, 255)
    })
    let s = 1.37
    let t = transform((1100, 64), .actual(s), center: CGPoint(x: 512.37 / 1100, y: 0.5))
    let ox = t.viewPoint(forImage: .zero).x
    #expect(ox != ox.rounded())                                   // the pan is fractional
    let seam = Int(t.viewPoint(forImage: CGPoint(x: 512, y: 0)).x)
    #expect(seam > 200 && seam < 440)
    let frame = try await render(image, t, renderer: bilinearRenderer())

    var values: [Int] = []
    var offExpected = 0
    for x in 0..<640 {
        let p = frame.px(x, 200)
        values.append(Int(p.g))
        // Expected: bilinear in linear light between the two nearest texels (centres at i + 0.5).
        let u = (Double(x) + 0.5 - ox) / s - 0.5
        let i = Int(u.rounded(.down)), f = u - Double(i)
        let lin = toLinear(ramp(min(max(i, 0), 1099))) * (1 - f) + toLinear(ramp(min(max(i + 1, 0), 1099))) * f
        if abs(Double(p.g) - toSRGB(lin)) > 2 { offExpected += 1 }
    }
    #expect(offExpected == 0)
    let step = Int((4 / s).rounded(.up))
    var nonMonotonic = 0, jumps = 0
    for x in 1..<640 {
        if values[x] < values[x - 1] { nonMonotonic += 1 }
        if values[x] - values[x - 1] > step + 2 { jumps += 1 }
    }
    #expect(nonMonotonic == 0)
    #expect(jumps == 0)
}

@Test func levelSelection() async throws {
    // Blue: 1 px stripes, which every level from 1 on averages (in linear light) to sRGB 188, while drawing
    // level 0 at 0.3 would alias them. Green: 2 px stripes, uniform only from level 2 on; at level 1 they
    // are single-pixel stripes again and drawing them at 0.6 view px per level px leaves a wide spread.
    let image = try await TiledImage.make(from: TestImages.synthetic(1100, 700) { x, _ in
        (x % 2 == 0 ? 255 : 0, x % 4 < 2 ? 255 : 0, 0, 255)
    })
    let t = transform((1100, 700), .actual(0.3))
    #expect(TileGrid.level(forScale: t.scale, levelCount: image.grid.levelCount) == 1)
    let frame = try await render(image, t, renderer: bilinearRenderer())
    let (blueOff, greenSpread) = stripeStats(frame)
    #expect(blueOff == 0)
    #expect(greenSpread > 150)
}

@Test func levelSelectionLanczos() async throws {
    // levelSelection's image and scale on the default filter: the kernel widened by 1/m filters level 1's single-pixel
    // green stripes before sampling them, so the aliasing bilinear shows is gone.
    let image = try await TiledImage.make(from: TestImages.synthetic(1100, 700) { x, _ in
        (x % 2 == 0 ? 255 : 0, x % 4 < 2 ? 255 : 0, 0, 255)
    })
    let t = transform((1100, 700), .actual(0.3))
    let renderer = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
    let frame = try await render(image, t, renderer: renderer)
    #expect(renderer.lastMode == .kernel(.lanczos3, upscale: false) && renderer.lastLevel == 1)
    let (blueOff, greenSpread) = stripeStats(frame)
    #expect(blueOff == 0)
    #expect(greenSpread <= 40)
}

/// levelSelection's measures inside the image (view x 155 ..< 485, y 95 ..< 305, a margin kept): blue pixels off
/// sRGB 188 by more than 2, and the spread of green.
private func stripeStats(_ frame: Frame) -> (blueOff: Int, greenSpread: Int) {
    var blueOff = 0, greenMin = 255, greenMax = 0
    for y in 100..<300 {
        for x in 160..<480 {
            let p = frame.px(x, y)
            if abs(Int(p.b) - 188) > 2 { blueOff += 1 }
            greenMin = min(greenMin, Int(p.g)); greenMax = max(greenMax, Int(p.g))
        }
    }
    return (blueOff, greenMax - greenMin)
}

@Test func instanceBufferRing() async throws {
    // Force the buffer path and encode more frames than the ring has buffers, each committed before the next
    // is encoded (as the render loop does), each panned differently so a reused stale buffer would show.
    let image = try await TiledImage.make(from: TestImages.synthetic(1100, 700))
    let renderer = bilinearRenderer()   // the compute path has no instances
    renderer.inlineInstanceLimit = 0
    var targets: [(MTLTexture, Int, Int)] = []
    for k in 0..<7 {
        let (ox, oy) = (10 + 60 * k, 10 + 40 * k)
        let t = transform((1100, 700), .actual(1),
                          center: CGPoint(x: Double(ox + 320) / 1100, y: Double(oy + 200) / 700))
        #expect(abs(t.visibleRect.minX - Double(ox)) < 1e-9 && abs(t.visibleRect.minY - Double(oy)) < 1e-9)
        let target = TestImages.renderTarget(640, 400)
        let commands = try #require(MetalContext.shared.queue.makeCommandBuffer())
        renderer.encode(image: image, transform: t, into: commands, target: target)
        commands.commit()
        targets.append((target, ox, oy))
    }
    #expect(renderer.bufferedFrameCount == 7)
    for (target, ox, oy) in targets {
        let frame = Frame(bytes: try await TestImages.readTexture(target), width: 640)
        var wrong = 0
        for y in stride(from: 0, to: 400, by: 13) {
            for x in stride(from: 0, to: 640, by: 13) where !same(frame.px(x, y), TestImages.pattern(x + ox, y + oy)) {
                wrong += 1
            }
        }
        #expect(wrong == 0, "frame at (\(ox), \(oy))")
    }
}

@Test func ringWaitsWhileTheGPUReadsEveryBuffer() async throws {
    // Three buffered frames whose command buffers are held on the GPU by an event: all three ring buffers are
    // in use, so a fourth frame must not be encoded (its instances would overwrite frame 1's) until one completes.
    let context = MetalContext.shared
    let image = try await TiledImage.make(from: TestImages.synthetic(1100, 700))
    let renderer = bilinearRenderer()   // the compute path has no instances
    renderer.inlineInstanceLimit = 0
    let gate = try #require(context.device.makeSharedEvent())
    let t = transform((1100, 700), .actual(1))
    for _ in 0..<3 {
        let commands = try #require(context.queue.makeCommandBuffer())
        commands.encodeWaitForEvent(gate, value: 1)
        renderer.encode(image: image, transform: t, into: commands, target: TestImages.renderTarget(640, 400))
        commands.commit()
    }
    let fourthEncoded = DispatchSemaphore(value: 0)
    let target = TestImages.renderTarget(640, 400)
    // Handed to one other thread while this one only waits: the renderer is used by one thread at a time. A thread of
    // its own, not a GCD global queue: those get no thread while other tests keep every core busy (the CPU resampling
    // reference does for half a minute), and the fourth frame would then start only after the 10 s below ran out.
    nonisolated(unsafe) let handedOver = renderer
    Thread {
        let commands = context.queue.makeCommandBuffer()!
        handedOver.encode(image: image, transform: t, into: commands, target: target)
        commands.commit()
        fourthEncoded.signal()
    }.start()
    #expect(fourthEncoded.wait(timeout: .now() + 0.3) == .timedOut)
    gate.signaledValue = 1
    #expect(fourthEncoded.wait(timeout: .now() + 10) == .success)
    let frame = Frame(bytes: try await TestImages.readTexture(target), width: 640)
    #expect(same(frame.px(320, 200), TestImages.pattern(550, 350)))
}

@Test func fallbackMatchesDownsampledFull() async throws {
    // A smooth image (no channel is ever 0 or 255 together), so a stretched coarse level stays close to level 0.
    let (w, h) = (3000, 2000)
    let smooth: (Int, Int) -> Px = { x, y in (UInt8(x / 12), UInt8(y / 8), 128, 255) }
    let a = try await TiledImage.make(from: TestImages.synthetic(w, h, pixel: smooth))
    let level2 = try await TestImages.readLevel(a.residentViews()[2]!, grid: a.grid, level: 2)
    let b = TiledImage.empty(grid: a.grid, colorSpace: a.colorSpace)
    try await b.upload(LevelImage(image: level2, level: 2))
    #expect(b.finestResidentLevel == 2)

    let renderer = TileRenderer(pixelFormat: .bgra8Unorm_srgb)
    renderer.background = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)   // magenta: never in the image
    let magenta: Px = (255, 0, 255, 255)

    // At 25 % both draw level 2, and B's level 2 is A's: the frames agree.
    let quarter = transform((w, h), .actual(0.25))
    #expect(TileGrid.level(forScale: quarter.scale, levelCount: a.grid.levelCount) == 2)
    let fa = try await render(a, quarter, renderer: renderer), fb = try await render(b, quarter, renderer: renderer)
    var differ = 0
    for y in 0..<400 { for x in 0..<640 where !same(fa.px(x, y), fb.px(x, y), tolerance: 1) { differ += 1 } }
    #expect(differ == 0)

    // At 100 % B has no level 0, so it stretches level 2 over the view: no hole, no seam at the level-2 tile
    // boundary (level x 512 = image x 2048, centred here), and close to A's true level 0.
    let actual = transform((w, h), .actual(1), center: CGPoint(x: 2048.5 / Double(w), y: 0.5))
    let seam = Int(actual.viewPoint(forImage: CGPoint(x: 2048, y: 0)).x)
    #expect(seam > 100 && seam < 540)
    let ga = try await render(a, actual, renderer: renderer), gb = try await render(b, actual, renderer: renderer)
    var holes = 0, far = 0
    for y in 0..<400 {
        for x in 0..<640 {
            if same(gb.px(x, y), magenta) { holes += 1 }
            if !same(ga.px(x, y), gb.px(x, y), tolerance: 2) { far += 1 }
        }
    }
    #expect(holes == 0)
    #expect(far == 0)
    var nonMonotonic = 0, jumps = 0
    for x in 1..<640 {
        let p = Int(gb.px(x, 200).b), q = Int(gb.px(x - 1, 200).b)
        if p < q { nonMonotonic += 1 }
        if p - q > 1 { jumps += 1 }
    }
    #expect(nonMonotonic == 0 && jumps == 0)
}
