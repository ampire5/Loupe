import Testing
import Foundation
import ImageIO
@testable import LoupeCore

private let exif = kCGImagePropertyExifDictionary as String
private let tiff = kCGImagePropertyTIFFDictionary as String
private let gps = kCGImagePropertyGPSDictionary as String

private func meta(_ properties: [String: Any] = [:], png: [String: String] = [:]) -> PhotoMetadata {
    PhotoMetadata(properties: properties, pngText: png, created: nil, modified: nil)
}

private func exposure(_ t: Double) -> String? {
    meta([exif: [kCGImagePropertyExifExposureTime as String: t]]).exposure
}

@Test func exposureFormats() {
    #expect(exposure(1.0 / 250) == "1/250 s")
    #expect(exposure(0.004) == "1/250 s")
    #expect(exposure(0.0333) == "1/30 s")
    #expect(exposure(0.5) == "0.5\u{00A0}s")
    #expect(exposure(1) == "1\u{2033}")
    #expect(exposure(2) == "2\u{2033}")
    #expect(exposure(2.5) == "2.5\u{00A0}s")
    #expect(exposure(30) == "30\u{2033}")
    #expect(exposure(0) == nil)
}

@Test func apertureFocalAndISO() {
    let m = meta([exif: [kCGImagePropertyExifFNumber as String: 2.8, kCGImagePropertyExifFocalLength as String: 50.0,
                         kCGImagePropertyExifISOSpeedRatings as String: [400]]])
    #expect(m.aperture == "f/2.8")
    #expect(m.focalLength == "50 mm")
    #expect(m.iso == "ISO 400")
    #expect(meta([exif: [kCGImagePropertyExifFNumber as String: 8.0]]).aperture == "f/8")
    #expect(meta([exif: [kCGImagePropertyExifFocalLength as String: 50.0, kCGImagePropertyExifFocalLenIn35mmFilm as String: 75]]).focalLength
            == "50 mm (75 mm equiv.)")
    #expect(meta([exif: [kCGImagePropertyExifFocalLength as String: 5.7, kCGImagePropertyExifFocalLenIn35mmFilm as String: 0]]).focalLength
            == "5.7 mm")
}

@Test func capturedDate() {
    #expect(meta([exif: [kCGImagePropertyExifDateTimeOriginal as String: "2024:05:01 12:34:56"]]).captured == "2024-05-01 12:34:56")
    #expect(meta([exif: [kCGImagePropertyExifDateTimeOriginal as String: "garbage"]]).captured == "garbage")
}

@Test func cameraDoesNotRepeatTheMake() {
    #expect(meta([tiff: [kCGImagePropertyTIFFMake as String: "Canon", kCGImagePropertyTIFFModel as String: "Canon EOS R5"]]).camera == "Canon EOS R5")
    #expect(meta([tiff: [kCGImagePropertyTIFFMake as String: "SONY", kCGImagePropertyTIFFModel as String: "ILCE-7M4"]]).camera == "SONY ILCE-7M4")
    #expect(meta([tiff: [kCGImagePropertyTIFFMake as String: "NIKON CORPORATION", kCGImagePropertyTIFFModel as String: "NIKON Z 6"]]).camera == "NIKON Z 6")
    #expect(meta([tiff: [kCGImagePropertyTIFFModel as String: "Pixel 8"]]).camera == "Pixel 8")
    #expect(meta([tiff: [kCGImagePropertyTIFFMake as String: "Leica"]]).camera == "Leica")
}

@Test func lensSoftwareDescription() {
    let m = meta([exif: [kCGImagePropertyExifLensModel as String: "RF24-70mm F2.8 L IS USM"],
                  tiff: [kCGImagePropertyTIFFSoftware as String: "Lightroom", kCGImagePropertyTIFFImageDescription as String: " A beach "]])
    #expect(m.lens == "RF24-70mm F2.8 L IS USM")
    #expect(m.software == "Lightroom")
    #expect(m.description == "A beach")
}

@Test func gpsFormat() {
    let tokyo: [String: Any] = [kCGImagePropertyGPSLatitude as String: 35.6586, kCGImagePropertyGPSLatitudeRef as String: "N",
                                kCGImagePropertyGPSLongitude as String: 139.7454, kCGImagePropertyGPSLongitudeRef as String: "E",
                                kCGImagePropertyGPSAltitude as String: 40.2, kCGImagePropertyGPSAltitudeRef as String: 0]
    #expect(meta([gps: tokyo]).gps == "35.6586° N, 139.7454° E, 40 m")
    var noAlt = tokyo
    noAlt[kCGImagePropertyGPSAltitude as String] = nil
    #expect(meta([gps: noAlt]).gps == "35.6586° N, 139.7454° E")
    let south: [String: Any] = [kCGImagePropertyGPSLatitude as String: 33.8688, kCGImagePropertyGPSLatitudeRef as String: "S",
                                kCGImagePropertyGPSLongitude as String: 151.2093, kCGImagePropertyGPSLongitudeRef as String: "W",
                                kCGImagePropertyGPSAltitude as String: 12.0, kCGImagePropertyGPSAltitudeRef as String: 1]
    #expect(meta([gps: south]).gps == "33.8688° S, 151.2093° W, -12 m")
    #expect(meta([gps: [kCGImagePropertyGPSLatitude as String: 1.0]]).gps == nil)
}

@Test func emptyPropertiesGiveNothing() {
    let m = meta()
    #expect(m.camera == nil && m.lens == nil && m.focalLength == nil && m.aperture == nil && m.exposure == nil)
    #expect(m.iso == nil && m.captured == nil && m.gps == nil && m.software == nil && m.description == nil)
    #expect(m.generation == nil && m.comfyWorkflowBytes == nil && m.error == nil && m.bitDepth == nil && m.hasAlpha == nil)
}

@Test func bitDepthAndAlpha() {
    let m = meta([kCGImagePropertyDepth as String: 16, kCGImagePropertyHasAlpha as String: true])
    #expect(m.bitDepth == 16 && m.hasAlpha == true)
    let opaque = meta([kCGImagePropertyDepth as String: 8.0, kCGImagePropertyHasAlpha as String: false])
    #expect(opaque.bitDepth == 8 && opaque.hasAlpha == false)
    let absent = meta()
    #expect(absent.bitDepth == nil && absent.hasAlpha == nil)
    for bad in [Double.infinity, -Double.infinity, Double.nan, 0, -8, 65, 1e30] {
        #expect(meta([kCGImagePropertyDepth as String: bad]).bitDepth == nil)
    }
    #expect(meta([kCGImagePropertyHasAlpha as String: "yes"]).hasAlpha == nil)
}

@Test func generationText() {
    #expect(meta(png: ["parameters": "a cat\nSteps: 20"]).generation == "a cat\nSteps: 20")
    #expect(meta([exif: [kCGImagePropertyExifUserComment as String: "from exif"]]).generation == "from exif")
    #expect(meta([exif: [kCGImagePropertyExifUserComment as String: "from exif"]], png: ["parameters": "png wins"]).generation == "png wins")
    #expect(meta([exif: [kCGImagePropertyExifUserComment as String: "  "]]).generation == nil)
    // The EXIF user comment as raw bytes: 8-byte character code, then the text.
    let raw = Data("ASCII\0\0\0".utf8) + Data("raw comment".utf8)
    #expect(meta([exif: [kCGImagePropertyExifUserComment as String: raw]]).generation == "raw comment")
}

@Test func comfyWorkflowBytes() {
    #expect(meta(png: ["workflow": String(repeating: "x", count: 2048)]).comfyWorkflowBytes == 2048)
    #expect(meta(png: ["prompt": "{}"]).comfyWorkflowBytes == 2)
    #expect(meta(png: ["workflow": "abc", "prompt": "abcdef"]).comfyWorkflowBytes == 3)
    #expect(meta(png: ["parameters": "x"]).comfyWorkflowBytes == nil)
}

@Test func readOfUnreadableFilesSetsAnError() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photometa-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let missing = PhotoMetadata.read(dir.appendingPathComponent("nope.jpg"))
    #expect(missing.error != nil)
    #expect(missing.error?.contains("\n") == false)
    let textFile = dir.appendingPathComponent("a.jpg")
    try Data("not an image".utf8).write(to: textFile)
    let text = PhotoMetadata.read(textFile)
    #expect(text.error != nil)
    #expect(text.modified != nil)    // the file facts survive the error
    #expect(PhotoMetadata.read(dir).error != nil)
}

@Test func readOfAPNGFindsItsText() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photometa-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // A real 1x1 PNG from ImageIO, with a tEXt chunk spliced in before IDAT.
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
    let png = data as Data
    let ihdrEnd = 8 + 12 + 13
    let spliced = png.prefix(ihdrEnd) + PNGFixture.text("parameters", "a fox") + PNGFixture.text("workflow", "{}") + png.dropFirst(ihdrEnd)
    let url = dir.appendingPathComponent("g.png")
    try Data(spliced).write(to: url)
    let m = PhotoMetadata.read(url)
    #expect(m.error == nil)
    #expect(m.generation == "a fox")
    #expect(m.comfyWorkflowBytes == 2)
    #expect(m.created != nil && m.modified != nil)
}

@Test func hugeAndNonFiniteNumbersDoNotCrash() {
    for bad in [Double.infinity, -Double.infinity, Double.nan, 1e30, 1e-30, 0, -3] {
        let m = meta([exif: [kCGImagePropertyExifExposureTime as String: bad, kCGImagePropertyExifFNumber as String: bad,
                             kCGImagePropertyExifFocalLength as String: bad, kCGImagePropertyExifFocalLenIn35mmFilm as String: bad,
                             kCGImagePropertyExifISOSpeedRatings as String: [bad]],
                      gps: [kCGImagePropertyGPSLatitude as String: bad, kCGImagePropertyGPSLongitude as String: bad]])
        #expect(m.exposure == nil && m.aperture == nil && m.focalLength == nil && m.iso == nil)
        #expect(m.gps == nil || (bad.isFinite && abs(bad) <= 90))    // a small finite latitude is a place
    }
    // The same through strings ("inf" parses as a Double) and a good focal length with a bad equivalent.
    #expect(meta([exif: [kCGImagePropertyExifExposureTime as String: "inf"]]).exposure == nil)
    #expect(meta([exif: [kCGImagePropertyExifFocalLength as String: 50.0, kCGImagePropertyExifFocalLenIn35mmFilm as String: Double.infinity]]).focalLength == "50 mm")
    let tokyo: [String: Any] = [kCGImagePropertyGPSLatitude as String: 35.0, kCGImagePropertyGPSLongitude as String: 139.0,
                                kCGImagePropertyGPSAltitude as String: Double.infinity]
    #expect(meta([gps: tokyo]).gps == "35.0000° N, 139.0000° E")
}

@Test func comfyWorkflowSizeIsTheTrueLength() {
    let m = PhotoMetadata(properties: [:], pngText: ["workflow": String(repeating: "x", count: 65_536)], pngSizes: ["workflow": 300_000],
                          created: nil, modified: nil)
    #expect(m.comfyWorkflowBytes == 300_000)
}

@Test func readOfAPNGWithALargeWorkflowReportsItsFullSize() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photometa-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
    let png = data as Data
    let ihdrEnd = 8 + 12 + 13
    let spliced = png.prefix(ihdrEnd) + PNGFixture.text("workflow", String(repeating: "w", count: 150_000))
        + PNGFixture.ztxt("prompt", String(repeating: "p", count: 200_000)) + png.dropFirst(ihdrEnd)
    let url = dir.appendingPathComponent("w.png")
    try Data(spliced).write(to: url)
    let m = PhotoMetadata.read(url)
    #expect(m.comfyWorkflowBytes == 150_000)
    // The compressed prompt alone (no workflow): its inflated length, not the 64 KB cut.
    let only = png.prefix(ihdrEnd) + PNGFixture.ztxt("prompt", String(repeating: "p", count: 200_000)) + png.dropFirst(ihdrEnd)
    try Data(only).write(to: url)
    #expect(PhotoMetadata.read(url).comfyWorkflowBytes == 200_000)
}

@Test func readKnowsTheHeaderBeforeTheDecoder() throws {
    // The panel shows Format / Dimensions / Profile from the metadata read, so a cold photo needs no decode for them.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photometa-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    let ctx = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    let url = dir.appendingPathComponent("a.jpg")
    try (data as Data).write(to: url)
    let header = try #require(PhotoMetadata.read(url).header)
    #expect(header.pixelSize == PixelSize(width: 3, height: 2))
    #expect(header.typeIdentifier == "public.jpeg")
    #expect(header.orientation == .right)
    #expect(header.fileSize == data.length)
    #expect(header.colorSpaceName == (try ImageIODecoder.probe(data as Data)).colorSpaceName)
    #expect(meta().header == nil)
}
