import Accelerate
import CoreGraphics
import Foundation

/// The per-code map that turns the gray codes of a gray-profile photo into Display P3 codes (M3b spec §5). A gray
/// image maps to neutral, so CoreGraphics' own conversion is a 1D table per channel, read once from a 256-code ramp
/// drawn into a Display P3 context (~10 µs); libjxl hands over a gray photo's codes as they are, replicated into
/// RGB, and this is what the ImageIO path's draw does to them.
struct GrayConversion {
    /// Display P3 code of each gray code, per channel.
    let red: [UInt8], green: [UInt8], blue: [UInt8]

    /// The conversion for the gray profile `iccData`, or nil when it is not a gray profile or its curve is the sRGB
    /// one (every channel within one code of the identity), where tagging the codes Display P3 is exact enough.
    static func of(iccData: Data) -> GrayConversion? {
        guard isGray(iccData), let gray = CGColorSpace(iccData: iccData as CFData), gray.model == .monochrome,
              let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        let codes = [UInt8](0...255)
        guard let provider = CGDataProvider(data: Data(codes) as CFData),
              let ramp = CGImage(width: 256, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 256, space: gray,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                 decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let context = CGContext(data: nil, width: 256, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(ramp, in: CGRect(x: 0, y: 0, width: 256, height: 1))
        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let table = { (channel: Int) in (0..<256).map { pixels[$0 * 4 + channel] } }
        let conversion = GrayConversion(red: table(2), green: table(1), blue: table(0))
        let nearIdentity = [conversion.red, conversion.green, conversion.blue].allSatisfy { table in
            table.indices.allSatisfy { abs(Int(table[$0]) - $0) <= 1 }
        }
        return nearIdentity ? nil : conversion
    }

    /// Whether the profile's data colour space (header bytes 16...19) is 'GRAY'.
    static func isGray(_ iccData: Data) -> Bool {
        iccData.count > 20 && iccData.dropFirst(16).prefix(4).elementsEqual("GRAY".utf8)
    }

    /// Maps the R, G and B bytes of `width` x `height` RGBA8 pixels in place; alpha is untouched. Pixels the file stores
    /// premultiplied (`premultiplied`) are unpremultiplied around the map, since a table on premultiplied values is
    /// wrong wherever alpha < 255.
    func apply(to bytes: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int, premultiplied: Bool) {
        var buffer = vImage_Buffer(data: bytes, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: bytesPerRow)
        let identity = [UInt8](0...255)
        if premultiplied { vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags)) }
        // The "ARGB" tables apply to the channels in memory order, here R, G, B, A.
        vImageTableLookUp_ARGB8888(&buffer, &buffer, red, green, blue, identity, vImage_Flags(kvImageNoFlags))
        if premultiplied { vImagePremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags)) }
    }
}
