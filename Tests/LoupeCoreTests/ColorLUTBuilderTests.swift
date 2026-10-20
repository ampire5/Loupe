import Testing
import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import LoupeCore

private let last = ColorCube.dimension - 1

/// Settings with auto colour on and the ramp out of the way (threshold 0: every photo gets the whole strength).
private func settings(auto: Bool = true, method: AutoColorMethod = .apple, strength: Double = 1,
                      filters: Set<AutoColorFilter> = Set(AutoColorFilter.allCases), threshold: Double = 0,
                      full: Double = 0, vibrance: Bool = false, amount: Double = 0.5) -> ColorSettings {
    ColorSettings(autoColor: auto, method: method, strength: strength, filters: filters, vibranceGain: 1,
                  threshold: threshold, full: full, vibrance: vibrance, vibranceAmount: amount)
}

/// Typical values of Apple's analysis (the M3c probe): vibrance, a contrast curve, shadows 0.15 with radius 0.
private let typicalSteps = [
    AutoColorStep(name: "CIVibrance", kind: .vibrance, parameters: [kCIInputAmountKey: NSNumber(value: 0.1)]),
    AutoColorStep(name: "CIToneCurve", kind: .curve, parameters: [
        "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.21),
        "inputPoint2": CIVector(x: 0.5, y: 0.52), "inputPoint3": CIVector(x: 0.75, y: 0.8),
        "inputPoint4": CIVector(x: 1, y: 1)]),
    AutoColorStep(name: "CIHighlightShadowAdjust", kind: .shadows, parameters: [
        "inputShadowAmount": NSNumber(value: 0.15), "inputHighlightAmount": NSNumber(value: 1),
        kCIInputRadiusKey: NSNumber(value: 0)]),
]

private func typical(delta: Double = 10, tooDark: Bool = false) -> AutoColorAnalysis {
    AutoColorAnalysis(steps: tooDark ? [] : typicalSteps, delta: tooDark ? 0 : delta, tooDark: tooDark)
}

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// A generated 8-bit image in `space`: `pixel(x, y)` gives 0...255 R, G, B.
private func makeImage(width: Int, height: Int, space: CGColorSpace,
                       _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            let i = (y * width + x) * 4
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
        }
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

/// Low contrast, low saturation, a slight warm tint: what Apple's analysis has something to do with.
private func dullImage(_ space: CGColorSpace) -> CGImage {
    makeImage(width: 128, height: 128, space: space) { x, y in
        let base = 90 + 70 * Double(x) / 127
        return (UInt8(base + 12), UInt8(base + 4 + 6 * Double(y) / 127), UInt8(base - 8))
    }
}

/// A node as stored: sRGB-encoded.
private func node(_ cube: ColorCube, _ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
    let n = ColorCube.dimension, i = ((b * n + g) * n + r) * 4
    return SIMD3(Float(cube.values[i]), Float(cube.values[i + 1]), Float(cube.values[i + 2]))
}

private func decode(_ e: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(ColorCurve.srgb.decode(e.x), ColorCurve.srgb.decode(e.y), ColorCurve.srgb.decode(e.z))
}

/// A node as light: linear in the photo's primaries.
private func light(_ cube: ColorCube, _ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { decode(node(cube, r, g, b)) }

/// The CPU reference of the renderer (M3c spec §4.1): linear light in the photo's primaries, sRGB-encoded, looked up
/// trilinearly among the encoded nodes, then decoded once; the result is linear light in the same primaries.
private func lookUp(_ cube: ColorCube, _ e: SIMD3<Float>) -> SIMD3<Float> {
    let p = e * Float(last)
    let i = SIMD3<Int>(Int(min(p.x, Float(last - 1))), Int(min(p.y, Float(last - 1))), Int(min(p.z, Float(last - 1))))
    let f = p - SIMD3<Float>(Float(i.x), Float(i.y), Float(i.z))
    var result = SIMD3<Float>(repeating: 0)
    for corner in 0..<8 {
        let dr = corner & 1, dg = (corner >> 1) & 1, db = (corner >> 2) & 1
        let weight = (dr == 1 ? f.x : 1 - f.x) * (dg == 1 ? f.y : 1 - f.y) * (db == 1 ? f.z : 1 - f.z)
        result += weight * node(cube, i.x + dr, i.y + dg, i.z + db)
    }
    return decode(result)
}

/// 0...255 levels of `image` drawn through `cube` (the CPU reference).
private func throughCube(_ image: CGImage, _ cube: ColorCube) -> [Float] {
    let curve = ColorCurve.of(image.colorSpace!)
    let data = image.dataProvider!.data! as Data
    var levels = [Float](repeating: 0, count: image.width * image.height * 3)
    for p in 0..<(image.width * image.height) {
        let code = SIMD3<Float>(Float(data[p * 4]), Float(data[p * 4 + 1]), Float(data[p * 4 + 2])) / 255
        let e = SIMD3<Float>(ColorCurve.srgb.encode(curve.decode(code.x)), ColorCurve.srgb.encode(curve.decode(code.y)),
                             ColorCurve.srgb.encode(curve.decode(code.z)))
        let out = lookUp(cube, e)
        for c in 0..<3 { levels[p * 3 + c] = curve.encode(out[c]) * 255 }
    }
    return levels
}

/// 0...255 levels of `image` with the chain applied directly by Core Image (FrameScrub's `ColorCorrection.apply`):
/// the steps in Apple's order, then a dissolve with the original at `share`.
private func throughCoreImage(_ image: CGImage, steps: [AutoColorStep], share: Double) -> [Float] {
    let original = CIImage(cgImage: image)
    var result = AutoColorAnalyzer.apply(steps, to: original)
    if share < 1 {
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = original
        mix.targetImage = result
        mix.time = Float(share)
        result = mix.outputImage!
    }
    var pixels = [Float](repeating: 0, count: image.width * image.height * 4)
    CIContext().render(result.cropped(to: original.extent), toBitmap: &pixels, rowBytes: image.width * 16,
                       bounds: original.extent, format: .RGBAf, colorSpace: image.colorSpace!)
    var levels = [Float](repeating: 0, count: image.width * image.height * 3)
    for p in 0..<(image.width * image.height) {
        for c in 0..<3 { levels[p * 3 + c] = min(max(pixels[p * 4 + c], 0), 1) * 255 }
    }
    return levels
}

// Review focus 4: nothing to apply, no cube — the photo keeps the ordinary pipeline.
@Test func nothingAppliesGivesNil() {
    #expect(ColorLUTBuilder.cube(analysis: typical(), settings: settings(auto: false), colorSpace: sRGB) == nil)
    // Δ 4 below the threshold 6: share 0.
    let below = settings(threshold: 6, full: 12)
    #expect(ColorLUTBuilder.share(typical(delta: 4), settings: below) == 0)
    #expect(ColorLUTBuilder.cube(analysis: typical(delta: 4), settings: below, colorSpace: sRGB) == nil)
    #expect(ColorLUTBuilder.cube(analysis: typical(tooDark: true), settings: settings(), colorSpace: sRGB) == nil)
    #expect(ColorLUTBuilder.cube(analysis: nil, settings: settings(), colorSpace: sRGB) == nil)
    #expect(ColorLUTBuilder.cube(analysis: typical(), settings: settings(strength: 0), colorSpace: sRGB) == nil)
    // apple-luma leaves Apple's vibrance out: with only vibrance chosen, nothing is left.
    #expect(ColorLUTBuilder.cube(analysis: typical(), settings: settings(method: .appleLuma, filters: [.vibrance]),
                                 colorSpace: sRGB) == nil)
    // Manual vibrance needs no analysis and works on a photo too dark or needing none.
    #expect(ColorLUTBuilder.cube(analysis: typical(tooDark: true), settings: settings(vibrance: true), colorSpace: sRGB) != nil)
    #expect(ColorLUTBuilder.cube(analysis: typical(delta: 4), settings: settings(threshold: 6, full: 12, vibrance: true),
                                 colorSpace: sRGB) != nil)
    #expect(ColorLUTBuilder.cube(analysis: nil, settings: settings(auto: false, vibrance: true), colorSpace: sRGB) != nil)
    // Not an RGB space: the renderer draws gray and CMYK photos in Display P3, which is what the caller passes.
    #expect(ColorLUTBuilder.cube(analysis: typical(), settings: settings(), colorSpace: CGColorSpaceCreateDeviceGray()) == nil)
}

@Test func identityCubeLayout() {
    let cube = ColorCube.identity
    let n = ColorCube.dimension
    #expect(cube.values.count == n * n * n * 4)
    #expect(node(cube, 5, 0, 0) == SIMD3(Float(Float16(5 / Float(last))), 0, 0))   // r fastest
    #expect(node(cube, 0, 7, 0) == SIMD3(0, Float(Float16(7 / Float(last))), 0))
    #expect(node(cube, 0, 0, last) == SIMD3(0, 0, 1))
    #expect(cube.values[3] == 1)
}

// The lattice goes into Core Image and comes back in the same order and the same light.
@Test func neutralChainGivesIdentity() throws {
    let diagonal = AutoColorStep(name: "CIToneCurve", kind: .curve, parameters: [
        "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25),
        "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: 0.75),
        "inputPoint4": CIVector(x: 1, y: 1)])
    for name in [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.adobeRGB1998] {
        let cube = try #require(ColorLUTBuilder.cube(analysis: AutoColorAnalysis(steps: [diagonal], delta: 10, tooDark: false),
                                                     settings: settings(), colorSpace: CGColorSpace(name: name)!))
        let worst = zip(cube.values, ColorCube.identity.values).map { abs(Float($0) - Float($1)) }.max()!
        #expect(worst <= 2e-3, "\(name): \(worst)")
    }
}

// M3c spec §7: the cube on an image against the chain applied directly — mean ≤ 0.3, max ≤ 4 of 255 — for the three
// spaces, at full strength and as a dissolve: the probe's typical values, and Apple's own analysis of the image in that
// space (a steep stretch, 0.24...0.88 to 0...1, which magnifies any lookup error).
@Test func cubeMatchesCoreImage() throws {
    for name in [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.adobeRGB1998] {
        let space = CGColorSpace(name: name)!, image = dullImage(space)
        let apples = AutoColorAnalyzer.analyse(image)
        try #require(!apples.steps.isEmpty)
        for (label, analysis) in [("typical", typical()), ("apple's", apples)] {
            for strength in [1.0, 0.6] {
                let cube = try #require(ColorLUTBuilder.cube(analysis: analysis, settings: settings(strength: strength),
                                                             colorSpace: space))
                let errors = zip(throughCube(image, cube), throughCoreImage(image, steps: analysis.steps, share: strength))
                    .map { abs($0 - $1) }
                let mean = errors.reduce(0, +) / Float(errors.count), worst = errors.max()!
                let what = "\(name) \(label) strength \(strength)"
                print(String(format: "cubeMatchesCoreImage %@: mean %.3f max %.2f", what, mean, worst))
                #expect(mean <= 0.3, "\(what): mean \(mean)")
                #expect(worst <= 4, "\(what): max \(worst)")
            }
        }
    }
}

// Strength and ramp are one mix in linear light.
@Test func halfShareIsMidway() throws {
    for method in AutoColorMethod.allCases {
        let full = try #require(ColorLUTBuilder.cube(analysis: typical(), settings: settings(method: method), colorSpace: sRGB))
        let half = try #require(ColorLUTBuilder.cube(analysis: typical(), settings: settings(method: method, strength: 0.5),
                                                     colorSpace: sRGB))
        var worst: Float = 0
        for b in 0...last {
            for g in 0...last {
                for r in 0...last {
                    let midway = (light(ColorCube.identity, r, g, b) + light(full, r, g, b)) / 2
                    let difference = light(half, r, g, b) - midway
                    worst = max(worst, difference.max(), -difference.min())
                }
            }
        }
        #expect(worst <= 1e-3, "\(method): \(worst)")
    }
    // The ramp: Δ 9 between 6 and 12 is half the strength.
    #expect(ColorLUTBuilder.share(typical(delta: 9), settings: settings(threshold: 6, full: 12)) == 0.5)
    #expect(ColorLUTBuilder.share(typical(delta: 9), settings: settings(strength: 0.5, threshold: 6, full: 12)) == 0.25)
    #expect(ColorLUTBuilder.share(typical(delta: 9), settings: settings(auto: false)) == 0)
    #expect(ColorLUTBuilder.share(nil, settings: settings()) == 0)
    #expect(ColorLUTBuilder.share(typical(tooDark: true), settings: settings()) == 0)
}

// Spec §4.2: apple-luma changes luminance only; a node keeps its chromaticity unless it is pulled into the gamut.
// Checked on the corrected light before it is stored (Float16 rounds the encoded node by up to 2.4e-4, ~6e-4 of the
// light per channel); the stored cube stays in 0...1.
@Test func appleLumaKeepsChromaticity() throws {
    let s = settings(method: .appleLuma)
    let corrected = try #require(ColorLUTBuilder.correctedLattice(analysis: typical(), settings: s, colorSpace: sRGB))
    let cube = try #require(ColorLUTBuilder.cube(analysis: typical(), settings: s, colorSpace: sRGB))
    let lattice = ColorLUTBuilder.lattice
    var compared = 0
    for i in stride(from: 0, to: lattice.count, by: 4) {
        let input = SIMD3(lattice[i], lattice[i + 1], lattice[i + 2])
        let output = SIMD3(corrected[i], corrected[i + 1], corrected[i + 2])
        #expect(output.min() >= 0 && output.max() <= 1, "node \(i / 4): \(output)")
        guard input.min() > 0.02, output.max() < 0.999 else { continue }
        let ratio = output / input
        #expect(ratio.max() - ratio.min() <= 1e-3 * ratio.max(), "node \(i / 4): \(ratio)")
        compared += 1
    }
    #expect(compared > 10_000)
    #expect(cube.values.allSatisfy { (0...1).contains($0) })
    // The curve does change the luminance.
    #expect(abs(node(cube, 8, 8, 8).x - node(ColorCube.identity, 8, 8, 8).x) > 0.005)
}

@Test func vibranceAloneSaturates() throws {
    let cube = try #require(ColorLUTBuilder.cube(analysis: nil, settings: settings(auto: false, vibrance: true),
                                                 colorSpace: sRGB))
    func saturation(_ c: SIMD3<Float>) -> Float { (c.max() - c.min()) / c.max() }
    let dull = light(ColorCube.identity, 20, 16, 14)
    #expect(saturation(light(cube, 20, 16, 14)) > saturation(dull) + 0.02)
    for i in 0...last {
        let grey = node(cube, i, i, i)
        #expect(grey.max() - grey.min() <= 1e-3, "grey \(i): \(grey)")
    }
}

@Test func luminanceWeightsSRGB() {
    let w = ColorLUTBuilder.luminanceWeights(of: sRGB)
    #expect(abs(w.sum() - 1) <= 0.01)
    #expect((0.70...0.73).contains(w.y))
    #expect(w.z < 0.08)
    // Wider primaries: P3's and Adobe RGB's green is a smaller share of white.
    #expect(ColorLUTBuilder.luminanceWeights(of: CGColorSpace(name: CGColorSpace.displayP3)!).y < w.y - 0.01)
    #expect(ColorLUTBuilder.luminanceWeights(of: CGColorSpace(name: CGColorSpace.adobeRGB1998)!).y < w.y - 0.05)
}

@Test func statusCases() {
    let ramp = settings(threshold: 6, full: 12)
    #expect(ColorLUTBuilder.status(typical(), settings: settings(auto: false, vibrance: true)) == .off)
    #expect(ColorLUTBuilder.status(nil, settings: ramp) == .analysing)
    #expect(ColorLUTBuilder.status(typical(tooDark: true), settings: ramp) == .tooDark)
    #expect(ColorLUTBuilder.status(typical(delta: 4), settings: ramp) == .needsNone(delta: 4))
    #expect(ColorLUTBuilder.status(typical(delta: 9), settings: ramp) == .applied(method: .apple, share: 0.5, delta: 9))
    var luma = ramp
    luma.method = .appleLuma
    luma.strength = 0.5
    #expect(ColorLUTBuilder.status(typical(delta: 12), settings: luma) == .applied(method: .appleLuma, share: 0.5, delta: 12))
    // Final review: apple-luma leaves Apple's vibrance out, so with only vibrance chosen no cube carries the share.
    luma.filters = [.vibrance]
    #expect(ColorLUTBuilder.status(typical(delta: 12), settings: luma) == .nothingToApply(delta: 12))
    var vibranceOnly = ramp
    vibranceOnly.filters = [.vibrance]
    #expect(ColorLUTBuilder.status(typical(delta: 9), settings: vibranceOnly) == .applied(method: .apple, share: 0.5, delta: 9))
    // Below the threshold it needs none, whatever the filters.
    #expect(ColorLUTBuilder.status(typical(delta: 4), settings: luma) == .needsNone(delta: 4))
}

// Spec §4.2: a cube is built in about a millisecond after the first (Core Image's warm-up). The budget is loose: a
// guard against a lost order of magnitude, not a benchmark (the debug build runs the per-node loops unoptimised).
@Test func cubeBuildTime() throws {
    #if DEBUG
    let budget = 200.0
    #else
    let budget = 10.0
    #endif
    let s = settings(vibrance: true)
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let first = Date()
    _ = ColorLUTBuilder.cube(analysis: typical(), settings: s, colorSpace: space)
    print(String(format: "cubeBuildTime first: %.2f ms", Date().timeIntervalSince(first) * 1000))
    for method in AutoColorMethod.allCases {
        var withMethod = s
        withMethod.method = method
        var times: [Double] = []
        for _ in 0..<10 {
            let start = Date()
            _ = try #require(ColorLUTBuilder.cube(analysis: typical(), settings: withMethod, colorSpace: space))
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: "cubeBuildTime %@ + vibrance: median %.2f ms, max %.2f ms", method.rawValue, median, times.max()!))
        #expect(median < budget)
    }
}

