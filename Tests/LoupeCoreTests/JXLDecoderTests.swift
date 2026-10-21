import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

private let haveCjxl = TestJXL.available
private let jxl = JXLDecoder()

private func channels(_ d: DecodedImage, x: Int, y: Int) -> [Int] {
    let p = d.buffer.bytes.load(fromByteOffset: y * d.bytesPerRow + x * 4, as: UInt32.self)
    return [Int(p & 0xFF), Int((p >> 8) & 0xFF), Int((p >> 16) & 0xFF), Int(p >> 24)]
}

/// Encodes `png` (any input cjxl reads, named `inputName`) to JXL with the reference encoder.
private func cjxl(_ png: Data, arguments: [String] = [], inputName: String = "in.png") throws -> Data {
    try TestJXL.encode(png, arguments: arguments, inputName: inputName)
}

private func gradientPNG(width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                                                          CGColor(red: 0, green: 0, blue: 1, alpha: 1)] as CFArray,
                              locations: nil)!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    return TestJPEGs.encode(context.makeImage()!, type: .png)
}

@Test(.enabled(if: haveCjxl)) func jxlFullMatchesSource() throws {
    let png = gradientPNG(width: 1200, height: 800)
    let data = try cjxl(png)
    let info = try jxl.probe(data)
    #expect(info.pixelSize == PixelSize(width: 1200, height: 800))
    #expect(info.typeIdentifier == "public.jpeg-xl")
    #expect(info.fileSize == data.count)
    let mine = try jxl.decodeFull(data, info: info)
    let reference = try ImageIODecoder.decodeFull(png)
    #expect(mine.pixelSize == reference.pixelSize)
    #expect(mine.bytesPerRow == reference.bytesPerRow)
    for x in [0, 600, 1199] {
        for y in [0, 400, 799] {
            let a = channels(mine, x: x, y: y), b = channels(reference, x: x, y: y)
            #expect(a[3] == 0xFF)
            for c in 0..<3 { #expect(abs(a[c] - b[c]) <= 4, "channel \(c) at \(x),\(y): \(a[c]) vs \(b[c])") }
        }
    }
}

/// No level 3 in a 1200 px grid: previews are the full decode made smaller, never past the grid's last level.
@Test(.enabled(if: haveCjxl)) func jxlPreviewStaysInTheGrid() throws {
    let data = try cjxl(gradientPNG(width: 1200, height: 800))
    let info = try jxl.probe(data)
    let grid = TileGrid(imageSize: info.pixelSize)
    for requested in [0, 2, 9] {
        let preview = try jxl.forRole(.other).preview(data, info: info, level: requested)
        let level = min(requested, grid.levelCount - 1)
        #expect(preview.level == level && preview.image.pixelSize == grid.levelSize(level), "\(requested)")
    }
}

@Test func jxlGarbageThrows() {
    // Fixed bytes (random ones can by chance form a plausible header); verified to be rejected by probe and decode.
    let data = Data([0xFF, 0x0A] + (0..<100).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
    let info = ImageInfo(pixelSize: PixelSize(width: 1, height: 1), typeIdentifier: "public.jpeg-xl", isProgressive: false,
                         fileSize: data.count, colorSpaceName: nil)
    #expect(throws: DecodeError.self) { try jxl.probe(data) }
    #expect(throws: DecodeError.self) { try jxl.decodeFull(data, info: info) }
}

@Test(.enabled(if: haveCjxl)) func jxlTruncatedThrows() throws {
    let data = try cjxl(gradientPNG(width: 1200, height: 800))
    let info = try jxl.probe(data)
    #expect(throws: DecodeError.self) { try jxl.decodeFull(data.prefix(data.count / 2), info: info) }
}

@Test(.enabled(if: haveCjxl)) func jxlAlphaIsPremultiplied() throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 0.5])!)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let data = try cjxl(TestJPEGs.encode(context.makeImage()!, type: .png), arguments: ["-d", "0"])
    let image = try jxl.decodeFull(data, info: try jxl.probe(data))
    let px = channels(image, x: 10, y: 10)  // B, G, R, A
    #expect(abs(px[3] - 128) <= 1)
    #expect(abs(px[2] - 128) <= 2, "red must be premultiplied: \(px)")
    #expect(px[0] == 0 && px[1] == 0)
}

@Test(.enabled(if: haveCjxl)) func jxlReportsItsAlphaChannel() throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 0.25])!)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let translucent = try cjxl(TestJPEGs.encode(context.makeImage()!, type: .png), arguments: ["-d", "0"])
    let image = try jxl.decodeFull(translucent, info: try jxl.probe(translucent))
    #expect(image.hasAlphaChannel && image.hasTransparentPixel())
    let opaque = try cjxl(gradientPNG(width: 64, height: 32))
    #expect(!(try jxl.decodeFull(opaque, info: try jxl.probe(opaque))).hasAlphaChannel)
}

@Test(.enabled(if: haveCjxl)) func jxlKeepsEmbeddedProfile() throws {
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let data = try cjxl(gradientPNG(width: 200, height: 100, space: p3))
    let info = try jxl.probe(data)
    let image = try jxl.decodeFull(data, info: info)
    #expect(image.colorSpace.model == .rgb)
    // An ICC-based space has no registered name; what matters is that it is not the sRGB fallback.
    #expect(image.colorSpace.name as String? != CGColorSpace.sRGB as String)
    #expect(image.colorSpace.copyICCData() != nil)
}

@Test(.enabled(if: haveCjxl)) func registryRoutesJXL() throws {
    let data = try cjxl(gradientPNG(width: 100, height: 100))
    #expect(DecoderRegistry.decoder(for: data).name == "libjxl+dc")
}

@Test func brokenJXLThrowsThroughRegistry() throws {
    // Both libjxl and the ImageIO fallback reject it; the registry must surface a clean throw, not crash.
    let data = Data([0xFF, 0x0A, 1, 2, 3])
    #expect(throws: DecodeError.self) { try DecoderRegistry.decoder(for: data).probe(data) }
}

@Test(.enabled(if: haveCjxl)) func jxlPaddedWidthKeepsPixelsAndZeroPadding() throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: 37, height: 21, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(colorSpace: space, components: [0, 1, 0, 1])!)  // opaque green
    context.fill(CGRect(x: 0, y: 0, width: 37, height: 21))
    context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 0.5])!)  // 50% red, top-left in image space
    context.setBlendMode(.copy)  // store the half-transparent pixels instead of compositing over the green
    context.fill(CGRect(x: 0, y: 11, width: 10, height: 10))
    let data = try cjxl(TestJPEGs.encode(context.makeImage()!, type: .png), arguments: ["-d", "0"])
    let image = try jxl.decodeFull(data, info: try jxl.probe(data))
    #expect(image.pixelSize == PixelSize(width: 37, height: 21))
    #expect(image.bytesPerRow == 192)  // 37 * 4 = 148, rounded up to 64
    let red = channels(image, x: 0, y: 0), green = channels(image, x: 36, y: 20)  // B, G, R, A
    #expect(abs(red[3] - 128) <= 1 && abs(red[2] - 128) <= 2 && red[0] == 0 && red[1] == 0, "\(red)")
    #expect(green == [0, 255, 0, 255], "\(green)")
    for y in 0..<21 {
        for offset in 148..<192 {
            #expect(image.buffer.bytes.load(fromByteOffset: y * 192 + offset, as: UInt8.self) == 0, "padding row \(y) byte \(offset)")
        }
    }
}

@Test(.enabled(if: haveCjxl)) func jxlProbeReadsOrientation() throws {
    // cjxl keeps a JPEG's EXIF orientation in the basic info (the pixels stay as stored), which is what the probe reads.
    for orientation in [1, 3, 6, 8] {
        let data = try cjxl(TestJPEGs.pattern(orientation: orientation), inputName: "in.jpg")
        let info = try jxl.probe(data)
        #expect(info.orientation.rawValue == orientation, "\(orientation)")
        #expect(info.colorSpace != nil, "\(orientation)")
        #expect(info.pixelSize == PixelSize(width: 24, height: 16))
    }
}

/// A horizontal gray ramp in Generic Gray Gamma 2.2 as PNG (the gray profile is embedded).
private func grayPNG(width: Int, height: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let gradient = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0.1, alpha: 1), CGColor(gray: 0.9, alpha: 1)] as CFArray,
                              locations: nil)!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
    return TestJPEGs.encode(context.makeImage()!, type: .png)
}

@Test(.enabled(if: haveCjxl)) func grayJXLIsNotSRGB() throws {
    let data = try cjxl(grayPNG(width: 256, height: 64))
    let info = try jxl.probe(data)
    let image = try jxl.decodeFull(data, info: info)
    // Gray decodes to Display P3, like the ImageIO path, and the probe says so before the pixels exist (the
    // viewer tags its layer from it): a wrong probe space would cost a re-tag, and so a frame, at launch.
    #expect(image.colorSpace.name as String? == CGColorSpace.displayP3 as String)
    #expect(info.colorSpace?.name as String? == CGColorSpace.displayP3 as String)
    #expect(info.colorSpaceName == "Gray → Display P3")
    let left = channels(image, x: 4, y: 10), right = channels(image, x: 250, y: 10)
    #expect(left[0] == left[1] && left[1] == left[2], "gray stays neutral")
    #expect(right[0] > left[0] + 100)
}

@Test(.enabled(if: haveCjxl)) func linearJXLKeepsLinear() throws {
    let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
    let data = try cjxl(gradientPNG(width: 256, height: 64, space: linear))
    let info = try jxl.probe(data)
    let image = try jxl.decodeFull(data, info: info)
    #expect(image.colorSpace.model == .rgb)
    #expect(image.colorSpace.name as String? != CGColorSpace.sRGB as String)
    #expect(info.colorSpace?.copyICCData() as Data? == image.colorSpace.copyICCData() as Data?)
    #expect(info.colorSpaceName != nil && info.colorSpaceName != "ICC (unnamed)")
    #expect(info.colorSpaceName != "sRGB")
    // The renderer's curve for it: a table whose forward half is the identity (linear light = code / 255).
    guard case .table(let forward, _) = ColorCurve.of(image.colorSpace) else {
        Issue.record("a linear profile must give a table, not the sRGB fast path")
        return
    }
    for code in 0..<256 { #expect(abs(forward[code] - Float(code) / 255) < 1e-4, "code \(code)") }
}

// MARK: - Gray photos are converted to Display P3 (M3b spec §5)

/// 256 x 4 ramp: the pixel in column x has gray code x (alpha 64 * (row + 1) - 1 per row when `alpha`), in `space`.
private func grayRampPNG(space: CGColorSpace, alpha: Bool = false) -> Data {
    var bytes = [UInt8]()
    for row in 0..<4 { for x in 0..<256 { bytes.append(UInt8(x)); if alpha { bytes.append(UInt8(64 * (row + 1) - 1)) } } }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let info = alpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.none
    let image = CGImage(width: 256, height: 4, bitsPerComponent: 8, bitsPerPixel: alpha ? 16 : 8, bytesPerRow: alpha ? 512 : 256,
                        space: space, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue), provider: provider, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)!
    return TestJPEGs.encode(image, type: .png)
}

/// A gray space of gamma `gamma` (a calibrated gray profile: the ImageIO PNG carries it as an ICC profile).
private func calibratedGray(gamma: CGFloat) -> CGColorSpace {
    CGColorSpace(calibratedGrayWhitePoint: [0.9505, 1, 1.089], blackPoint: [0, 0, 0], gamma: gamma)!
}

/// The pixels of the JXL decode of `png` (lossless) against ImageIO's decode of the same PNG, which CoreGraphics
/// converts from the gray profile to Display P3: every channel of every pixel within `tolerance` codes.
private func expectGrayMatchesCoreGraphics(_ png: Data, tolerance: Int, _ label: String) throws {
    let data = try cjxl(png, arguments: ["-d", "0"])
    let info = try jxl.probe(data)
    let mine = try jxl.decodeFull(data, info: info)
    let reference = try ImageIODecoder.decodeFull(png)
    #expect(mine.colorSpace.name as String? == CGColorSpace.displayP3 as String, "\(label)")
    #expect(info.colorSpace?.name as String? == CGColorSpace.displayP3 as String, "\(label)")
    var worst = 0
    for y in 0..<4 {
        for x in 0..<256 {
            let a = channels(mine, x: x, y: y), b = channels(reference, x: x, y: y)
            for c in 0..<4 { worst = max(worst, abs(a[c] - b[c])) }
        }
    }
    #expect(worst <= tolerance, "\(label): \(worst) codes from CoreGraphics' gray to Display P3")
}

@Test(.enabled(if: haveCjxl)) func linearGrayJXLMatchesCoreGraphics() throws {
    try expectGrayMatchesCoreGraphics(grayRampPNG(space: CGColorSpace(name: CGColorSpace.linearGray)!), tolerance: 1, "linear gray")
}

@Test(.enabled(if: haveCjxl)) func gamma18GrayJXLMatchesCoreGraphics() throws {
    try expectGrayMatchesCoreGraphics(grayRampPNG(space: calibratedGray(gamma: 1.8)), tolerance: 1, "gamma 1.8 gray")
}

@Test(.enabled(if: haveCjxl)) func grayAlphaJXLMatchesCoreGraphics() throws {
    // Straight alpha in the file; the decode premultiplies after the map. One code more for the rounding of that.
    try expectGrayMatchesCoreGraphics(grayRampPNG(space: CGColorSpace(name: CGColorSpace.linearGray)!, alpha: true), tolerance: 2,
                                      "linear gray with alpha")
}

@Test(.enabled(if: haveCjxl)) func srgbCurveGrayJXLKeepsItsCodes() throws {
    // A PGM has no profile: JXL's gray is the sRGB curve, which is Display P3's, so no map (codes untouched).
    var pgm = Data("P5\n256 4\n255\n".utf8)
    for _ in 0..<4 { pgm.append(contentsOf: (0...255).map { UInt8($0) }) }
    let data = try cjxl(pgm, arguments: ["-d", "0"], inputName: "in.pgm")
    let info = try jxl.probe(data)
    let image = try jxl.decodeFull(data, info: info)
    #expect(info.colorSpaceName == "Gray → Display P3")
    for x in 0..<256 {
        let p = channels(image, x: x, y: 1)
        #expect(p[0] == x && p[1] == x && p[2] == x, "code \(x) came out as \(p)")
    }
}

/// Loupe links its own libjxl (scripts/build-deps.sh); stats name it so.
@Test func jxlDecoderNamesLoupesLibjxl() {
    #expect(JXLDecoder().name == "libjxl+dc")
}

@Test func jxlRolePicksThreads() throws {
    let options = JXLOptions(threadsCurrent: 9, threadsOther: 3)
    let current = try #require(JXLDecoder(options: options).forRole(.current) as? JXLDecoder)
    let other = try #require(JXLDecoder(options: options).forRole(.other) as? JXLDecoder)
    #expect(current.threads == 9 && other.threads == 3)
}

@Test func fallbackPassesTheRole() throws {
    let fallback = FallbackDecoder(primary: JXLDecoder(options: JXLOptions(threadsOther: 2)), fallback: ImageIOImageDecoder())
    let other = try #require(fallback.forRole(.other) as? FallbackDecoder)
    #expect((other.primary as? JXLDecoder)?.threads == 2)
}

@Test(.enabled(if: haveCjxl)) func jxlOneThreadSamePixels() throws {
    let data = try cjxl(gradientPNG(width: 300, height: 200))
    let info = try jxl.probe(data)
    let one = try #require(JXLDecoder(options: JXLOptions(threadsOther: 1)).forRole(.other) as? JXLDecoder)
    let a = try one.decodeFull(data, info: info), b = try JXLDecoder(options: JXLOptions(threadsCurrent: 10)).decodeFull(data, info: info)
    #expect(memcmp(a.buffer.bytes, b.buffer.bytes, a.bytesPerRow * a.pixelSize.height) == 0)
}

// MARK: - The 1:8 DC image (Loupe's libjxl)

/// Largest per-channel difference between the DC level and `full` averaged over each 8x8 block, at `samples` blocks
/// spread over the image (the last column and row included).
private func dcDifference(_ dc: DecodedImage, _ full: DecodedImage, samples: Int = 12) -> Int {
    var worst = 0
    let cols = dc.pixelSize.width, rows = dc.pixelSize.height
    var points = [(0, 0), (cols - 1, rows - 1), (cols - 1, 0), (0, rows - 1)]
    for i in 1..<samples { points.append((cols * i / samples, rows * (samples - i) / samples)) }
    for (bx, by) in points {
        var sum = [0, 0, 0], n = 0
        for y in by * 8..<min(full.pixelSize.height, by * 8 + 8) {
            for x in bx * 8..<min(full.pixelSize.width, bx * 8 + 8) {
                let c = channels(full, x: x, y: y)
                for k in 0..<3 { sum[k] += c[k] }
                n += 1
            }
        }
        let d = channels(dc, x: bx, y: by)
        for k in 0..<3 { worst = max(worst, abs(Int((Double(sum[k]) / Double(n)).rounded()) - d[k])) }
    }
    return worst
}

private let dcOff = JXLDecoder(options: JXLOptions(dcPreview: false))

@Test(.enabled(if: haveCjxl)) func jxlFirstLookIsLevel3() throws {
    let data = try cjxl(TestJPEGs.gradient(width: 2400, height: 1800), inputName: "in.jpg")
    let info = try jxl.probe(data)
    let look = try #require(try jxl.firstLook(data, info: info))
    #expect(look.level == 3)
    #expect(look.image.pixelSize == TileGrid(imageSize: info.pixelSize).levelSize(3))
    #expect(dcDifference(look.image, try jxl.decodeFull(data, info: info)) <= 3)
}

@Test(.enabled(if: haveCjxl)) func jxlOddSizeDC() throws {
    let data = try cjxl(gradientPNG(width: 2401, height: 1777))
    let info = try jxl.probe(data)
    let look = try #require(try jxl.firstLook(data, info: info))
    #expect(look.image.pixelSize == PixelSize(width: 301, height: 223))
    #expect(dcDifference(look.image, try jxl.decodeFull(data, info: info)) <= 3)
}

@Test(.enabled(if: haveCjxl)) func jxlCoarsePreviewFromDC() throws {
    let data = try cjxl(TestJPEGs.gradient(width: 4800, height: 3600), inputName: "in.jpg")
    let info = try jxl.probe(data)
    let preview = try jxl.preview(data, info: info, level: 4)
    #expect(preview.level == 3)
    #expect(preview.image.pixelSize == TileGrid(imageSize: info.pixelSize).levelSize(3))
}

/// Neighbours and thumbnails get finer previews made smaller (the cache keeps a screen-size level).
@Test(.enabled(if: haveCjxl)) func jxlFinerPreviewsAreDownscaled() throws {
    let data = try cjxl(gradientPNG(width: 2400, height: 1800))
    let info = try jxl.probe(data)
    let grid = TileGrid(imageSize: info.pixelSize)
    let other = jxl.forRole(.other)
    for level in [1, 2] {
        let preview = try other.preview(data, info: info, level: level)
        #expect(preview.level == level && preview.image.pixelSize == grid.levelSize(level), "\(level)")
    }
    #expect(try other.preview(data, info: info, level: 0).image.pixelSize == info.pixelSize)
}

/// The current photo's finer preview is the full image itself: the cache keeps it at full resolution anyway
/// (`cache-full`), so one decode serves both, and the GPU builds the coarser levels.
@Test(.enabled(if: haveCjxl)) func jxlCurrentPreviewIsTheFullImage() throws {
    let data = try cjxl(gradientPNG(width: 2400, height: 1800))
    let info = try jxl.probe(data)
    let preview = try jxl.forRole(.current).preview(data, info: info, level: 1)
    #expect(preview.level == 0 && preview.image.pixelSize == info.pixelSize)
    #expect(try jxl.forRole(.current).preview(data, info: info, level: 4).level == 3)
}

@Test(.enabled(if: haveCjxl)) func jxlFromPNGHasNoFirstLook() throws {
    let data = try cjxl(gradientPNG(width: 2400, height: 1800), arguments: ["-d", "0"])
    let info = try jxl.probe(data)
    #expect(try jxl.firstLook(data, info: info) == nil)
    let preview = try jxl.forRole(.other).preview(data, info: info, level: 3)
    #expect(preview.level == 3 && preview.image.pixelSize == TileGrid(imageSize: info.pixelSize).levelSize(3))
    #expect(jxl.previewNeedsFullDecode(data, info: info, level: 3))
}

@Test(.enabled(if: haveCjxl)) func jxlAlphaHasNoFirstLook() throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: 2400, height: 1800, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1800))
    let data = try cjxl(TestJPEGs.encode(context.makeImage()!, type: .png), arguments: ["-d", "1"])
    let info = try jxl.probe(data)
    #expect(try jxl.firstLook(data, info: info) == nil)
}

@Test(.enabled(if: haveCjxl)) func jxlDCOff() throws {
    let data = try cjxl(TestJPEGs.gradient(width: 2400, height: 1800), inputName: "in.jpg")
    let info = try dcOff.probe(data)
    #expect(try dcOff.firstLook(data, info: info) == nil)
    #expect(dcOff.previewNeedsFullDecode(data, info: info, level: 3))
    #expect(!jxl.previewNeedsFullDecode(data, info: info, level: 3))
    #expect(jxl.previewNeedsFullDecode(data, info: info, level: 2))
}

@Test(.enabled(if: haveCjxl)) func jxlGrayDC() throws {
    let data = try cjxl(grayPNG(width: 2400, height: 600))
    let info = try jxl.probe(data)
    let look = try #require(try jxl.firstLook(data, info: info))
    #expect(look.image.colorSpace.name == (try jxl.decodeFull(data, info: info)).colorSpace.name)
    #expect(dcDifference(look.image, try jxl.decodeFull(data, info: info)) <= 3)
}

@Test(.enabled(if: haveCjxl)) func jxlDCKeepsStoredOrientation() throws {
    let data = try cjxl(TestJPEGs.halves(width: 2400, height: 1800, orientation: 6), inputName: "in.jpg")
    let info = try jxl.probe(data)
    #expect(info.orientation.rawValue == 6)
    let look = try #require(try jxl.firstLook(data, info: info))
    #expect(look.image.pixelSize == PixelSize(width: 300, height: 225))
    let left = channels(look.image, x: 20, y: 100), right = channels(look.image, x: 280, y: 100)
    // BGRA: red stored on the left, blue on the right.
    #expect(left[2] > 200 && left[0] < 60 && right[0] > 200 && right[2] < 60)
}

@Test(.enabled(if: haveCjxl)) func jxlSmallImageHasNoLevel3() throws {
    let data = try cjxl(TestJPEGs.gradient(width: 1600, height: 1200), inputName: "in.jpg")
    let info = try jxl.probe(data)
    #expect(try jxl.firstLook(data, info: info) == nil)
}

/// The app's JXL decoder is the registry's `FallbackDecoder`: it must answer `previewNeedsFullDecode` as libjxl does,
/// or the cache's gate for big decodes lets JXL neighbours' full decodes through three at a time.
@Test(.enabled(if: haveCjxl)) func registryJXLAsksForTheGate() throws {
    let data = try cjxl(TestJPEGs.gradient(width: 2400, height: 1800), inputName: "in.jpg")
    let decoder = DecoderRegistry.decoder(for: data).forRole(.other)
    let info = try decoder.probe(data)
    #expect(decoder.previewNeedsFullDecode(data, info: info, level: 2))
    #expect(!decoder.previewNeedsFullDecode(data, info: info, level: 3))
}
