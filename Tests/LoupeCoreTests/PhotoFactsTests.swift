import CoreGraphics
import Foundation
import HomeScreenModel
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LoupeCore

/// A photo card's facts from ImageIO's properties of bytes already read (HomeScreenKit's file-cards spec).
@Suite struct PhotoFactsTests {
    private func jpeg(orientation: Int = 1) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        let exif: [CFString: Any] = [kCGImagePropertyExifExposureTime: 1.0 / 250, kCGImagePropertyExifFNumber: 2.8,
                                     kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFocalLength: 35,
                                     kCGImagePropertyExifLensModel: "FE 24-70mm F2.8 GM II",
                                     kCGImagePropertyExifDateTimeOriginal: "2024:06:01 14:03:22"]
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "SONY", kCGImagePropertyTIFFModel: "ILCE-7M4"]
        return TestJPEGs.encode(context.makeImage()!, type: .jpeg,
                                properties: [kCGImagePropertyExifDictionary: exif, kCGImagePropertyTIFFDictionary: tiff,
                                             kCGImagePropertyOrientation: orientation])
    }

    @Test func exifOfAJPEG() throws {
        let f = try #require(PhotoFacts.read(jpeg()))
        #expect(f.width == 64 && f.height == 48)
        #expect(f.camera == "SONY ILCE-7M4" && f.lens == "FE 24-70mm F2.8 GM II")
        #expect(FileFactsText.exposureLine(f) == "1/250 · f/2.8 · ISO\u{00A0}400 · 35\u{00A0}mm")
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: try #require(f.taken))
        #expect(parts.year == 2024 && parts.month == 6 && parts.day == 1 && parts.hour == 14)
        #expect(f.isVideo == false)
    }

    @Test func aQuarterTurnTradesTheSides() throws {
        let f = try #require(PhotoFacts.read(jpeg(orientation: 6)))
        #expect(f.width == 48 && f.height == 64)
    }

    @Test func unreadableBytesHaveNone() {
        #expect(PhotoFacts.read(Data([1, 2, 3])) == nil)
    }
}
