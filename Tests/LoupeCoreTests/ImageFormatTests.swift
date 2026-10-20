import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

/// An ISOBMFF `ftyp` box with the given major brand and no compatible brands.
private func ftyp(_ brand: String) -> Data {
    Data([0, 0, 0, 16] + Array("ftyp".utf8) + Array(brand.utf8) + [0, 0, 0, 0])
}

@Test func detectsJPEG() { #expect(ImageFormat.detect(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])) == .jpeg) }

@Test func detectsPNG() {
    #expect(ImageFormat.detect(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == .png)
}

@Test func detectsWebP() {
    let data = Data(Array("RIFF".utf8) + [0x10, 0, 0, 0] + Array("WEBPVP8 ".utf8))
    #expect(ImageFormat.detect(data) == .webp)
}

@Test func detectsHEICAndAVIFBrands() {
    #expect(ImageFormat.detect(ftyp("heic")) == .heic)
    #expect(ImageFormat.detect(ftyp("avif")) == .avif)
}

@Test func detectsBothJXLSignatures() {
    #expect(ImageFormat.detect(Data([0xFF, 0x0A, 0x00, 0x00])) == .jxl)
    #expect(ImageFormat.detect(Data([0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A])) == .jxl)
}

@Test func unknownBytesAreNotAFormat() {
    #expect(ImageFormat.detect(Data("hello".utf8)) == nil)
    #expect(ImageFormat.detect(Data()) == nil)
}

/// A PNG that arrives named `x.jpg` is routed by its bytes: the registry never sees a file name.
@Test func formatBeatsExtension() throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    let png = TestJPEGs.encode(context.makeImage()!, type: .png)
    #expect(ImageFormat.detect(png) == .png)
    #expect(try DecoderRegistry.decoder(for: png).probe(png).typeIdentifier == "public.png")
}
