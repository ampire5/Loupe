import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// In-memory encoded images for tests, so no fixture files are needed.
enum TestJPEGs {
    /// `image` encoded as `type` with the given ImageIO destination properties.
    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        let ok = CGImageDestinationFinalize(destination)
        precondition(ok)
        return out as Data
    }

    /// A red-to-blue gradient JPEG, baseline or progressive. A gradient rather than a flat colour
    /// so the file is not trivially small (truncation tests need bytes to cut, progressive files
    /// need enough data for several scans).
    static func gradient(width: Int, height: Int, progressive: Bool = false) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                                                              CGColor(red: 0, green: 0, blue: 1, alpha: 1)] as CFArray,
                                  locations: nil)!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if progressive { properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
        return encode(context.makeImage()!, type: .jpeg, properties: properties)
    }

    /// Left half red, right half blue, so a rotated or mirrored result cannot pass as correct.
    static func halves(width: Int, height: Int, orientation: Int? = nil) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        return encode(context.makeImage()!, type: .jpeg, properties: properties)
    }

    /// Six saturated colours that stay tellable apart through JPEG, for `pattern`.
    static let patternColors: [(r: Int, g: Int, b: Int)] = [
        (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (255, 0, 255), (0, 255, 255),
    ]

    /// The colour of cell (`x`, `y`) in a stored `pattern` that is `cellsWide` cells wide: all different in 3 x 2.
    static func patternColor(x: Int, y: Int, cellsWide: Int) -> (r: Int, g: Int, b: Int) {
        patternColors[(y * cellsWide + x) % patternColors.count]
    }

    /// `cellsWide` x `cellsHigh` cells of `cell` pixels each, every cell its own colour, so no rotation or mirror of
    /// the stored picture looks like another (spec M3b §2); `orientation` is the EXIF tag written with the file
    /// (1...8), the pixels stay as stored.
    static func pattern(cellsWide: Int = 3, cellsHigh: Int = 2, cell: Int = 8, orientation: Int? = nil) -> Data {
        let width = cellsWide * cell, height = cellsHigh * cell
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        for y in 0..<cellsHigh {
            for x in 0..<cellsWide {
                let c = patternColor(x: x, y: y, cellsWide: cellsWide)
                context.setFillColor(CGColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1))
                // CoreGraphics' y is up; cell row 0 is the top row of the picture.
                context.fill(CGRect(x: x * cell, y: height - (y + 1) * cell, width: cell, height: cell))
            }
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        return encode(context.makeImage()!, type: .jpeg, properties: properties)
    }
}
