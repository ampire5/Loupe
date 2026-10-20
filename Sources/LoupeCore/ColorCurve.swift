import Accelerate
import CoreGraphics
import Foundation

/// How a photo's colour space turns encoded levels into linear light (M3b spec §4): the renderer filters in
/// linear light, so the transfer curve it decodes and re-encodes with has to be the profile's own.
public enum ColorCurve: Hashable, Sendable {
    /// The sRGB curve (sRGB, Display P3, and any profile whose curve matches it within `srgbTolerance`):
    /// hardware sRGB decoding and encoding, as for every photo before M3b.
    case srgb
    /// Any other curve. `forward[code]` is the linear light of the 8-bit code `code` (256 values);
    /// `inverse[i]` is the encoded level in 0…1 of the linear light `(i / 4095)²` (4096 values).
    /// The inverse is indexed by the square root of the light, so the dark codes still round-trip: a pure
    /// 2.2 gamma has code 1 at 5e-6, far below one 1/4095 step of linear light.
    case table(forward: [Float], inverse: [Float])

    /// The largest distance from the sRGB curve (in linear light) that still counts as sRGB.
    public static let srgbTolerance: Float = 1.0 / 1024

    public static let inverseCount = 4096

    /// The curve of `space`, from its linearized variant (`CGColorSpaceCreateLinearized`) over a 0…255 ramp per
    /// channel; `.srgb` when it matches the sRGB curve, when the space is not RGB (gray and CMYK photos are decoded
    /// to Display P3), or when an RGB space has no linearized variant or fails to convert (a debug-log line each, `LOUPE_DEBUG` only).
    /// A profile whose channels differ gets their mean curve: one table serves all three. The named sRGB and Display P3
    /// spaces (most photos, and every CMYK or gray one once decoded) are `.srgb` without the conversion, whose first
    /// call in a process costs ~2 ms (ColorSync's setup) and later ones ~0.1 ms.
    public static func of(_ space: CGColorSpace) -> ColorCurve {
        if let name = space.name, name == CGColorSpace.sRGB || name == CGColorSpace.displayP3 { return .srgb }
        guard space.model == .rgb else { return .srgb }
        guard let linear = CGColorSpaceCreateLinearized(space) else {
            debugLog("ColorCurve: the colour space has no linearized variant, using sRGB")
            return .srgb
        }
        let forward: [Float]
        do { forward = try linearRamp(of: space, linearized: linear) } catch {
            debugLog("ColorCurve: converting the colour space to linear failed (\(error)), using sRGB")
            return .srgb
        }
        let nearSRGB = forward.indices.allSatisfy { abs(forward[$0] - srgbLinear(Float($0) / 255)) <= srgbTolerance }
        return nearSRGB ? .srgb : .table(forward: forward, inverse: inverse(of: forward))
    }

    private static let debugEnabled = ProcessInfo.processInfo.environment["LOUPE_DEBUG"] != nil

    /// The project's debug-log convention (`LOUPE_DEBUG` in the environment, a line on stderr), which the app's
    /// `DebugLog` lives above this module: silent by default.
    private static func debugLog(_ message: String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// The linear light of an encoded level in 0…1 (CPU reference; the shader does the same lookups).
    public func decode(_ level: Float) -> Float {
        let level = level.isNaN ? 0 : min(max(level, 0), 1)
        switch self {
        case .srgb: return Self.srgbLinear(level)
        case .table(let forward, _): return Self.interpolate(forward, at: level * 255)
        }
    }

    /// The encoded level in 0…1 of linear light (clamped to 0…1, NaN as 0); the table path looks up `√light`.
    public func encode(_ linear: Float) -> Float {
        let light = linear.isNaN ? 0 : min(max(linear, 0), 1)
        switch self {
        case .srgb: return light <= 0.0031308 ? light * 12.92 : 1.055 * powf(light, 1 / 2.4) - 0.055
        case .table(_, let inverse): return Self.interpolate(inverse, at: light.squareRoot() * Float(inverse.count - 1))
        }
    }

    private static func srgbLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    private static func interpolate(_ table: [Float], at position: Float) -> Float {
        let i = min(Int(position), table.count - 2), f = position - Float(i)
        return table[i] + (table[i + 1] - table[i]) * f
    }

    private struct ConversionFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// The linear light of each 8-bit code of `space`: a 256×3 float image whose row `r` ramps channel `r` alone,
    /// converted into `linear`; the three ramps are averaged. Float both ways: ColorSync converts 8-bit sources
    /// through a 12-bit table, too coarse for the dark codes.
    private static func linearRamp(of space: CGColorSpace, linearized linear: CGColorSpace) throws -> [Float] {
        var pixels = [Float](repeating: 1, count: 3 * 256 * 4)
        for channel in 0..<3 {
            for code in 0..<256 {
                for component in 0..<3 {
                    pixels[(channel * 256 + code) * 4 + component] = component == channel ? Float(code) / 255 : 0
                }
            }
        }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                                | CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let from = vImage_CGImageFormat(bitsPerComponent: 32, bitsPerPixel: 128, colorSpace: space, bitmapInfo: info),
              let to = vImage_CGImageFormat(bitsPerComponent: 32, bitsPerPixel: 128, colorSpace: linear, bitmapInfo: info)
        else { throw ConversionFailure(description: "no float image format for the space") }
        let converter = try vImageConverter.make(sourceFormat: from, destinationFormat: to)
        var floats = [Float](repeating: 0, count: pixels.count)
        let converted = pixels.withUnsafeMutableBytes { src in
            floats.withUnsafeMutableBytes { dst in
                var source = vImage_Buffer(data: src.baseAddress, height: 3, width: 256, rowBytes: 256 * 16)
                var destination = vImage_Buffer(data: dst.baseAddress, height: 3, width: 256, rowBytes: 256 * 16)
                return vImageConvert_AnyToAny(converter, &source, &destination, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        guard converted == kvImageNoError else { throw ConversionFailure(description: "vImage error \(converted)") }
        var ramp = [Float](repeating: 0, count: 256)
        for channel in 0..<3 {
            for code in 0..<256 { ramp[code] += floats[(channel * 256 + code) * 4 + channel] / 3 }
        }
        return ramp
    }

    /// The inverse of a forward table: for each of the 4096 square-root-spaced light values, the level in 0…1 of
    /// the code with that light, interpolated along the table (made non-decreasing first).
    private static func inverse(of forward: [Float]) -> [Float] {
        var rising = forward
        for i in 1..<rising.count { rising[i] = max(rising[i], rising[i - 1]) }
        var result = [Float](repeating: 1, count: inverseCount)
        var code = 0
        for i in 0..<inverseCount {
            let root = Float(i) / Float(inverseCount - 1), light = root * root
            if light >= rising[255] { break }
            while code < 254 && rising[code + 1] <= light { code += 1 }
            let span = rising[code + 1] - rising[code]
            let fraction = span > 0 ? min(max((light - rising[code]) / span, 0), 1) : 0   // light below an offset black
            result[i] = (Float(code) + fraction) / 255
        }
        return result
    }
}
