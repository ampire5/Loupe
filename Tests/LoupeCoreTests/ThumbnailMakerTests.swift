import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LoupeCore

/// Width and height a stored thumbnail decodes to.
private func size(of jpeg: Data) -> PixelSize? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return PixelSize(width: image.width, height: image.height)
}

private func make(_ data: Data, maxSide: Int = 512) throws -> (jpeg: Data, info: ImageInfo) {
    try ThumbnailMaker.make(from: data, decoder: DecoderRegistry.decoder(for: data), maxSide: maxSide)
}

/// A horizontal gradient drawn in `space` and encoded as `type` (the space's ICC profile is embedded).
private func gradientImage(width: Int, height: Int, space: CGColorSpace) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    let colors = [CGColor(colorSpace: space, components: [1, 0, 0, 1])!, CGColor(colorSpace: space, components: [0, 1, 0, 1])!]
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
    return context.makeImage()!
}

/// RGB of the pixel at (x, y) of a stored thumbnail, drawn into sRGB; y runs down from the top row (a bitmap
/// context's first row in memory).
private func rgb(_ jpeg: Data, x: Int, y: Int) -> [Int] {
    rgb(ThumbnailMaker.decodeImage(jpeg)!, x: x, y: y)
}

/// RGB of the pixel at (x, y) of `image` drawn into sRGB, y down from the top.
private func rgb(_ image: CGImage, x: Int, y: Int) -> [Int] {
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let p = context.data!.assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow + x * 4
    return [Int(p[0]), Int(p[1]), Int(p[2])]
}

private func profileName(of jpeg: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    return properties[kCGImagePropertyProfileName] as? String
}

@Test func baselineThumbnailHasLongSide512() throws {
    let (jpeg, info) = try make(TestJPEGs.gradient(width: 4000, height: 3000))
    #expect(size(of: jpeg) == PixelSize(width: 512, height: 384))
    #expect(info.pixelSize == PixelSize(width: 4000, height: 3000))
    #expect(info.typeIdentifier == "public.jpeg")
}

@Test func portraitLongSideIsHeight() throws {
    let (jpeg, _) = try make(TestJPEGs.gradient(width: 3000, height: 4000))
    #expect(size(of: jpeg) == PixelSize(width: 384, height: 512))
}

@Test func maxSideIsHonoured() throws {
    let (jpeg, _) = try make(TestJPEGs.gradient(width: 4000, height: 3000), maxSide: 1024)
    #expect(size(of: jpeg) == PixelSize(width: 1024, height: 768))
}

@Test func smallImageNotUpscaled() throws {
    let (jpeg, info) = try make(TestJPEGs.gradient(width: 300, height: 200))
    #expect(size(of: jpeg) == PixelSize(width: 300, height: 200))
    #expect(info.pixelSize == PixelSize(width: 300, height: 200))
}

@Test func pngUsesImageIO() throws {
    let png = TestJPEGs.encode(gradientImage(width: 2000, height: 1000, space: CGColorSpace(name: CGColorSpace.sRGB)!), type: .png)
    let (jpeg, info) = try make(png)
    #expect(size(of: jpeg) == PixelSize(width: 512, height: 256))
    #expect(info.typeIdentifier == "public.png")
    #expect(info.pixelSize == PixelSize(width: 2000, height: 1000))
}

@Test func truncatedPNGMakesNoThumbnail() throws {
    let png = TestJPEGs.encode(gradientImage(width: 2000, height: 1000, space: CGColorSpace(name: CGColorSpace.sRGB)!), type: .png)
    #expect(throws: (any Error).self) { try make(png.prefix(png.count / 2)) }
}

/// A progressive gradient of a size whose DC picture is sharp enough at 512 (long side 4096 = 8 x 512).
private let sharpProgressive = TestJPEGs.gradient(width: 4096, height: 3072, progressive: true)

/// The prefix `readPrefix` stops at: a chunk that reaches into the first AC scan's header.
private func readerPrefix(_ data: Data) throws -> Data {
    let end = try #require(JPEGScans.endOfDCScans(data))
    return data.prefix(end + 64)
}

@Test func progressivePrefixMakesThumbnail() throws {
    let data = sharpProgressive
    let prefix = try readerPrefix(data)
    #expect(ThumbnailMaker.isPrefixEnough(prefix))
    let info = try TurboJPEGDecoder().probe(data)
    let jpeg = try ThumbnailMaker.makeFromPrefix(prefix, fullSize: info, maxSide: 512)
    #expect(size(of: jpeg) == PixelSize(width: 512, height: 384))
    // The DC terms alone carry the picture: it matches the full-data thumbnail, not a grey fill.
    let (full, _) = try make(data)
    for (x, y) in [(10, 10), (256, 192), (500, 370)] {
        let a = rgb(jpeg, x: x, y: y), b = rgb(full, x: x, y: y)
        for c in 0..<3 { #expect(abs(a[c] - b[c]) <= 12, "channel \(c) at \(x),\(y): \(a[c]) vs \(b[c])") }
    }
}

@Test func prefixWithSomeACDataStillWorks() throws {
    // The reader hands over whole chunks, which may run well into the first AC scans.
    let data = sharpProgressive
    let end = try #require(JPEGScans.endOfDCScans(data))
    let info = try TurboJPEGDecoder().probe(data)
    let jpeg = try ThumbnailMaker.makeFromPrefix(data.prefix(end + (data.count - end) / 3), fullSize: info, maxSide: 512)
    #expect(size(of: jpeg) == PixelSize(width: 512, height: 384))
}

@Test func progressivePrefixFallsBackToFullRead() throws {
    let data = sharpProgressive
    let end = try #require(JPEGScans.endOfDCScans(data))
    #expect(!ThumbnailMaker.isPrefixEnough(data.prefix(end / 2)))
    #expect(!ThumbnailMaker.isPrefixEnough(data.prefix(end)))  // the next SOS header not seen yet
    #expect(!ThumbnailMaker.isPrefixEnough(TestJPEGs.gradient(width: 4096, height: 3072)))
    #expect(ThumbnailMaker.isPrefixEnough(data))
    let info = try TurboJPEGDecoder().probe(data)
    #expect(throws: (any Error).self) { try ThumbnailMaker.makeFromPrefix(Data(repeating: 0x5A, count: 4096), fullSize: info, maxSide: 512) }
    // Cut short of the proof that the DC scans are complete: refused, not decoded with grey rows.
    #expect(throws: (any Error).self) { try ThumbnailMaker.makeFromPrefix(data.prefix(end / 2), fullSize: info, maxSide: 512) }
    #expect(throws: (any Error).self) { try ThumbnailMaker.makeFromPrefix(data.prefix(end), fullSize: info, maxSide: 512) }
}

@Test func prefixOfAnotherSizeThrows() throws {
    let data = sharpProgressive
    let other = ImageInfo(pixelSize: PixelSize(width: 4096, height: 3071), typeIdentifier: "public.jpeg",
                          isProgressive: true, fileSize: data.count, colorSpaceName: nil)
    #expect(throws: (any Error).self) { try ThumbnailMaker.makeFromPrefix(try readerPrefix(data), fullSize: other, maxSide: 512) }
}

@Test func prefixRefusedBelowEightTimesMaxSide() throws {
    // 2000 / 8 = 250 px of DC detail would be stretched to 512 and stored soft for good.
    let data = TestJPEGs.gradient(width: 2000, height: 1500, progressive: true)
    let info = try TurboJPEGDecoder().probe(data)
    #expect(!ThumbnailMaker.prefixIsSharpEnough(info, maxSide: 512))
    #expect(throws: ThumbnailMakerError.prefixTooCoarse) {
        try ThumbnailMaker.makeFromPrefix(try readerPrefix(data), fullSize: info, maxSide: 512)
    }
    func sized(_ width: Int, _ height: Int) -> ImageInfo {
        ImageInfo(pixelSize: PixelSize(width: width, height: height), typeIdentifier: "public.jpeg",
                  isProgressive: true, fileSize: 0, colorSpaceName: nil)
    }
    #expect(ThumbnailMaker.prefixIsSharpEnough(sized(4096, 3072), maxSide: 512))
    #expect(ThumbnailMaker.prefixIsSharpEnough(sized(3072, 4096), maxSide: 512))
    #expect(!ThumbnailMaker.prefixIsSharpEnough(sized(4095, 3072), maxSide: 512))
    #expect(!ThumbnailMaker.prefixIsSharpEnough(sized(4096, 3072), maxSide: 1024))
}

@Test func thumbnailWithAlphaOnChecker() throws {
    // M3b spec §3: the left quarter opaque white, then half-transparent red, the right half fully transparent, onto the
    // #FFFFFF / #CCCCCC checker with cells of 1/16 of the long side (512 / 16 = 32 px), white cell at the top-left;
    // composited in linear light, so 50 % red over white keeps G = B at the encoded half of the light (188), not 128.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 256, height: 512))
    context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 0.5])!)
    context.fill(CGRect(x: 256, y: 0, width: 256, height: 512))
    let (jpeg, _) = try make(TestJPEGs.encode(context.makeImage()!, type: .png))
    #expect(size(of: jpeg) == PixelSize(width: 512, height: 256))
    func near(_ value: [Int], _ expected: [Int], _ label: String) {
        #expect(zip(value, expected).allSatisfy { abs($0 - $1) <= 6 }, "\(label): \(value), expected \(expected)")
    }
    near(rgb(jpeg, x: 64, y: 128), [255, 255, 255], "opaque white")
    // Cells (8, 0) and (9, 0) of the transparent half (x 256...511), and (9, 1) below the grey one.
    near(rgb(jpeg, x: 8 * 32 + 16, y: 16), [255, 255, 255], "white cell")
    near(rgb(jpeg, x: 9 * 32 + 16, y: 16), [0xcc, 0xcc, 0xcc], "grey cell")
    near(rgb(jpeg, x: 9 * 32 + 16, y: 48), [255, 255, 255], "white cell below a grey one")
    // Half-transparent red over cell (4, 0), white, and (5, 0), #CCCCCC: linear light 0.5 + 0.5·back.
    near(rgb(jpeg, x: 4 * 32 + 16, y: 16), [255, 188, 188], "red over white")
    near(rgb(jpeg, x: 5 * 32 + 16, y: 16), [231, 149, 149], "red over grey")
}

@Test func iccIsEmbedded() throws {
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let image = gradientImage(width: 2000, height: 1000, space: p3)
    for source in [TestJPEGs.encode(image, type: .jpeg), TestJPEGs.encode(image, type: .png)] {
        let (jpeg, _) = try make(source)
        let name = try #require(profileName(of: jpeg))
        #expect(name.contains("P3"), "profile \(name)")
    }
}

@Test func cellDecodeRespectsMaxPixel() throws {
    let (jpeg, _) = try make(TestJPEGs.gradient(width: 4000, height: 3000))
    let cell = try #require(ThumbnailMaker.decodeCell(jpeg, maxPixel: 192))
    #expect(max(cell.width, cell.height) == 192)
    let full = try #require(ThumbnailMaker.decodeImage(jpeg))
    #expect(full.width == 512 && full.height == 384)
    #expect(ThumbnailMaker.decodeCell(Data([1, 2, 3]), maxPixel: 192) == nil)
    #expect(ThumbnailMaker.decodeImage(Data([1, 2, 3])) == nil)
}

// MARK: - Seeding the pyramid (spec M2.5 §5.1)

private func info(_ width: Int, _ height: Int) -> ImageInfo {
    ImageInfo(pixelSize: PixelSize(width: width, height: height), typeIdentifier: "public.jpeg", isProgressive: false,
              fileSize: 0, colorSpaceName: nil)
}

/// BGRA bytes of the pixel at (x, y) of a seeded level.
private func bgra(_ image: DecodedImage, x: Int, y: Int) -> [Int] {
    let p = image.buffer.bytes.assumingMemoryBound(to: UInt8.self) + y * image.bytesPerRow + x * 4
    return [Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3])]
}

/// 14000 px tall with a 512 px thumbnail: level 5 (438 px) is the finest not larger than it (level 4 is 875).
@Test func seedLevelFor14000IsLevel5() throws {
    let jpeg = TestJPEGs.gradient(width: 384, height: 512)
    let level = try #require(ThumbnailMaker.seedLevel(jpeg, info: info(10502, 14000)))
    #expect(level.level == 5)
    #expect(level.image.pixelSize == PixelSize(width: 329, height: 438))
    #expect(level.image.bytesPerRow >= 329 * 4)
    #expect(level.image.buffer.length >= level.image.bytesPerRow * 438)
    // The picture itself, not an empty buffer: the gradient runs red (bottom left) to blue (top right).
    let red = bgra(level.image, x: 2, y: 435), blue = bgra(level.image, x: 326, y: 2)
    #expect(red[2] > 200 && red[0] < 60, "bottom left \(red)")
    #expect(blue[0] > 200 && blue[2] < 60, "top right \(blue)")
    #expect(red[3] == 255 && blue[3] == 255)
}

@Test func seedRefusedOnAspectMismatch() {
    let portrait = TestJPEGs.gradient(width: 384, height: 512)
    #expect(ThumbnailMaker.seedLevel(portrait, info: info(14000, 10502)) == nil)
    // A pixel off from rounding is fine; three are not.
    #expect(ThumbnailMaker.seedLevel(TestJPEGs.gradient(width: 385, height: 512), info: info(10502, 14000)) != nil)
    #expect(ThumbnailMaker.seedLevel(TestJPEGs.gradient(width: 388, height: 512), info: info(10502, 14000)) == nil)
    #expect(ThumbnailMaker.seedLevel(Data([1, 2, 3]), info: info(10502, 14000)) == nil)
}

/// A thumbnail no smaller than the photo (a photo below `thumb-size`) seeds level 0 at the photo's own size.
@Test func seedOfASmallPhotoIsLevel0() throws {
    let level = try #require(ThumbnailMaker.seedLevel(TestJPEGs.gradient(width: 300, height: 200), info: info(300, 200)))
    #expect(level.level == 0)
    #expect(level.image.pixelSize == PixelSize(width: 300, height: 200))
}

/// With `thumb-size` below 512 the coarsest level can be larger than the thumbnail: it is stretched up into
/// that level rather than refused, or such a setting would turn the jump preview off for every big photo.
@Test func seedBelowTheCoarsestLevelStretchesUp() throws {
    let level = try #require(ThumbnailMaker.seedLevel(TestJPEGs.gradient(width: 192, height: 256), info: info(10502, 14000)))
    #expect(level.level == 5)
    #expect(level.image.pixelSize == PixelSize(width: 329, height: 438))
}

/// The level is tagged with the thumbnail's own colour space (the source's ICC), like the viewer's decoders tag
/// theirs, so the seeded pyramid and the levels decoded later into it render alike.
@Test func seedKeepsTheThumbnailColourSpace() throws {
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let (jpeg, source) = try make(TestJPEGs.encode(gradientImage(width: 2000, height: 1000, space: p3), type: .jpeg))
    let level = try #require(ThumbnailMaker.seedLevel(jpeg, info: source))
    #expect(level.level == 2)
    #expect(level.image.pixelSize == PixelSize(width: 500, height: 250))
    let name = try #require(level.image.colorSpace.name as String?)
    #expect(name.contains("P3"), "colour space \(name)")
}

// MARK: - EXIF orientation (spec M3b §2.2)

/// The strip shows photos as the photographer saw them: an EXIF 6 photo stored 4000x3000 gets a portrait thumbnail,
/// its stored left half (red) on top. The `ImageInfo` stays the stored header, orientation included.
@Test func thumbnailIsOriented() throws {
    for (name, data) in [("jpeg", TestJPEGs.halves(width: 4000, height: 3000, orientation: 6)),
                         ("png", reencoded(TestJPEGs.halves(width: 4000, height: 3000), as: .png, orientation: 6))] {
        let (jpeg, info) = try make(data)
        try #require(size(of: jpeg) == PixelSize(width: 384, height: 512), "\(name)")
        #expect(info.pixelSize == PixelSize(width: 4000, height: 3000) && info.orientation == .right, "\(name)")
        #expect(info.colorSpace == nil, "\(name)")   // `catalogued`: the colour space by name only
        let top = rgb(jpeg, x: 192, y: 128), bottom = rgb(jpeg, x: 192, y: 384)
        #expect(top[0] > 200 && top[2] < 60, "\(name) top \(top)")
        #expect(bottom[2] > 200 && bottom[0] < 60, "\(name) bottom \(bottom)")
    }
}

/// `data` decoded and encoded again as `type` with the EXIF orientation `orientation`.
private func reencoded(_ data: Data, as type: UTType, orientation: Int) -> Data {
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
    return TestJPEGs.encode(image, type: type, properties: [kCGImagePropertyOrientation: orientation])
}

/// Every orientation, through libjpeg-turbo (JPEG) and ImageIO (PNG): each cell of the thumbnail is the cell of
/// CoreGraphics' own oriented picture of the file (`CGImageSourceCreateThumbnailWithTransform`).
@Test func thumbnailOrientedLikeCoreGraphics() throws {
    let cell = 32
    /// The nearest of the six pattern colours (JPEG and the colour match move each a little).
    func nearest(_ c: [Int]) -> Int {
        TestJPEGs.patternColors.indices.min { p, q in
            func d(_ k: (r: Int, g: Int, b: Int)) -> Int {
                (k.r - c[0]) * (k.r - c[0]) + (k.g - c[1]) * (k.g - c[1]) + (k.b - c[2]) * (k.b - c[2])
            }
            return d(TestJPEGs.patternColors[p]) < d(TestJPEGs.patternColors[q])
        }!
    }
    for orientation in ImageOrientation.allCases {
        let jpeg = TestJPEGs.pattern(cell: cell, orientation: orientation.rawValue)
        let png = reencoded(TestJPEGs.pattern(cell: cell), as: .png, orientation: orientation.rawValue)
        for (name, data) in [("jpeg", jpeg), ("png", png)] {
            let (thumb, _) = try make(data)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 3 * cell]
            let reference = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
            let shown = PixelSize(width: reference.width, height: reference.height)
            #expect(shown == orientation.orientedSize(PixelSize(width: 3 * cell, height: 2 * cell)))
            try #require(size(of: thumb) == shown, "\(orientation) \(name)")
            for y in 0..<shown.height / cell {
                for x in 0..<shown.width / cell {
                    let px = x * cell + cell / 2, py = y * cell + cell / 2
                    let got = rgb(thumb, x: px, y: py), want = rgb(reference, x: px, y: py)
                    #expect(nearest(got) == nearest(want), "\(orientation) \(name) cell (\(x), \(y)): \(got) vs \(want)")
                }
            }
        }
    }
}

/// `exif-orientation=no` in the strip: a thumbnail made for any orientation, turned back by `unturned`, is the
/// stored picture again: each cell of the pattern in its stored place, at the stored size.
@Test func unturnedThumbnailIsTheStoredPicture() throws {
    let cell = 32
    func nearest(_ c: [Int]) -> Int {
        TestJPEGs.patternColors.indices.min { p, q in
            func d(_ k: (r: Int, g: Int, b: Int)) -> Int {
                (k.r - c[0]) * (k.r - c[0]) + (k.g - c[1]) * (k.g - c[1]) + (k.b - c[2]) * (k.b - c[2])
            }
            return d(TestJPEGs.patternColors[p]) < d(TestJPEGs.patternColors[q])
        }!
    }
    for orientation in ImageOrientation.allCases {
        let (jpeg, info) = try make(TestJPEGs.pattern(cell: cell, orientation: orientation.rawValue))
        let thumb = try #require(ThumbnailMaker.decodeImage(jpeg))
        #expect(PixelSize(width: thumb.width, height: thumb.height) == orientation.orientedSize(PixelSize(width: 3 * cell, height: 2 * cell)))
        let back = try #require(ThumbnailMaker.unturned(thumb, from: info.orientation))
        try #require(PixelSize(width: back.width, height: back.height) == PixelSize(width: 3 * cell, height: 2 * cell), "\(orientation)")
        for y in 0..<2 {
            for x in 0..<3 {
                let got = rgb(back, x: x * cell + cell / 2, y: y * cell + cell / 2)
                let want = TestJPEGs.patternColor(x: x, y: y, cellsWide: 3)
                #expect(nearest(got) == nearest([want.r, want.g, want.b]), "\(orientation) cell (\(x), \(y)): \(got)")
            }
        }
    }
}

/// The progressive prefix's thumbnail is turned like the whole file's: the stored one's pixels, oriented.
@Test func prefixThumbnailIsOriented() throws {
    let data = sharpProgressive
    let stored = try TurboJPEGDecoder().probe(data)
    let info = ImageInfo(pixelSize: stored.pixelSize, typeIdentifier: stored.typeIdentifier, isProgressive: true,
                         fileSize: data.count, colorSpaceName: stored.colorSpaceName, orientation: .right)
    let plain = try ThumbnailMaker.makeFromPrefix(try readerPrefix(data), fullSize: stored, maxSide: 512)
    let turned = try ThumbnailMaker.makeFromPrefix(try readerPrefix(data), fullSize: info, maxSide: 512)
    try #require(size(of: turned) == PixelSize(width: 384, height: 512))
    for (x, y) in [(10, 10), (192, 256), (370, 500), (300, 40)] {
        let s = ImageOrientation.right.storedPoint(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5),
                                                   storedSize: CGSize(width: 512, height: 384))
        let a = rgb(turned, x: x, y: y), b = rgb(plain, x: Int(s.x), y: Int(s.y))
        for c in 0..<3 { #expect(abs(a[c] - b[c]) <= 12, "channel \(c) at \(x),\(y): \(a[c]) vs \(b[c])") }
    }
}

/// The oriented thumbnail seeds the photo's pyramid in oriented layout (drawn with `.up`, `drawOrientation`): a
/// portrait thumbnail of an EXIF 6 landscape photo is accepted, at the oriented level size.
@Test func seedOfAnOrientedThumbnailIsOriented() throws {
    let rotated = ImageInfo(pixelSize: PixelSize(width: 14000, height: 10502), typeIdentifier: "public.jpeg",
                            isProgressive: false, fileSize: 0, colorSpaceName: nil, orientation: .right)
    let level = try #require(ThumbnailMaker.seedLevel(TestJPEGs.gradient(width: 384, height: 512), info: rotated))
    #expect(level.level == 5)
    #expect(level.image.pixelSize == PixelSize(width: 329, height: 438))
    // A thumbnail in stored layout (made before M3b) no longer fits it.
    #expect(ThumbnailMaker.seedLevel(TestJPEGs.gradient(width: 512, height: 384), info: rotated) == nil)
}

// MARK: - JPEG XL (Loupe's libjxl: thumbnails from the 1:8 DC image)

/// Records whether the thumbnail went through the decoder's `preview` (not ImageIO's thumbnailer).
private final class PreviewSpy: ImageDecoder, @unchecked Sendable {
    let base: any ImageDecoder
    private(set) var previews = 0
    init(_ base: any ImageDecoder) { self.base = base }
    var name: String { base.name }
    func probe(_ data: Data) throws -> ImageInfo { try base.probe(data) }
    func preview(_ data: Data, info: ImageInfo, level: Int) throws -> LevelImage {
        previews += 1
        return try base.preview(data, info: info, level: level)
    }
    func decodeFull(_ data: Data, info: ImageInfo) throws -> DecodedImage { try base.decodeFull(data, info: info) }
}

private func largestDifference(_ a: Data, _ b: Data, points: [(Int, Int)]) -> Int {
    points.map { (x, y) in zip(rgb(a, x: x, y: y), rgb(b, x: x, y: y)).map { abs($0 - $1) }.max()! }.max()!
}

@Test(.enabled(if: TestJXL.available)) func jxlThumbnailSkipsImageIO() throws {
    let source = TestJPEGs.gradient(width: 4096, height: 3072)
    let data = try TestJXL.encode(source, inputName: "in.jpg")
    let spy = PreviewSpy(DecoderRegistry.decoder(for: data))
    let (jpeg, info) = try ThumbnailMaker.make(from: data, decoder: spy, maxSide: 512)
    #expect(spy.previews == 1)
    #expect(info.typeIdentifier == "public.jpeg-xl")
    #expect(size(of: jpeg) == PixelSize(width: 512, height: 384))
    let fromJPEG = try make(source).jpeg
    #expect(largestDifference(jpeg, fromJPEG, points: [(10, 10), (256, 192), (500, 370)]) <= 6)
}

@Test(.enabled(if: TestJXL.available)) func smallJXLThumbnailFromFullDecode() throws {
    let data = try TestJXL.encode(TestJPEGs.gradient(width: 1200, height: 900), inputName: "in.jpg")
    #expect(size(of: try make(data).jpeg) == PixelSize(width: 512, height: 384))
}

@Test(.enabled(if: TestJXL.available)) func jxlPrefixEnoughAtTheDCByteCount() throws {
    let data = try TestJXL.encode(TestJPEGs.gradient(width: 4096, height: 3072), inputName: "in.jpg")
    let count = try #require(JXLDecoder.dcByteCount(data))
    #expect(count < data.count)
    #expect(!ThumbnailMaker.isPrefixEnough(data.prefix(count - 1)))
    #expect(ThumbnailMaker.isPrefixEnough(data.prefix(count)))
    #expect(!ThumbnailMaker.isPrefixEnough(data.prefix(100)))
    let junk = Data([0xFF, 0x0A] + (0..<4094).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 13) })
    #expect(!ThumbnailMaker.isPrefixEnough(junk))
    let fromPNG = try TestJXL.encode(TestJPEGs.encode(gradientImage(width: 2400, height: 1800,
                                                                     space: CGColorSpace(name: CGColorSpace.sRGB)!),
                                                       type: .png), arguments: ["-d", "0"])
    #expect(!ThumbnailMaker.isPrefixEnough(fromPNG))
}

@Test(.enabled(if: TestJXL.available)) func jxlPrefixThumbnailMatchesWholeFile() throws {
    let data = try TestJXL.encode(TestJPEGs.gradient(width: 4096, height: 3072), inputName: "in.jpg")
    let count = try #require(JXLDecoder.dcByteCount(data))
    let (whole, info) = try make(data)
    let prefix = try ThumbnailMaker.makeFromJXLPrefix(data.prefix(count), fullSize: info, maxSide: 512)
    #expect(size(of: prefix) == PixelSize(width: 512, height: 384))
    #expect(largestDifference(prefix, whole, points: [(10, 10), (256, 192), (500, 370)]) <= 3)
}

@Test(.enabled(if: TestJXL.available)) func jxlPrefixThumbnailIsTurned() throws {
    let data = try TestJXL.encode(TestJPEGs.halves(width: 4096, height: 3072, orientation: 6), inputName: "in.jpg")
    let count = try #require(JXLDecoder.dcByteCount(data))
    let info = try JXLDecoder().probe(data)
    let prefix = try ThumbnailMaker.makeFromJXLPrefix(data.prefix(count), fullSize: info, maxSide: 512)
    #expect(size(of: prefix) == PixelSize(width: 384, height: 512))
    #expect(size(of: try make(data).jpeg) == PixelSize(width: 384, height: 512))
}

/// With `jxl-dc-preview=no` there is no DC thumbnail, so a prefix read would only be thrown away (prefix, then the
/// whole file): the JXL prefix is never "enough".
@Test(.enabled(if: TestJXL.available)) func jxlPrefixNeverEnoughWithDCOff() throws {
    let data = try TestJXL.encode(TestJPEGs.gradient(width: 4096, height: 3072), inputName: "in.jpg")
    #expect(ThumbnailMaker.isPrefixEnough(data, jxl: JXLOptions(dcPreview: true)))
    #expect(!ThumbnailMaker.isPrefixEnough(data, jxl: JXLOptions(dcPreview: false)))
}
