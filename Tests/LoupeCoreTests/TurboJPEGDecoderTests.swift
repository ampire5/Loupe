import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LoupeCore

private let turbo = TurboJPEGDecoder()

private func channels(_ d: DecodedImage, x: Int, y: Int) -> [Int] {
    let p = d.buffer.bytes.load(fromByteOffset: y * d.bytesPerRow + x * 4, as: UInt32.self)
    return [Int(p & 0xFF), Int((p >> 8) & 0xFF), Int((p >> 16) & 0xFF), Int(p >> 24)]
}

/// A solid-colour image in `space` encoded as JPEG (the colour space's ICC profile is embedded).
private func solidJPEG(width: Int, height: Int, space: CGColorSpace, alpha: CGImageAlphaInfo, components: [CGFloat]) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: alpha.rawValue)!
    context.setFillColor(CGColor(colorSpace: space, components: components)!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return TestJPEGs.encode(context.makeImage()!, type: .jpeg)
}

@Test func fullMatchesImageIO() throws {
    let data = TestJPEGs.gradient(width: 1000, height: 700)
    let info = try turbo.probe(data)
    #expect(info.pixelSize == PixelSize(width: 1000, height: 700))
    #expect(info.typeIdentifier == "public.jpeg")
    #expect(!info.isProgressive)
    let mine = try turbo.decodeFull(data, info: info)
    let reference = try ImageIODecoder.decodeFull(data)
    #expect(mine.pixelSize == reference.pixelSize)
    #expect(mine.bytesPerRow == reference.bytesPerRow)
    for x in [0, 500, 999] {
        for y in [0, 350, 699] {
            let a = channels(mine, x: x, y: y), b = channels(reference, x: x, y: y)
            #expect(a[3] == 0xFF)
            for c in 0..<3 { #expect(abs(a[c] - b[c]) <= 3, "channel \(c) at \(x),\(y): \(a[c]) vs \(b[c])") }
        }
    }
}

@Test func probeSeesProgressive() throws {
    let data = TestJPEGs.gradient(width: 600, height: 400, progressive: true)
    #expect(try turbo.probe(data).isProgressive)
    #expect(try turbo.probe(data).colorSpaceName != nil)
}

@Test func previewIsExactLevel() throws {
    let data = TestJPEGs.gradient(width: 3001, height: 2001)
    let info = try turbo.probe(data)
    let expected = TileGrid(imageSize: info.pixelSize).levelSize(2)
    #expect(expected == PixelSize(width: 751, height: 501))
    let preview = try turbo.preview(data, info: info, level: 2)
    #expect(preview.level == 2)
    #expect(preview.image.pixelSize == expected)
    #expect(preview.image.bytesPerRow == 3008)   // 751 × 4 = 3004, padded to 64 bytes
}

@Test func previewCapsAtEighth() throws {
    let data = TestJPEGs.gradient(width: 3001, height: 2001)
    let info = try turbo.probe(data)
    let preview = try turbo.preview(data, info: info, level: 5)
    #expect(preview.level == 3)
    #expect(preview.image.pixelSize == TileGrid(imageSize: info.pixelSize).levelSize(3))
}

@Test func previewLevelZeroIsFullDecode() throws {
    let data = TestJPEGs.gradient(width: 640, height: 480)
    let preview = try turbo.preview(data, info: try turbo.probe(data), level: 0)
    #expect(preview.level == 0)
    #expect(preview.image.pixelSize == PixelSize(width: 640, height: 480))
}

@Test func turboPreviewLevelClampedToGrid() throws {
    // A small image has fewer than four levels; the result must be a level the grid has.
    let data = TestJPEGs.gradient(width: 300, height: 200)
    let info = try turbo.probe(data)
    let grid = TileGrid(imageSize: info.pixelSize)
    let preview = try turbo.preview(data, info: info, level: 3)
    #expect(preview.level == min(3, grid.levelCount - 1))
    #expect(preview.image.pixelSize == grid.levelSize(preview.level))
}

@Test func previewKeepsOrientationAndColours() throws {
    let data = TestJPEGs.halves(width: 1600, height: 1000)
    let preview = try turbo.preview(data, info: try turbo.probe(data), level: 2)
    let left = channels(preview.image, x: 10, y: 125), right = channels(preview.image, x: 390, y: 125)
    #expect(left[2] > 200 && left[0] < 60)
    #expect(right[0] > 200 && right[2] < 60)
}

@Test func firstLookIsNil() throws {
    let data = TestJPEGs.gradient(width: 600, height: 400, progressive: true)
    #expect(try turbo.firstLook(data, info: try turbo.probe(data)) == nil)
}

@Test func truncatedJPEGRejectedByBothDecoders() throws {
    let data = TestJPEGs.gradient(width: 1000, height: 700)
    let cut = Data(data.prefix(data.count * 9 / 10))
    let info = try turbo.probe(cut)
    #expect(throws: (any Error).self) { try turbo.decodeFull(cut, info: info) }
    #expect(throws: (any Error).self) { try turbo.preview(cut, info: info, level: 1) }
    let registry = DecoderRegistry.decoder(for: cut)
    #expect(throws: DecodeError.unreadable) { try registry.decodeFull(cut, info: try registry.probe(cut)) }
}

@Test func warningTurboRejectsFallbackAccepts() throws {
    // Stray bytes between the first two segments: libjpeg warns ("extraneous bytes before
    // marker"), ImageIO shrugs. Turbo must refuse and the registry must still return pixels.
    let clean = TestJPEGs.gradient(width: 400, height: 300)
    let firstSegmentEnd = 2 + 2 + (Int(clean[4]) << 8 | Int(clean[5]))
    let dirty = clean.prefix(firstSegmentEnd) + Data([0x00, 0x00, 0x00]) + clean.dropFirst(firstSegmentEnd)
    // Turbo already balks at the damaged header; the registry then answers probe and decode via ImageIO.
    let info = try ImageIODecoder.probe(dirty)
    #expect(throws: (any Error).self) { try turbo.decodeFull(dirty, info: info) }
    let registry = DecoderRegistry.decoder(for: dirty)
    let image = try registry.decodeFull(dirty, info: try registry.probe(dirty))
    #expect(image.pixelSize == PixelSize(width: 400, height: 300))
}

@Test func cmykGoesToImageIO() throws {
    let space = CGColorSpace(name: CGColorSpace.genericCMYK)!
    let data = solidJPEG(width: 64, height: 64, space: space, alpha: .none, components: [0.2, 0.4, 0.6, 0.1, 1])
    let info = try turbo.probe(data)
    #expect(throws: (any Error).self) { try turbo.decodeFull(data, info: info) }
    let registry = DecoderRegistry.decoder(for: data)
    let image = try registry.decodeFull(data, info: try registry.probe(data))
    #expect(image.colorSpace.model == .rgb)
}

@Test func grayscaleGoesToImageIO() throws {
    let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
    let data = solidJPEG(width: 64, height: 64, space: space, alpha: .none, components: [0.5, 1])
    #expect(throws: (any Error).self) { try turbo.decodeFull(data, info: try turbo.probe(data)) }
    let registry = DecoderRegistry.decoder(for: data)
    #expect(try registry.decodeFull(data, info: try registry.probe(data)).pixelSize == PixelSize(width: 64, height: 64))
}

@Test func iccProfileKept() throws {
    let space = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
    let data = solidJPEG(width: 64, height: 64, space: space, alpha: .noneSkipFirst, components: [0.5, 0.3, 0.2, 1])
    let image = try turbo.decodeFull(data, info: try turbo.probe(data))
    #expect(image.colorSpace.name as String? == CGColorSpace.adobeRGB1998 as String)
    #expect(try turbo.probe(data).colorSpaceName == "Adobe RGB (1998)")
}

@Test func untaggedIsSRGB() throws {
    let data = TestJPEGs.halves(width: 64, height: 64)
    let image = try turbo.decodeFull(data, info: try turbo.probe(data))
    #expect(image.colorSpace.name as String? == CGColorSpace.sRGB as String)
}

@Test func turboGarbageThrows() {
    #expect(throws: (any Error).self) { try turbo.probe(Data("not a jpeg".utf8)) }
}

@Test func registryRoutesJPEGToTurboFirst() throws {
    let data = TestJPEGs.gradient(width: 200, height: 100)
    let registry = DecoderRegistry.decoder(for: data)
    #expect(registry.name == "libjpeg-turbo")
    #expect(try registry.probe(data).pixelSize == PixelSize(width: 200, height: 100))
}

private struct Failing: ImageDecoder {
    let error: DecodeError
    var name: String { "failing" }
    func probe(_ data: Data) throws -> ImageInfo { throw error }
    func preview(_ data: Data, info: ImageInfo, level: Int) throws -> LevelImage { throw error }
    func decodeFull(_ data: Data, info: ImageInfo) throws -> DecodedImage { throw error }
}

@Test func fallbackSkipsFallbackOnTooLarge() {
    let decoder = FallbackDecoder(primary: Failing(error: .tooLarge), fallback: ImageIOImageDecoder())
    let data = TestJPEGs.gradient(width: 100, height: 100)
    #expect(throws: DecodeError.tooLarge) { try decoder.probe(data) }
    #expect(throws: DecodeError.tooLarge) { try decoder.decodeFull(data, info: ImageInfo(pixelSize: PixelSize(width: 100, height: 100), typeIdentifier: "public.jpeg", isProgressive: false, fileSize: data.count, colorSpaceName: nil)) }
}

@Test func fallbackUsesFallbackOnOtherErrors() throws {
    let decoder = FallbackDecoder(primary: Failing(error: .unreadable), fallback: ImageIOImageDecoder())
    let data = TestJPEGs.gradient(width: 100, height: 100)
    let info = try decoder.probe(data)
    #expect(try decoder.decodeFull(data, info: info).pixelSize == PixelSize(width: 100, height: 100))
    #expect(try decoder.preview(data, info: info, level: 0).level == 0)
}

@Test func turboProbeReadsOrientation() throws {
    for orientation in ImageOrientation.allCases {
        let data = TestJPEGs.pattern(orientation: orientation.rawValue)
        let info = try turbo.probe(data)
        #expect(info.orientation == orientation)
        #expect(info.colorSpace != nil)   // the launch pretag (`RenderLoop.expectColorSpace`) still has its space
        #expect(info.pixelSize == PixelSize(width: 24, height: 16))
    }
    #expect(try turbo.probe(TestJPEGs.pattern()).orientation == .up)
    // Only the header (through the start-of-scan header): the EXIF segment sits before the first scan.
    let data = TestJPEGs.pattern(orientation: 6)
    let scan = try #require(data.indices.first { data[$0] == 0xFF && data[$0 + 1] == 0xDA })
    #expect(try turbo.probe(data.prefix(scan + 16)).orientation == .right)
}

/// A refusal must not leak the libjpeg handle (a throwing class init skips `deinit`): every session made for a
/// gray or CMYK file is gone again once the decode call returns.
@Test func refusedGrayAndCMYKDecodesFreeTheirHandle() throws {
    let gray = solidJPEG(width: 64, height: 64, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                         alpha: .none, components: [0.5, 1])
    let cmyk = solidJPEG(width: 64, height: 64, space: CGColorSpace(name: CGColorSpace.genericCMYK)!,
                         alpha: .none, components: [0.2, 0.4, 0.6, 0.1, 1])
    let decoder = TurboJPEGDecoder()
    let before = decoder.liveSessions.value
    for data in [gray, cmyk] {
        let info = try decoder.probe(data)
        #expect(throws: (any Error).self) { try decoder.decodeFull(data, info: info) }
        #expect(throws: (any Error).self) { try decoder.preview(data, info: info, level: 1) }
    }
    #expect(decoder.liveSessions.value == before)
    // An accepted decode frees its session too.
    let rgb = TestJPEGs.gradient(width: 64, height: 64)
    _ = try decoder.decodeFull(rgb, info: try decoder.probe(rgb))
    #expect(decoder.liveSessions.value == before)
}
