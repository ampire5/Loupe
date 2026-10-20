import Accelerate
import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

private func profile(_ name: CFString) -> Data { CGColorSpace(name: name)!.copyICCData()! as Data }

@Test func grayConversionTablesAreCoreGraphics() throws {
    let linear = try #require(GrayConversion.of(iccData: profile(CGColorSpace.linearGray)))
    #expect(linear.red.count == 256 && linear.green.count == 256 && linear.blue.count == 256)
    // Linear gray code 128 is a light of 0.5, which is code 188 on the sRGB curve.
    #expect(abs(Int(linear.red[128]) - 188) <= 1, "linear gray code 128 should be about 188: \(linear.red[128])")
    #expect(linear.red[0] == 0 && linear.red[255] == 255)
}

@Test func rgbAndUnreadableProfilesHaveNoGrayConversion() {
    #expect(GrayConversion.of(iccData: profile(CGColorSpace.adobeRGB1998)) == nil)
    #expect(GrayConversion.of(iccData: Data("not a profile".utf8)) == nil)
    #expect(GrayConversion.of(iccData: Data()) == nil)
}

/// Pixels the file stores premultiplied are unpremultiplied around the map: the result is the map of the straight
/// value, premultiplied again (within the rounding of two 8-bit divisions).
@Test func premultipliedGrayIsMappedAsStraightValues() throws {
    let conversion = try #require(GrayConversion.of(iccData: profile(CGColorSpace.linearGray)))
    var straight = [UInt8](), premultiplied = [UInt8]()
    for alpha in [255, 200, 128, 64, 20] {
        for gray in stride(from: 0, through: 255, by: 15) {
            let mapped = Int(conversion.red[gray])
            straight += [UInt8(mapped * alpha / 255), UInt8(mapped * alpha / 255), UInt8(mapped * alpha / 255), UInt8(alpha)]
            let p = gray * alpha / 255
            premultiplied += [UInt8(p), UInt8(p), UInt8(p), UInt8(alpha)]
        }
    }
    let width = straight.count / 4
    premultiplied.withUnsafeMutableBytes {
        conversion.apply(to: $0.baseAddress!, width: width, height: 1, bytesPerRow: width * 4, premultiplied: true)
    }
    for i in 0..<width where straight[i * 4 + 3] >= 128 {   // dark, mostly transparent pixels lose their precision
        for c in 0..<3 { #expect(abs(Int(premultiplied[i * 4 + c]) - Int(straight[i * 4 + c])) <= 3, "pixel \(i) channel \(c)") }
        #expect(premultiplied[i * 4 + 3] == straight[i * 4 + 3])
    }
}
