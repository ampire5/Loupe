import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// One Core Image filter of Apple's analysis with its input values, without the input image.
public struct AutoColorStep: @unchecked Sendable {   // parameter values are immutable NSNumber/CIVector
    public let name: String
    public let kind: AutoColorFilter
    let parameters: [String: Any]

    init(name: String, kind: AutoColorFilter, parameters: [String: Any]) {
        self.name = name
        self.kind = kind
        self.parameters = parameters
    }
}

/// What the analysis of one photo found: the steps, and how much they change it when applied in full.
public struct AutoColorAnalysis: @unchecked Sendable {   // steps hold immutable parameter values
    public let steps: [AutoColorStep]
    /// Mean absolute difference over R, G and B (sRGB, 0...255) the full correction makes to the photo.
    public let delta: Double
    /// The photo is nearly black: no analysis was made, there are no steps and Δ is 0.
    public let tooDark: Bool
    /// Apple's steps left out because a LUT cannot hold them (shadows and highlights with a radius, spec §3.1); the
    /// corrector logs them.
    public let droppedSpatialSteps: Int

    public init(steps: [AutoColorStep], delta: Double, tooDark: Bool, droppedSpatialSteps: Int = 0) {
        self.steps = steps
        self.delta = delta
        self.tooDark = tooDark
        self.droppedSpatialSteps = droppedSpatialSteps
    }
}

/// Apple's automatic adjustments (vibrance, tone curve, shadows and highlights) for a photo, kept as parameters so the
/// cube builder can apply them to a lattice; ported from FrameScrub's `ColorCorrection`.
public enum AutoColorAnalyzer {
    /// The Core Image context of the analysis and of the cube builder (thread-safe; nothing cached between renders).
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// The analysis of `image`, which is used as given (the strip thumbnail, 512 px, is already small enough for
    /// statistics) and keeps its colour space. A nearly black photo is not analysed: Apple's analysis of it stretches
    /// the tones wildly.
    public static func analyse(_ image: CGImage) -> AutoColorAnalysis {
        let sample = CIImage(cgImage: image)
        guard !isTooDarkToAnalyse(sample) else { return AutoColorAnalysis(steps: [], delta: 0, tooDark: true) }
        return analysis(of: sample, steps: adjustmentSteps(for: sample))
    }

    /// The analysis of `sample` with Apple's `steps` for it: those a LUT can hold, counting the others, and their Δ.
    static func analysis(of sample: CIImage, steps all: [AutoColorStep]) -> AutoColorAnalysis {
        let steps = withoutSpatialSteps(all)
        return AutoColorAnalysis(steps: steps, delta: meanDifference(sample, apply(steps, to: sample)), tooDark: false,
                                 droppedSpatialSteps: all.count - steps.count)
    }

    /// Spec §3.1: shadows and highlights with a radius are spatial, which a 3D LUT cannot hold; they are dropped.
    static func withoutSpatialSteps(_ steps: [AutoColorStep]) -> [AutoColorStep] {
        steps.filter { step in
            guard step.kind == .shadows else { return true }
            return ((step.parameters[kCIInputRadiusKey] as? NSNumber)?.doubleValue ?? 0) <= 0
        }
    }

    /// A nearly black frame (a fade-in, a title on black): mean Rec. 709 luma, sRGB-encoded, below 0.06.
    static func isTooDarkToAnalyse(_ image: CIImage) -> Bool {
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = image.extent
        guard let output = average.outputImage else { return false }
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))   // as seen, not linear
        return 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2] < 0.06
    }

    /// `image` with `steps` in full, in their order; Apple's vibrance amount is multiplied by `vibranceGain` and capped
    /// at 1 (`auto-color-vibrance-gain`; FrameScrub's `ColorCorrection.autoVibrance`). Δ uses gain 1, the cube builder
    /// the window's gain.
    static func apply(_ steps: [AutoColorStep], to image: CIImage, vibranceGain: Double = 1) -> CIImage {
        var result = image
        for step in steps {
            guard let filter = CIFilter(name: step.name) else { continue }
            filter.setValuesForKeys(step.parameters)
            if step.kind == .vibrance, let amount = (step.parameters[kCIInputAmountKey] as? NSNumber)?.doubleValue {
                filter.setValue(min(1, amount * vibranceGain), forKey: kCIInputAmountKey)
            }
            filter.setValue(result, forKey: kCIInputImageKey)
            result = filter.outputImage ?? result
        }
        return result.cropped(to: image.extent)
    }

    /// Mean absolute difference over R, G and B between two images of the same extent, as seen (sRGB, 0...255).
    private static func meanDifference(_ a: CIImage, _ b: CIImage) -> Double {
        let width = Int(a.extent.width), height = Int(a.extent.height)
        guard width > 0, height > 0 else { return 0 }
        func pixels(_ image: CIImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &buffer, rowBytes: width * 4, bounds: a.extent, format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return buffer
        }
        let before = pixels(a), after = pixels(b)
        var sum = 0
        for i in stride(from: 0, to: before.count, by: 4) {
            sum += abs(Int(before[i]) - Int(after[i])) + abs(Int(before[i + 1]) - Int(after[i + 1])) + abs(Int(before[i + 2]) - Int(after[i + 2]))
        }
        return Double(sum) / Double(width * height * 3)
    }

    private static func adjustmentSteps(for sample: CIImage) -> [AutoColorStep] {
        let filters = sample.autoAdjustmentFilters(options: [.redEye: false, .enhance: true])
        return filters.compactMap { filter in
            guard let kind = AutoColorFilter(filterName: filter.name) else { return nil }   // face balance, red-eye
            var parameters: [String: Any] = [:]
            for key in filter.inputKeys where key != kCIInputImageKey {
                if let value = filter.value(forKey: key) { parameters[key] = value }
            }
            return AutoColorStep(name: filter.name, kind: kind, parameters: parameters)
        }
    }
}
