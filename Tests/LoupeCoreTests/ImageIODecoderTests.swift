import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LoupeCore

// MARK: - In-memory inputs (no fixture files)

/// A solid-colour CGImage in `space`, drawn through a CGContext so the stored bytes are the
/// given components in that space.
private func solidImage(width: Int, height: Int, space: CGColorSpace, components: [CGFloat],
                        bitsPerComponent: Int = 8, alpha: CGImageAlphaInfo) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent,
                            bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)!
    context.setFillColor(CGColor(colorSpace: space, components: components)!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
    TestJPEGs.encode(image, type: type, properties: properties)
}

private func jpegData(width: Int, height: Int, progressive: Bool = false) -> Data {
    TestJPEGs.gradient(width: width, height: height, progressive: progressive)
}

/// Random noise, which compresses badly, so cutting the file really loses image content.
private func noiseImage(width: Int, height: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    var rng = SystemRandomNumberGenerator()
    let count = context.bytesPerRow * height
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<count { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
    return context.makeImage()!
}

private func pngData(width: Int, height: Int, rgba: (CGFloat, CGFloat, CGFloat, CGFloat),
                     space name: CFString = CGColorSpace.sRGB, bitsPerComponent: Int = 8) -> Data {
    let space = CGColorSpace(name: name)!
    let alpha: CGImageAlphaInfo = rgba.3 < 1 ? .premultipliedLast : .noneSkipLast
    let image = solidImage(width: width, height: height, space: space,
                           components: [rgba.0, rgba.1, rgba.2, rgba.3],
                           bitsPerComponent: bitsPerComponent, alpha: alpha)
    return encode(image, type: .png)
}

/// BGRA pixel of a decoded image.
private func pixel(_ d: DecodedImage, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
    let p = d.buffer.bytes.load(fromByteOffset: y * d.bytesPerRow + x * 4, as: UInt32.self)
    return (UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF), UInt8((p >> 16) & 0xFF), UInt8(p >> 24))
}

private func near(_ a: UInt8, _ b: Int, _ tolerance: Int = 1) -> Bool { abs(Int(a) - b) <= tolerance }

// MARK: - Tests

@Test func probeProgressiveJPEG() throws {
    let data = jpegData(width: 64, height: 48, progressive: true)
    let info = try ImageIODecoder.probe(data)
    #expect(info.pixelSize == PixelSize(width: 64, height: 48))
    #expect(info.isProgressive)
    #expect(info.typeIdentifier == "public.jpeg")
    #expect(info.fileSize == data.count)
    #expect(info.colorSpaceName != nil)
}

@Test func probeBaselineJPEGIsNotProgressive() throws {
    #expect(try !ImageIODecoder.probe(jpegData(width: 64, height: 48)).isProgressive)
}

@Test func probeGarbageThrows() {
    #expect(throws: DecodeError.unreadable) { try ImageIODecoder.probe(Data("not an image".utf8)) }
}

@Test func decodeSolidSRGB() throws {
    let d = try ImageIODecoder.decodeFull(pngData(width: 100, height: 70, rgba: (1, 0, 0, 1)))
    #expect(d.pixelSize == PixelSize(width: 100, height: 70))
    #expect(d.bytesPerRow == 448)
    #expect(d.colorSpace.name == CGColorSpace.sRGB)
    let px = pixel(d, x: 50, y: 30)
    #expect(near(px.r, 255) && near(px.g, 0) && near(px.b, 0) && px.a == 255)
}

@Test func adobeRGBStaysAsIs() throws {
    let data = pngData(width: 32, height: 32, rgba: (200.0 / 255, 100.0 / 255, 50.0 / 255, 1),
                       space: CGColorSpace.adobeRGB1998)
    let d = try ImageIODecoder.decodeFull(data)
    // An embedded Adobe RGB profile decodes to an ICC-based space, which CoreGraphics gives no
    // constant name (unlike sRGB), so identify it by what it is not and by the profile name.
    #expect(d.colorSpace.model == .rgb)
    #expect(d.colorSpace.name != CGColorSpace.displayP3 && d.colorSpace.name != CGColorSpace.sRGB)
    #expect(try ImageIODecoder.probe(data).colorSpaceName == "Adobe RGB (1998)")
    let px = pixel(d, x: 10, y: 10)
    #expect(near(px.r, 200) && near(px.g, 100) && near(px.b, 50) && px.a == 255)
}

@Test func grayscaleDecodes() throws {
    let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
    let image = solidImage(width: 32, height: 32, space: gray, components: [128.0 / 255, 1], alpha: .none)
    let d = try ImageIODecoder.decodeFull(encode(image, type: .jpeg))
    #expect(d.colorSpace.name == CGColorSpace.displayP3)
    // Reference: the same gray rendered into Display P3 by CoreGraphics.
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let reference = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    reference.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let expected = Int(reference.data!.load(as: UInt8.self))
    let px = pixel(d, x: 16, y: 16)
    #expect(abs(Int(px.r) - Int(px.b)) <= 1 && abs(Int(px.g) - Int(px.b)) <= 1)  // neutral stays neutral
    #expect(near(px.r, expected, 3) && near(px.g, expected, 3) && near(px.b, expected, 3))
    #expect(abs(expected - 128) <= 8)
    #expect(px.a == 255)
}

@Test func cmykDecodes() throws {
    let cmyk = CGColorSpaceCreateDeviceCMYK()
    let image = solidImage(width: 32, height: 32, space: cmyk, components: [0, 0, 0, 0, 1], alpha: .none)
    let d = try ImageIODecoder.decodeFull(encode(image, type: .jpeg))
    #expect(d.colorSpace.name == CGColorSpace.displayP3)
    let px = pixel(d, x: 16, y: 16)
    #expect(near(px.r, 255, 3) && near(px.g, 255, 3) && near(px.b, 255, 3) && px.a == 255)
}

@Test func sixteenBitDecodes() throws {
    let d = try ImageIODecoder.decodeFull(pngData(width: 32, height: 32, rgba: (1, 0, 0, 1), bitsPerComponent: 16))
    #expect(d.colorSpace.name == CGColorSpace.sRGB)
    let px = pixel(d, x: 5, y: 5)
    #expect(near(px.r, 255) && near(px.g, 0) && near(px.b, 0) && px.a == 255)
}

@Test func alphaPremultiplied() throws {
    let d = try ImageIODecoder.decodeFull(pngData(width: 32, height: 32, rgba: (1, 1, 1, 128.0 / 255)))
    let px = pixel(d, x: 5, y: 5)
    #expect(near(px.b, 128, 2) && near(px.g, 128, 2) && near(px.r, 128, 2) && near(px.a, 128, 1))
}

@Test func decodersReportAnAlphaChannel() throws {
    // M3b spec §3: the upload scans for transparent pixels only when the decoder says there is an alpha channel.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let translucent = solidImage(width: 16, height: 16, space: space, components: [1, 0, 0, 0.5], alpha: .premultipliedLast)
    let opaqueRGBA = solidImage(width: 16, height: 16, space: space, components: [1, 0, 0, 1], alpha: .premultipliedLast)
    let rgb = solidImage(width: 16, height: 16, space: space, components: [1, 0, 0, 1], alpha: .noneSkipLast)

    let png = try ImageIODecoder.decodeFull(encode(translucent, type: .png))
    #expect(png.hasAlphaChannel && png.hasTransparentPixel())
    // An alpha channel that is all 255 is still one (the scan then finds nothing).
    let opaque = try ImageIODecoder.decodeFull(encode(opaqueRGBA, type: .png))
    #expect(opaque.hasAlphaChannel && !opaque.hasTransparentPixel())
    #expect(!(try ImageIODecoder.decodeFull(encode(rgb, type: .png))).hasAlphaChannel)
    #expect((try ImageIODecoder.decodeFull(encode(translucent, type: .tiff))).hasAlphaChannel)
    let heicTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    if heicTypes.contains(UTType.heic.identifier) {
        let heic = try ImageIODecoder.decodeFull(encode(translucent, type: .heic))
        #expect(heic.hasAlphaChannel && heic.hasTransparentPixel())
    }
    // JPEG has none, through ImageIO and libjpeg-turbo alike, previews included.
    let jpeg = jpegData(width: 64, height: 48)
    #expect(!(try ImageIODecoder.decodeFull(jpeg)).hasAlphaChannel)
    let info = try TurboJPEGDecoder().probe(jpeg)
    #expect(!(try TurboJPEGDecoder().decodeFull(jpeg, info: info)).hasAlphaChannel)
    #expect(!(try TurboJPEGDecoder().preview(jpeg, info: info, level: 1)).image.hasAlphaChannel)
}

@Test func transparentPixelScanCoversEveryPixelAndNoPadding() throws {
    // Odd widths (a trailing 4-byte pixel after the 8-byte words), the last row and pixel, and row padding (zero,
    // which must not count as transparent).
    for width in [1, 2, 7, 33] {
        for height in [1, 65, 130] {
            let (buffer, bytesPerRow) = try ImageIODecoder.allocateBGRA(width: width, height: height)
            let base = buffer.bytes.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height { for x in 0..<width { base[y * bytesPerRow + x * 4 + 3] = 255 } }
            let image = DecodedImage(pixelSize: PixelSize(width: width, height: height), bytesPerRow: bytesPerRow,
                                     buffer: buffer, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            #expect(!image.hasTransparentPixel(), "\(width)x\(height) opaque")
            for (x, y) in [(width - 1, height - 1), (0, 0), (width / 2, height / 2)] {
                base[y * bytesPerRow + x * 4 + 3] = 254
                #expect(image.hasTransparentPixel(), "\(width)x\(height) at \(x),\(y)")
                base[y * bytesPerRow + x * 4 + 3] = 255
            }
        }
    }
}

@Test func garbageThrows() {
    #expect(throws: DecodeError.unreadable) { try ImageIODecoder.decodeFull(Data("not an image".utf8)) }
}

@Test func truncatedThrows() {
    #expect(throws: DecodeError.unreadable) { try ImageIODecoder.decodeFull(jpegData(width: 512, height: 512).prefix(200)) }
}

@Test(arguments: [false, true], [0.5, 0.99])
func truncatedJPEGThrows(progressive: Bool, fraction: Double) {
    let properties: [CFString: Any] = progressive ? [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]] : [:]
    let full = encode(noiseImage(width: 512, height: 512), type: .jpeg, properties: properties)
    #expect(throws: DecodeError.unreadable) { try ImageIODecoder.decodeFull(full.prefix(Int(Double(full.count) * fraction))) }
    #expect(throws: Never.self) { try ImageIODecoder.decodeFull(full) }
}

@Test func truncatedPNGThrows() {
    let full = encode(noiseImage(width: 256, height: 256), type: .png)
    #expect(throws: DecodeError.unreadable) { try ImageIODecoder.decodeFull(full.prefix(full.count / 2)) }
    #expect(throws: Never.self) { try ImageIODecoder.decodeFull(full) }
}

@Test func trailingGarbageAfterEOIStillDecodes() throws {
    var data = jpegData(width: 64, height: 48)
    data.append(Data(repeating: 0x5A, count: 1024))
    #expect(try ImageIODecoder.decodeFull(data).pixelSize == PixelSize(width: 64, height: 48))
}

@Test func rowPaddingAndTailAreZero() throws {
    // 101 px -> 404 bytes of pixels, 448 per row: 44 padding bytes per row.
    let d = try ImageIODecoder.decodeFull(pngData(width: 101, height: 70, rgba: (1, 1, 1, 1)))
    #expect(d.bytesPerRow == 448)
    let bytes = d.buffer.bytes.assumingMemoryBound(to: UInt8.self)
    for y in 0..<70 {
        for x in 404..<448 { #expect(bytes[y * 448 + x] == 0) }
    }
    for i in (70 * 448)..<d.buffer.length { #expect(bytes[i] == 0) }
}

@Test func bufferIsPageAlignedAndRoundedUp() throws {
    let d = try ImageIODecoder.decodeFull(pngData(width: 100, height: 70, rgba: (0, 1, 0, 1)))
    let page = 16 * 1024
    #expect(Int(bitPattern: d.buffer.bytes) % page == 0)
    #expect(d.buffer.length % page == 0)
    #expect(d.buffer.length >= d.bytesPerRow * 70)
}

@Test func bufferRejectsOverflowingSize() {
    #expect(throws: DecodeError.outOfMemory) { try PageAlignedBuffer(minimumLength: Int.max) }
    #expect(throws: DecodeError.outOfMemory) { try PageAlignedBuffer(minimumLength: -1) }
}

// MARK: - ImageIOImageDecoder

private let decoder = ImageIOImageDecoder()

private func halvesJPEG(width: Int, height: Int, orientation: Int? = nil) -> Data {
    TestJPEGs.halves(width: width, height: height, orientation: orientation)
}

private func isRed(_ p: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 }
private func isBlue(_ p: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) -> Bool { p.b > 200 && p.g < 60 && p.r < 60 }

@Test func previewExactLevelSize() throws {
    let data = halvesJPEG(width: 3000, height: 2000)
    let info = try decoder.probe(data)
    let result = try decoder.preview(data, info: info, level: 2)
    #expect(result.level == 2)
    #expect(result.image.pixelSize == TileGrid(imageSize: info.pixelSize).levelSize(2))
    #expect(result.image.pixelSize == PixelSize(width: 750, height: 500))
    #expect(isRed(pixel(result.image, x: 187, y: 250)))
    #expect(isBlue(pixel(result.image, x: 562, y: 250)))
}

/// Previews are stored as in the file and drawn turned by the renderer (spec M3b §2.2): the preview of an EXIF 6
/// photo is kept, not refused for its aspect, and keeps the stored layout. A turned thumbnail would be 400x600 with
/// the colours top and bottom, not left and right. HEIC goes the same way (its orientation is a property too).
@Test func previewOfARotatedJPEGIsKept() throws {
    let jpeg = halvesJPEG(width: 1200, height: 800, orientation: 6)
    var heic = Data()
    if let image = CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
        heic = encode(image, type: .heic, properties: [kCGImagePropertyOrientation: 6])
    }
    for (name, data) in [("jpeg", jpeg), ("heic", heic)] {
        let info = try decoder.probe(data)
        #expect(info.pixelSize == PixelSize(width: 1200, height: 800) && info.orientation == .right, "\(name)")
        let result = try decoder.preview(data, info: info, level: 1)
        #expect(result.level == 1, "\(name)")
        #expect(result.image.pixelSize == PixelSize(width: 600, height: 400), "\(name)")
        #expect(isRed(pixel(result.image, x: 150, y: 200)), "\(name)")
        #expect(isBlue(pixel(result.image, x: 450, y: 200)), "\(name)")
    }
    // The JPEG's own decoder (libjpeg-turbo, DCT-scaled) keeps the stored layout as well.
    let turbo = try DecoderRegistry.decoder(for: jpeg).preview(jpeg, info: try decoder.probe(jpeg), level: 1)
    #expect(turbo.image.pixelSize == PixelSize(width: 600, height: 400))
    #expect(isRed(pixel(turbo.image, x: 150, y: 200)) && isBlue(pixel(turbo.image, x: 450, y: 200)))
}

/// Asked for the oriented size (`oriented`), ImageIO's thumbnail is turned: the thumbnails of the strip are.
@Test func orientedPreviewIsTurned() throws {
    let data = halvesJPEG(width: 1200, height: 800, orientation: 6)
    let image = try ImageIODecoder.preview(data, size: PixelSize(width: 400, height: 600), oriented: true)
    #expect(image.pixelSize == PixelSize(width: 400, height: 600))
    // EXIF 6 turns the stored picture clockwise: its left half (red) is the top.
    #expect(isRed(pixel(image, x: 200, y: 150)) && isBlue(pixel(image, x: 200, y: 450)))
    #expect(throws: DecodeError.unreadable) {
        try ImageIODecoder.preview(data, size: PixelSize(width: 600, height: 400), oriented: true)
    }
}

@Test func previewLevelClampedToGrid() throws {
    let data = jpegData(width: 300, height: 200)
    let result = try decoder.preview(data, info: decoder.probe(data), level: 5)
    #expect(result.level == 0)
    #expect(result.image.pixelSize == PixelSize(width: 300, height: 200))
}

@Test func previewOfTruncatedJPEGThrows() throws {
    let full = jpegData(width: 1200, height: 800)
    let info = try decoder.probe(full)
    let cut = full.prefix(Int(Double(full.count) * 0.6))
    #expect(throws: DecodeError.unreadable) { try decoder.preview(cut, info: info, level: 1) }
}

@Test func previewRejectsZeroSize() {
    let data = jpegData(width: 64, height: 48)
    #expect(throws: DecodeError.unreadable) { try ImageIODecoder.preview(data, size: PixelSize(width: 0, height: 0)) }
    #expect(throws: DecodeError.unreadable) { try ImageIODecoder.preview(data, size: PixelSize(width: 32, height: 0)) }
}

/// A size whose aspect differs from the image's would stretch the thumbnail; refuse instead.
@Test func previewRejectsMismatchedAspect() {
    let data = jpegData(width: 600, height: 400)
    #expect(throws: DecodeError.unreadable) { try ImageIODecoder.preview(data, size: PixelSize(width: 200, height: 300)) }
}

@Test func pngPreviewIsFullDecode() throws {
    let data = pngData(width: 1200, height: 800, rgba: (0, 1, 0, 1))
    let info = try decoder.probe(data)
    let result = try decoder.preview(data, info: info, level: 1)
    #expect(result.level == 0)
    #expect(result.image.pixelSize == PixelSize(width: 1200, height: 800))
}

/// Motion photos carry a video after the JPEG's EOI, far beyond any tail window.
@Test func motionPhotoOpens() throws {
    var data = jpegData(width: 64, height: 48)
    var rng = SystemRandomNumberGenerator()
    data.append(Data((0..<200 * 1024).map { _ in UInt8.random(in: 0...255, using: &rng) }))
    #expect(try decoder.decodeFull(data, info: decoder.probe(data)).pixelSize == PixelSize(width: 64, height: 48))
}

@Test func defaultFirstLookIsNil() throws {
    let data = jpegData(width: 64, height: 48)
    #expect(try decoder.firstLook(data, info: decoder.probe(data)) == nil)
}

@Test func registryFallsBackToImageIO() {
    #expect(DecoderRegistry.decoder(for: Data("hello".utf8)).name == "ImageIO")
}

@Test func imageIOProbeReadsOrientation() throws {
    for orientation in ImageOrientation.allCases {
        let info = try ImageIODecoder.probe(TestJPEGs.pattern(orientation: orientation.rawValue))
        #expect(info.orientation == orientation)
        #expect(info.colorSpace != nil)   // the launch pretag (`RenderLoop.expectColorSpace`) still has its space
        // The stored size is reported as stored, the oriented one swaps for 5...8.
        #expect(info.pixelSize == PixelSize(width: 24, height: 16))
        #expect(info.orientedSize == (orientation.swapsAxes ? PixelSize(width: 16, height: 24) : info.pixelSize))
    }
    #expect(try ImageIODecoder.probe(TestJPEGs.pattern()).orientation == .up)
}
