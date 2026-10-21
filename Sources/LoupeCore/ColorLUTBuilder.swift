import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A photo's colour correction as one 3D lookup table, sampled by the renderer at the output of every draw path
/// (M3c spec §4.1). Both sides are linear light in the photo's primaries, sRGB-encoded: node `i` of a channel stands
/// for `lin_srgb(i / last)` (`last = dimension − 1`), so the lattice is even in perceived lightness, and its value is
/// the corrected light encoded the same way, clamped to 0...1; the renderer decodes it once per pixel after the lookup.
/// Encoded values interpolate closer to the chain than linear ones, whose trilinear lookup always lands a little
/// bright (linear light is convex in the encoded input; mean 0.32 against 0.14 of 255 in the tests).
public struct ColorCube: Equatable, Sendable {
    /// Nodes per channel: the one constant of the cube's size (texture, lattice and lookup follow it).
    public static let dimension = 33

    /// RGBA of each node (alpha 1), r fastest, then g, then b: node (r, g, b) starts at `((b · n + g) · n + r) · 4`
    /// with `n = dimension`. The layout of an `rgba16Float` 3D texture of n³ texels.
    public let values: [Half]

    public init(values: [Half]) {
        precondition(values.count == Self.dimension * Self.dimension * Self.dimension * 4, "a cube has n³ RGBA nodes")
        self.values = values
    }

    /// No change: each node holds its own position, `i / last`. The renderer's "from" cube when a correction fades in.
    public static let identity: ColorCube = {
        let n = dimension, last = Float(n - 1)
        var values = [Half](repeating: 1, count: n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = ((b * n + g) * n + r) * 4
                    values[i] = Half(Float(r) / last); values[i + 1] = Half(Float(g) / last)
                    values[i + 2] = Half(Float(b) / last)
                }
            }
        }
        return ColorCube(values: values)
    }()
}

/// Builds a photo's cube from Apple's analysis and the window's colour keys (M3c spec §4.2). The application is
/// FrameScrub's `ColorCorrection.apply` as it is — the active steps in Apple's order with Apple's vibrance × gain
/// (≤ 1), strength as a dissolve with the original in linear light, then manual vibrance — evaluated once on the
/// lattice instead of on every frame. Thread-safe: the background queue of the window's corrector calls it.
public enum ColorLUTBuilder {
    /// The share of the full correction a photo gets: `auto-color-strength` × the ramp of its Δ (spec §3.2); 0 while
    /// auto colour is off, before the analysis, and for a photo too dark to analyse. Method, filters and vibrance gain
    /// play no part: they change what is applied, not whether a photo needs it.
    public static func share(_ analysis: AutoColorAnalysis?, settings: ColorSettings) -> Double {
        guard settings.autoColor, let analysis, !analysis.tooDark else { return 0 }
        let ramp = AutoColorSchedule.rampStrength(delta: analysis.delta, threshold: settings.threshold, full: settings.full)
        return min(1, max(0, settings.strength)) * ramp
    }

    /// What the stats line says about a photo (spec §2.3). `.nothingToApply` when the settings let none of its steps
    /// through (`auto-color-filters`, `apple-luma` without Apple's vibrance); a colour space that takes no cube is the
    /// corrector's to tell, which knows the space.
    public static func status(_ analysis: AutoColorAnalysis?, settings: ColorSettings) -> ColorStatus {
        guard settings.autoColor else { return .off }
        guard let analysis else { return .analysing }
        guard !analysis.tooDark else { return .tooDark }
        guard AutoColorSchedule.isNeeded(delta: analysis.delta, threshold: settings.threshold) else {
            return .needsNone(delta: analysis.delta)
        }
        let share = share(analysis, settings: settings)
        if share > 0, activeSteps(analysis.steps, settings: settings).isEmpty { return .nothingToApply(delta: analysis.delta) }
        return .applied(method: settings.method, share: share, delta: analysis.delta)
    }

    /// The cube of a photo in `colorSpace`; nil when nothing applies (auto colour off, not needed, too dark, no steps
    /// chosen — and vibrance off), so the photo keeps the ordinary pipelines. `colorSpace` is the space the renderer
    /// draws the photo in (Display P3 for a gray or CMYK photo, which are decoded to it); a space that is not RGB or
    /// has no linearized variant (`CGColorSpaceCreateLinearized`; RGB ICC profiles have one) gets no cube either. The
    /// first build in a process includes Core Image's warm-up.
    public static func cube(analysis: AutoColorAnalysis?, settings: ColorSettings, colorSpace: CGColorSpace) -> ColorCube? {
        guard let values = correctedLattice(analysis: analysis, settings: settings, colorSpace: colorSpace) else { return nil }
        // sRGB-encoded and clamped to the photo's range (Loupe is SDR; `encode` clamps, NaN gives 0).
        var halves = [Half](repeating: 1, count: values.count)
        for i in values.indices where i % 4 != 3 { halves[i] = Half(ColorCurve.srgb.encode(values[i])) }
        return ColorCube(values: halves)
    }

    /// The corrected lattice in linear light (RGBA floats in the cube's layout), before it is encoded and stored in
    /// half floats; nil when there is no cube. Internal for the tests, which check `apple-luma`'s chromaticity at full
    /// precision (in the stored cube Float16's rounding, ×2.4 through the decoding, is ~1e-3 of the light).
    static func correctedLattice(analysis: AutoColorAnalysis?, settings: ColorSettings,
                                 colorSpace: CGColorSpace) -> [Float]? {
        let share = share(analysis, settings: settings)
        let steps = share > 0 ? activeSteps(analysis?.steps ?? [], settings: settings) : []
        let vibrance = settings.vibrance ? min(1, settings.vibranceAmount) : 0
        guard !steps.isEmpty || vibrance > 0, colorSpace.model == .rgb,
              let linear = CGColorSpaceCreateLinearized(colorSpace) else { return nil }
        var values = lattice
        if !steps.isEmpty {
            // The lattice is linear light in the photo's primaries, so the chain sees exactly what it would see in
            // the photo; its output comes back in the same space.
            var full = render(AutoColorAnalyzer.apply(steps, to: image(lattice, in: linear),
                                                      vibranceGain: settings.vibranceGain), in: linear)
            if settings.method == .appleLuma { full = luminanceOnly(full, weights: luminanceWeights(of: colorSpace)) }
            let amount = Float(share)
            for i in values.indices { values[i] += amount * (full[i] - values[i]) }
        }
        if vibrance > 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image(values, in: linear)
            filter.amount = Float(vibrance)
            if let output = filter.outputImage { values = render(output, in: linear) }
        }
        return values
    }

    /// The luminance of linear light in `space`'s primaries: the Y row of its RGB → XYZ matrix, from its three
    /// primaries converted into `genericXYZ` (the ICC connection space, D50), scaled so that white is 1 (`apple-luma`,
    /// spec §4.2). The conversion is ColorSync's (`CGColor.converted`): Core Image renders nothing into an XYZ space.
    /// A primary at full is the same light in the space and in its linearized variant, so the space itself serves.
    /// Worked out once per space; Rec. 709's weights for a space that is not RGB or does not convert.
    public static func luminanceWeights(of space: CGColorSpace) -> SIMD3<Double> {
        weightsLock.lock()
        let known = weightsBySpace[space]
        weightsLock.unlock()
        if let known { return known }
        let weights = primariesLuminance(space)
        weightsLock.lock()
        weightsBySpace[space] = weights
        weightsLock.unlock()
        return weights
    }

    // MARK: - Lattice

    /// The lattice in linear light, what the chain is run on: RGBA floats in the cube's layout, each channel
    /// `lin_srgb(i / last)` at node `i`.
    static let lattice: [Float] = {
        let n = ColorCube.dimension
        let light = (0..<n).map { ColorCurve.srgb.decode(Float($0) / Float(n - 1)) }
        var values = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = ((b * n + g) * n + r) * 4
                    values[i] = light[r]; values[i + 1] = light[g]; values[i + 2] = light[b]
                }
            }
        }
        return values
    }()

    /// The lattice as an image of n² × n pixels: a row of the image is one b, r running fastest along it.
    private static let latticeSize = CGSize(width: ColorCube.dimension * ColorCube.dimension, height: ColorCube.dimension)

    private static func image(_ values: [Float], in space: CGColorSpace) -> CIImage {
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: Int(latticeSize.width) * 16, size: latticeSize, format: .RGBAf,
                       colorSpace: space)
    }

    private static func render(_ image: CIImage, in space: CGColorSpace) -> [Float] {
        var values = [Float](repeating: 0, count: lattice.count)
        AutoColorAnalyzer.context.render(image, toBitmap: &values, rowBytes: Int(latticeSize.width) * 16,
                                         bounds: CGRect(origin: .zero, size: latticeSize), format: .RGBAf, colorSpace: space)
        return values
    }

    // MARK: - Methods

    /// The steps the settings let through, in Apple's order: `auto-color-filters`, and no Apple vibrance for
    /// `apple-luma`.
    private static func activeSteps(_ steps: [AutoColorStep], settings: ColorSettings) -> [AutoColorStep] {
        steps.filter { settings.filters.contains($0.kind) && !(settings.method == .appleLuma && $0.kind == .vibrance) }
    }

    /// `apple-luma` (spec §4.2): each node takes its luminance from the chain's output and keeps its own chromaticity,
    /// `out = in · Y_out / Y_in`. A colour that would leave the gamut is pulled toward the grey of the same luminance
    /// until its largest channel is 1; black (no chromaticity) becomes the grey `Y_out`.
    private static func luminanceOnly(_ corrected: [Float], weights: SIMD3<Double>) -> [Float] {
        let w = SIMD3<Float>(Float(weights.x), Float(weights.y), Float(weights.z))
        var result = corrected
        for i in stride(from: 0, to: lattice.count, by: 4) {
            let input = SIMD3<Float>(lattice[i], lattice[i + 1], lattice[i + 2])
            let output = SIMD3<Float>(corrected[i], corrected[i + 1], corrected[i + 2])
            let yIn = (input * w).sum(), y = min(max((output * w).sum(), 0), 1)
            var out: SIMD3<Float>
            if yIn < 1e-6 {
                out = SIMD3(repeating: y)
            } else {
                out = input * (y / yIn)
                let peak = out.max()
                if peak > 1 {
                    out = y + (out - y) * ((1 - y) / (peak - y))   // peak > 1 ≥ y
                }
            }
            result[i] = out.x; result[i + 1] = out.y; result[i + 2] = out.z
        }
        return result
    }

    // MARK: - Luminance weights

    private static let weightsLock = NSLock()
    nonisolated(unsafe) private static var weightsBySpace: [CGColorSpace: SIMD3<Double>] = [:]   // behind weightsLock

    private static let rec709 = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    private static func primariesLuminance(_ space: CGColorSpace) -> SIMD3<Double> {
        guard space.model == .rgb, let xyz = CGColorSpace(name: CGColorSpace.genericXYZ) else { return rec709 }
        let primaries: [[CGFloat]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1]]
        let y = primaries.map { components -> Double in
            let color = CGColor(colorSpace: space, components: components)?
                .converted(to: xyz, intent: .relativeColorimetric, options: nil)
            return color?.components.map { Double($0[1]) } ?? -1
        }
        let weights = SIMD3<Double>(y[0], y[1], y[2]), white = weights.sum()
        guard white.isFinite, white > 0, weights.min() >= 0 else { return rec709 }
        return weights / white
    }
}
