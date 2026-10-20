import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// Turns file bytes into the stored thumbnail (spec M2.5 §3.1, §3.4) and stored thumbnails back
/// into pictures for the strip. Pure functions with no state, so `ThumbnailStore` runs them inside
/// `DecodePool` off its actor.
///
/// A thumbnail is `maxSide` px on the long side (never upscaled), JPEG 0.8, tagged with the decoded
/// colour space so the source's ICC profile travels with it. It is turned by the file's EXIF orientation
/// (M3b spec §2.2), as the strip shows it and as a seed stretches it (`seedLevel`, drawn without a turn
/// of its own), whatever `exif-orientation` says; the `ImageInfo` stored with it stays the stored header. With
/// `exif-orientation=no` the strip turns the decoded cell back (`unturned`), so it shows the photo as stored.
/// Transparency is composited onto a neutral checkerboard (M3b spec §3), since JPEG stores no alpha.
public enum ThumbnailMaker {
    static let quality = 0.8

    /// Whether `data`, the start of a file, already holds a whole thumbnail's worth, a 1/8-scale picture: a
    /// progressive JPEG whose DC scans are complete, or a JPEG XL holding its DC image
    /// (`JxlDecoderGetDCByteCount`, from the headers and TOC; ~14 % of a transcoded JPEG). Anything else
    /// (baseline JPEG, modular JXL, other formats, a prefix cut before the DC) needs the whole file, and so does
    /// every JPEG XL with `jxl-dc-preview=no` (no DC thumbnail: the prefix would only be read twice).
    public static func isPrefixEnough(_ data: Data, jxl: JXLOptions = JXLSetting.shared.options) -> Bool {
        switch ImageFormat.detect(data) {
        case .jxl: return jxl.dcPreview && (JXLDecoder.dcByteCount(data).map { $0 <= data.count } ?? false)
        default: return JPEGScans.endOfDCScans(data) != nil
        }
    }

    /// Whether a DC-only picture of an image this size is as sharp as the thumbnail: the DC terms hold
    /// 1/8 of the resolution, so the long side must be at least 8 x `maxSide` (4096 px at 512). Below
    /// that the prefix would be stretched up and stored soft for good, so the caller reads the whole file.
    public static func prefixIsSharpEnough(_ info: ImageInfo, maxSide: Int) -> Bool {
        max(info.pixelSize.width, info.pixelSize.height) >= 8 * maxSide
    }

    /// The thumbnail of a whole file and the file's `ImageInfo` as the catalog keeps it (`catalogued`; stored with it to
    /// seed the pyramid).
    /// JPEG and JPEG XL go through `decoder.preview` at the coarsest pyramid level still at least `maxSide`
    /// (libjpeg-turbo's DCT scaling does up to 1/8 of the work there, libjxl's DC image is level 3), turned at
    /// the encode; other formats
    /// through ImageIO's thumbnailer with `CreateThumbnailWithTransform` (turned by ImageIO), which also
    /// refuses truncated files. Throws whatever the decoder throws.
    public static func make(from data: Data, decoder: any ImageDecoder, maxSide: Int) throws -> (jpeg: Data, info: ImageInfo) {
        let info = try decoder.probe(data)
        let target = thumbnailSize(of: info.pixelSize, maxSide: maxSide)
        // JPEG and JPEG XL go through the decoder: DCT scaling, or the 1:8 DC image (~15 ms at 147 MP against
        // 340–645 ms in ImageIO).
        if info.typeIdentifier != "public.jpeg", info.typeIdentifier != "public.jpeg-xl",
           let thumbnail = try? ImageIODecoder.preview(data, size: info.orientation.orientedSize(target),
                                                       oriented: true) {
            return (try encode(thumbnail, size: thumbnail.pixelSize, orientation: .up), info.catalogued)
        }
        // JPEG, JPEG XL, or a format ImageIO does not thumbnail but a specialist decodes.
        let pixels = try decoder.preview(data, info: info, level: level(for: info.pixelSize, maxSide: maxSide)).image
        return (try encode(pixels, size: target, orientation: info.orientation), info.catalogued)
    }

    /// The thumbnail from the start of a JPEG XL that holds its DC image (`isPrefixEnough`): the 1:8 picture,
    /// made smaller and turned at the encode. Throws `prefixTooCoarse` below 8 x `maxSide`, as `makeFromPrefix`,
    /// and whatever the decoder throws when the prefix gives no DC image.
    public static func makeFromJXLPrefix(_ prefix: Data, fullSize info: ImageInfo, maxSide: Int) throws -> Data {
        guard prefixIsSharpEnough(info, maxSide: maxSide) else { throw ThumbnailMakerError.prefixTooCoarse }
        let decoder = JXLDecoder(role: .other)
        guard let dc = try decoder.firstLook(prefix, info: info) else { throw DecodeError.unreadable }
        return try encode(dc.image, size: thumbnailSize(of: info.pixelSize, maxSide: maxSide), orientation: info.orientation)
    }

    /// The thumbnail from the start of a progressive JPEG (spec §3.4 item 3): the bytes up to the end of
    /// the DC scans plus an EOI, which is a complete coarse JPEG. The prefix must reach the first AC
    /// scan's header (what `isPrefixEnough` waits for), the only proof the DC scans are all there; the
    /// bytes past it are dropped, since a scan cut mid-way makes libjpeg warn and at 1/8 scale only the
    /// DC terms count anyway. libjpeg-turbo decodes it, ImageIO what turbo refuses (CMYK, gray).
    /// Throws `ThumbnailMakerError.prefixTooCoarse` for an image too small for a sharp DC picture
    /// (`prefixIsSharpEnough`), and otherwise when the DC scans are not proven complete, the decoders
    /// refuse the result or it is not an image of `info.pixelSize`; the caller then reads the whole file.
    public static func makeFromPrefix(_ prefix: Data, fullSize info: ImageInfo, maxSide: Int) throws -> Data {
        guard prefixIsSharpEnough(info, maxSide: maxSide) else { throw ThumbnailMakerError.prefixTooCoarse }
        guard let end = JPEGScans.endOfDCScans(prefix) else { throw DecodeError.unreadable }
        let coarse = Data(prefix.prefix(end)) + [0xFF, 0xD9]
        let level = level(for: info.pixelSize, maxSide: maxSide)
        let decoder = DecoderRegistry.decoder(for: coarse)
        // ImageIO's preview scales to whatever size it is told, so the header is checked here, not
        // left to libjpeg-turbo, whose refusal would only hand the file to ImageIO.
        guard try decoder.probe(coarse).pixelSize == info.pixelSize else { throw DecodeError.unreadable }
        let pixels = try decoder.preview(coarse, info: info, level: level).image
        let size = thumbnailSize(of: info.pixelSize, maxSide: maxSide)
        return try encode(pixels, size: size, orientation: info.orientation)
    }

    /// A stored thumbnail at most `maxPixel` on the long side, decoded now rather than at first draw:
    /// the strip's memory LRU holds cell-sized pictures, not the 512 px original.
    public static func decodeCell(_ jpeg: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// `image`, a thumbnail turned by `orientation` when it was made, turned back to the stored layout (its size is
    /// `orientation.orientedSize` of the thumbnail's: a quarter turn trades the sides). `image` itself for `.up`.
    /// A pixel copy through `ImageOrientation`'s own maps, on the cell-sized pictures the strip holds; nil when no
    /// bitmap context can be made for the image's colour space.
    public static func unturned(_ image: CGImage, from orientation: ImageOrientation) -> CGImage? {
        if orientation == .up { return image }
        let width = image.width, height = image.height
        let stored = orientation.orientedSize(PixelSize(width: width, height: height))
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let source = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: bitmapInfo),
              let target = CGContext(data: nil, width: stored.width, height: stored.height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo),
              let from = source.data, let to = target.data
        else { return nil }
        source.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let storedSize = CGSize(width: stored.width, height: stored.height)
        for y in 0..<stored.height {
            let row = to.assumingMemoryBound(to: UInt32.self) + y * target.bytesPerRow / 4
            for x in 0..<stored.width {
                let p = orientation.orientedPoint(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), storedSize: storedSize)
                let sx = min(max(Int(p.x.rounded(.down)), 0), width - 1), sy = min(max(Int(p.y.rounded(.down)), 0), height - 1)
                row[x] = from.assumingMemoryBound(to: UInt32.self)[sy * source.bytesPerRow / 4 + sx]
            }
        }
        return target.makeImage()
    }

    /// A stored thumbnail at its full size. Not used by the app at the moment (the hover preview it served gave way to
    /// the strip's magnification in Build 1.1); kept for the jump's first picture (Build 2).
    public static func decodeImage(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// A stored thumbnail as a pyramid level of the photo `info` describes (spec §5.1), so the jump shows it at
    /// once and the levels decoded later are simply finer levels of the same image: the finest level whose long
    /// side is at most the thumbnail's (level 5, 438 px, for 14000 px at 512), resampled to exactly its size. The
    /// thumbnail is turned, so the level is one of the oriented pyramid (`info.orientedSize`; `ImageCache.seed`
    /// builds that grid and the viewer draws it with `ImageInfo.drawOrientation(seeded: true)`).
    /// With no level that small (`thumb-size` below 512 and a photo above it) the coarsest level, stretched up:
    /// refusing would turn the jump preview off for every big photo at such a setting.
    ///
    /// Decoded like the viewer's ImageIO path: premultiplied BGRA in the thumbnail's own colour space, which is
    /// the source's (the thumbnail was encoded in the decoded pixels' space), so the seeded pyramid and the
    /// levels decoded later render alike. Nil when the JPEG does not decode, or when its aspect is not the
    /// level's: scaled to the level's long side, either side more than a pixel off (a stale thumbnail of
    /// another picture) — stretching it would show a distorted photo.
    public static func seedLevel(_ jpeg: Data, info: ImageInfo) -> LevelImage? {
        let grid = TileGrid(imageSize: info.orientedSize)
        guard let thumbnail = try? ImageIODecoder.decodeFull(jpeg) else { return nil }
        let thumbLong = max(thumbnail.pixelSize.width, thumbnail.pixelSize.height)
        let level = (0..<grid.levelCount).first { max(grid.levelSize($0).width, grid.levelSize($0).height) <= thumbLong }
            ?? grid.levelCount - 1
        let size = grid.levelSize(level)
        let scale = Double(max(size.width, size.height)) / Double(thumbLong)
        guard abs(Double(thumbnail.pixelSize.width) * scale - Double(size.width)) <= 1,
              abs(Double(thumbnail.pixelSize.height) * scale - Double(size.height)) <= 1,
              let pixels = try? resample(thumbnail, to: size)
        else { return nil }
        return LevelImage(image: pixels, level: level)
    }

    /// `image` resampled to exactly `size` (vImage high quality, on the premultiplied BGRA it expects) in a fresh
    /// page-aligned buffer, as the decoders hand levels to the cache.
    static func resample(_ image: DecodedImage, to size: PixelSize) throws -> DecodedImage {
        if image.pixelSize == size { return image }
        let (buffer, bytesPerRow) = try ImageIODecoder.allocateBGRA(width: size.width, height: size.height)
        var source = vImage_Buffer(data: image.buffer.bytes, height: vImagePixelCount(image.pixelSize.height),
                                   width: vImagePixelCount(image.pixelSize.width), rowBytes: image.bytesPerRow)
        var destination = vImage_Buffer(data: buffer.bytes, height: vImagePixelCount(size.height),
                                        width: vImagePixelCount(size.width), rowBytes: bytesPerRow)
        guard vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
        else { throw ThumbnailMakerError.cannotResample }
        return DecodedImage(pixelSize: size, bytesPerRow: bytesPerRow, buffer: buffer, colorSpace: image.colorSpace,
                            hasAlphaChannel: image.hasAlphaChannel)
    }

    /// `size` with its long side brought down to `maxSide`, the aspect kept to the nearest pixel; an image
    /// already that small keeps its size.
    static func thumbnailSize(of size: PixelSize, maxSide: Int) -> PixelSize {
        let long = max(size.width, size.height)
        guard long > maxSide, maxSide > 0 else { return size }
        func scaled(_ n: Int) -> Int { max(1, Int((Double(n) * Double(maxSide) / Double(long)).rounded())) }
        return PixelSize(width: scaled(size.width), height: scaled(size.height))
    }

    /// The coarsest pyramid level whose long side is still at least `maxSide`, so the last step to the
    /// thumbnail is always a downscale; level 0 for an image smaller than that.
    static func level(for size: PixelSize, maxSide: Int) -> Int {
        let grid = TileGrid(imageSize: size)
        var level = 0
        while level + 1 < grid.levelCount {
            let next = grid.levelSize(level + 1)
            guard max(next.width, next.height) >= maxSide else { break }
            level += 1
        }
        return level
    }

    /// `pixels` resampled to `size` (vImage high quality on the premultiplied BGRA, which is what its
    /// filter expects), turned by `orientation` (the result is `orientation.orientedSize(size)`) and encoded
    /// as JPEG in `pixels.colorSpace`, so the ICC profile is embedded.
    ///
    /// The destination context is opaque (`noneSkipFirst`) and ignores the alpha byte, rather than leaving the encoder
    /// to decide what a transparent pixel becomes; when the pixels have an alpha channel, the turned and scaled
    /// pixels with alpha < 255 are first composited onto the checkerboard (`compositeOnChecker`).
    private static func encode(_ pixels: DecodedImage, size: PixelSize, orientation: ImageOrientation) throws -> Data {
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let shown = orientation.orientedSize(size)
        guard let context = CGContext(data: nil, width: shown.width, height: shown.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: pixels.colorSpace, bitmapInfo: bitmapInfo),
              let destinationBytes = context.data
        else { throw ThumbnailMakerError.cannotEncode }
        if orientation == .up {
            var source = vImage_Buffer(data: pixels.buffer.bytes, height: vImagePixelCount(pixels.pixelSize.height),
                                       width: vImagePixelCount(pixels.pixelSize.width), rowBytes: pixels.bytesPerRow)
            var destination = vImage_Buffer(data: destinationBytes, height: vImagePixelCount(size.height),
                                            width: vImagePixelCount(size.width), rowBytes: context.bytesPerRow)
            let status = pixels.pixelSize == size
                ? vImageCopyBuffer(&source, &destination, 4, vImage_Flags(kvImageNoFlags))
                : vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
            guard status == kvImageNoError else { throw ThumbnailMakerError.cannotEncode }
        } else {
            guard let scaled = try? resample(pixels, to: size) else { throw ThumbnailMakerError.cannotEncode }
            guard turn(scaled, by: orientation, into: destinationBytes, bytesPerRow: context.bytesPerRow)
            else { throw ThumbnailMakerError.cannotEncode }
        }
        if pixels.hasAlphaChannel {
            compositeOnChecker(destinationBytes, width: shown.width, height: shown.height, bytesPerRow: context.bytesPerRow)
        }
        guard let image = context.makeImage() else { throw ThumbnailMakerError.cannotEncode }

        let out = NSMutableData()
        guard let jpeg = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            throw ThumbnailMakerError.cannotEncode
        }
        CGImageDestinationAddImage(jpeg, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(jpeg) else { throw ThumbnailMakerError.cannotEncode }
        return out as Data
    }
}

extension ThumbnailMaker {
    /// The checkerboard under a thumbnail's transparent pixels: #FFFFFF in the top-left cell, #CCCCCC beside it (the
    /// viewer's `checker-colors=light`), each cell 1/16 of the thumbnail's long side.
    static let checkerColors: (UInt8, UInt8) = (0xff, 0xcc)

    /// Composites every pixel of the premultiplied BGRA `bytes` whose alpha is below 255 onto the checkerboard, in
    /// linear light as the viewer does (`c + (1 - a) · cell`, c the premultiplied colour linearised as `lin(s / a) · a`,
    /// the sRGB curve), and makes it opaque; opaque pixels are left as they are. Through tables, no `pow` per pixel: the
    /// straight colour rounded to a byte, then `decodeTable`; the result through `encodeTable` (4096 steps of linear
    /// light: at most 0.8 of an encoded byte apart in the darkest codes, finer above).
    static func compositeOnChecker(_ bytes: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        let cell = max(1, Int((Double(max(width, height)) / 16).rounded()))
        let light = decodeTable[Int(checkerColors.0)], dark = decodeTable[Int(checkerColors.1)]
        let steps = Float(encodeTable.count - 1)
        for y in 0..<height {
            let row = bytes.assumingMemoryBound(to: UInt8.self) + y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4, a = p[3]
                guard a < 255 else { continue }
                let back = (x / cell + y / cell) % 2 == 0 ? light : dark, alpha = Float(a) / 255
                for c in 0..<3 {
                    // The straight byte: round(s * 255 / a), clamped (s > a is out of range).
                    let straight = a == 0 ? 0 : min((Int(p[c]) * 255 + Int(a) / 2) / Int(a), 255)
                    let lit = decodeTable[straight] * alpha + (1 - alpha) * back
                    p[c] = encodeTable[Int((min(max(lit, 0), 1) * steps).rounded())]
                }
                p[3] = 255
            }
        }
    }

    /// The sRGB curve as tables: byte to linear light, and linear light in 4096 steps to the rounded byte.
    private static let decodeTable: [Float] = (0..<256).map { i in
        let v = Double(i) / 255
        return Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
    }
    private static let encodeTable: [UInt8] = (0..<4096).map { i in
        let c = Double(i) / 4095
        return UInt8(((c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255).rounded())
    }

    /// `image` (stored layout) turned and mirrored by `orientation` into `destination`, which holds
    /// `orientation.orientedSize` of it with rows `bytesPerRow` apart: vImage's reflections and quarter turns, the
    /// transpose (5) and the transverse (7) as a left-right mirror and then a turn. The thumbnail is the picture
    /// CoreGraphics shows for the file (`thumbnailOrientedLikeCoreGraphics`). False when vImage fails.
    private static func turn(_ image: DecodedImage, by orientation: ImageOrientation,
                             into destination: UnsafeMutableRawPointer, bytesPerRow: Int) -> Bool {
        let shown = orientation.orientedSize(image.pixelSize)
        var source = vImage_Buffer(data: image.buffer.bytes, height: vImagePixelCount(image.pixelSize.height),
                                   width: vImagePixelCount(image.pixelSize.width), rowBytes: image.bytesPerRow)
        var target = vImage_Buffer(data: destination, height: vImagePixelCount(shown.height),
                                   width: vImagePixelCount(shown.width), rowBytes: bytesPerRow)
        let flags = vImage_Flags(kvImageNoFlags)
        let none: [UInt8] = [0, 0, 0, 0]
        func rotate(_ from: inout vImage_Buffer, _ turn: Int) -> vImage_Error {
            vImageRotate90_ARGB8888(&from, &target, UInt8(turn), none, flags)
        }
        switch orientation {
        case .up: return vImageCopyBuffer(&source, &target, 4, flags) == kvImageNoError
        case .upMirrored: return vImageHorizontalReflect_ARGB8888(&source, &target, flags) == kvImageNoError
        case .down: return rotate(&source, kRotate180DegreesClockwise) == kvImageNoError
        case .downMirrored: return vImageVerticalReflect_ARGB8888(&source, &target, flags) == kvImageNoError
        case .right: return rotate(&source, kRotate90DegreesClockwise) == kvImageNoError
        case .left: return rotate(&source, kRotate90DegreesCounterClockwise) == kvImageNoError
        case .leftMirrored, .rightMirrored:
            guard let (buffer, rowBytes) = try? ImageIODecoder.allocateBGRA(width: image.pixelSize.width,
                                                                          height: image.pixelSize.height)
            else { return false }
            var mirrored = vImage_Buffer(data: buffer.bytes, height: source.height, width: source.width,
                                         rowBytes: rowBytes)
            guard vImageHorizontalReflect_ARGB8888(&source, &mirrored, flags) == kvImageNoError else { return false }
            let turn = orientation == .leftMirrored ? kRotate90DegreesCounterClockwise : kRotate90DegreesClockwise
            return withExtendedLifetime(buffer) { rotate(&mirrored, turn) == kvImageNoError }
        }
    }
}

/// Why a thumbnail was not made, beyond the decoders' own `DecodeError`.
public enum ThumbnailMakerError: Error, Equatable {
    /// The image is too small for its DC-only prefix to make a sharp thumbnail; read the whole file.
    case prefixTooCoarse
    /// The pixels decoded but could not be resampled or encoded (no bitmap context for the colour
    /// space, vImage or the JPEG encoder failed).
    case cannotEncode
    /// A stored thumbnail decoded but vImage could not resample it to the seeded level's size.
    case cannotResample
}
