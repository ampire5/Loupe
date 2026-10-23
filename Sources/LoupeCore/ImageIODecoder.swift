import CoreGraphics
import Foundation
import ImageIO

/// A fully decoded image: BGRA8 premultiplied pixels in a page-aligned buffer.
public struct DecodedImage: Sendable {
    public let pixelSize: PixelSize
    /// `width * 4` rounded up to 64, so rows stay cache-line aligned.
    public let bytesPerRow: Int
    /// BGRA8 premultiplied (`premultipliedFirst | byteOrder32Little`) in `colorSpace`.
    public let buffer: PageAlignedBuffer
    /// The image's own colour space when it is RGB and a bitmap context accepts it (sRGB stays
    /// sRGB, Adobe RGB stays Adobe RGB, no conversion); Display P3 for everything else.
    public let colorSpace: CGColorSpace
    /// Whether the source has an alpha channel at all, from the decoder: false when every alpha byte is 255 by
    /// construction (JPEG, an RGB PNG), so the upload skips its scan for transparent pixels (`TiledImage.hasAlpha`).
    /// True does not mean any pixel is transparent: a PNG may carry a fully opaque alpha channel.
    public let hasAlphaChannel: Bool

    /// Public so other modules (the renderer's tests) can wrap their own pixels. `hasAlphaChannel` defaults to true,
    /// which only costs the upload a scan.
    public init(pixelSize: PixelSize, bytesPerRow: Int, buffer: PageAlignedBuffer, colorSpace: CGColorSpace,
                hasAlphaChannel: Bool = true) {
        self.pixelSize = pixelSize
        self.bytesPerRow = bytesPerRow
        self.buffer = buffer
        self.colorSpace = colorSpace
        self.hasAlphaChannel = hasAlphaChannel
    }

    /// The row of a `width`-pixel image as decoders lay it out: BGRA8, rounded up to 64 bytes.
    public static func bytesPerRow(width: Int) -> Int { (width * 4 + 63) / 64 * 64 }

    /// The buffer a decode of a `size` image fills: what a full decode holds in memory (`CacheGoal.ready`'s cost).
    public static func byteCount(_ size: PixelSize) -> Int { bytesPerRow(width: size.width) * size.height }
}

extension DecodedImage {
    /// Whether any pixel's alpha byte is below 255 (M3b spec §3): one pass over the pixels (not the row padding), rows
    /// in parallel bands, each band AND-reducing 8-byte words so the loop vectorises; a band stops at its first row with
    /// a transparent pixel. Opaque pixels are the only ones whose alpha byte is 0xFF, so the AND of a row's words keeps
    /// 0xFF in its alpha bytes exactly when the whole row is opaque.
    public func hasTransparentPixel() -> Bool {
        let width = pixelSize.width, height = pixelSize.height
        guard width > 0, height > 0 else { return false }
        let bandRows = 64, bands = (height + bandRows - 1) / bandRows
        let base = UnsafeRawPointer(buffer.bytes), stride = bytesPerRow
        let found = UnsafeMutableBufferPointer<Bool>.allocate(capacity: bands)
        defer { found.deallocate() }
        found.initialize(repeating: false)
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            for y in (band * bandRows)..<min(height, (band + 1) * bandRows) {
                let row = base + y * stride
                var and64: UInt64 = .max
                let words = width / 2
                for i in 0..<words { and64 &= row.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) }
                var opaque = and64 & 0xFF00_0000_FF00_0000 == 0xFF00_0000_FF00_0000
                if width & 1 == 1 { opaque = opaque && row.load(fromByteOffset: (width - 1) * 4 + 3, as: UInt8.self) == 0xFF }
                if !opaque {
                    found[band] = true
                    return
                }
            }
        }
        return found.contains(true)
    }
}

/// Decodes through ImageIO, the fastest path measured in M0 for JPEG/PNG/TIFF/HEIC on this hardware.
public enum ImageIODecoder {
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// Reads header-level facts without decoding pixels. Throws `.unreadable` for anything
    /// ImageIO cannot recognise.
    public static func probe(_ data: Data) throws -> ImageInfo {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw DecodeError.unreadable }
        return try probe(source, fileSize: data.count)
    }

    /// `probe` of an open source (the info panel's metadata read opens the file by URL, `PhotoMetadata.read`).
    public static func probe(_ source: CGImageSource, fileSize: Int) throws -> ImageInfo {
        guard CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw DecodeError.unreadable }
        let jfif = properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any]
        let progressive = (jfif?[kCGImagePropertyJFIFIsProgressive] as? Bool) ?? false
        // Creating a CGImage is lazy: it parses the header but decodes nothing.
        // What the decode will produce, not the file's own space: a gray or CMYK image is drawn into Display P3, and
        // the viewer pretags its layer from this (M3b spec §5).
        let profileName = properties[kCGImagePropertyProfileName] as? String
        let pixels = CGImageSourceCreateImageAtIndex(source, 0, noCache).map {
            EmbeddedColorSpace.imageIOPixels(source: $0.colorSpace, profileName: profileName)
        }
        return ImageInfo(pixelSize: PixelSize(width: width, height: height), typeIdentifier: type as String,
                         isProgressive: progressive, fileSize: fileSize, colorSpaceName: pixels?.name ?? profileName,
                         orientation: orientation(of: properties), colorSpace: pixels?.space)
    }

    /// The orientation among `properties` (`kCGImagePropertyOrientation`), `.up` when absent or not 1...8.
    static func orientation(of properties: [CFString: Any]) -> ImageOrientation {
        (properties[kCGImagePropertyOrientation] as? Int).flatMap(ImageOrientation.init(rawValue:)) ?? .up
    }

    /// No decoded copy kept with the image or source (spec M2 §11.3): every image and thumbnail here is drawn once
    /// into our own buffer. (The ~548 MB per 147 MP HEIC the replay saw retained was our freed malloc'd frame, fixed
    /// by mapping `PageAlignedBuffer`; this flag alone did not change it, it only rules out a cached second copy.)
    private static let noCache = [kCGImageSourceShouldCache: false] as CFDictionary

    /// Decodes the first image at full size straight into a page-aligned BGRA buffer. The draw is
    /// what decodes, and ImageIO is told not to cache a second copy of the pixels.
    /// Throws `.unreadable` for garbage, zero-size images and truncated files, `.outOfMemory`
    /// when the buffer cannot be allocated. ImageIO happily reports a cut-off JPEG or PNG as
    /// complete (it decodes the missing part as gray), so those two get a structural end-marker
    /// check; other formats rely on ImageIO's own status only.
    public static func decodeFull(_ data: Data) throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, noCache),
              image.width > 0, image.height > 0
        else { throw DecodeError.unreadable }
        guard hasCompleteEnding(data, type: CGImageSourceGetType(source) as String?) else { throw DecodeError.unreadable }

        return try draw(image, width: image.width, height: image.height, interpolation: .none)
    }

    /// A downscaled picture of exactly `size`, for the pyramid level that size belongs to. Uses
    /// ImageIO's thumbnailer (which can decode JPEG at a reduced scale), asked explicitly for no
    /// `CreateThumbnailWithTransform`: previews are stored as in the file, like the grid they are a level
    /// of, and the renderer turns them with the rest of the pyramid (M3b spec §2.2). `oriented` asks for the
    /// picture as shown instead, `size` then being the oriented size: the strip's thumbnails (`ThumbnailMaker`).
    /// Same truncation checks as `decodeFull`.
    static func preview(_ data: Data, size: PixelSize, oriented: Bool = false) throws -> DecodedImage {
        guard size.width > 0, size.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              hasCompleteEnding(data, type: CGImageSourceGetType(source) as String?)
        else { throw DecodeError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: oriented,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
            kCGImageSourceShouldCache: false,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              thumbnail.width > 0, thumbnail.height > 0
        else { throw DecodeError.unreadable }
        // The thumbnail may be a pixel off the grid's rounding (the draw fixes that), but a different
        // aspect means it came from another image (both sides are in the same layout: stored, or
        // oriented when asked); stretching it would lie.
        let skew = abs(thumbnail.width * size.height - size.width * thumbnail.height)
        guard skew <= size.width + size.height else { throw DecodeError.unreadable }
        return try draw(thumbnail, width: size.width, height: size.height, interpolation: .high)
    }

    /// A page-aligned buffer for a `width` x `height` BGRA image, rows padded to 64 bytes. It reads
    /// as zero (fresh pages from `PageAlignedBuffer`), so the padding and the page-rounding tail need no
    /// clearing; the pixels are left for the caller. Throws `.outOfMemory` on overflow or allocation failure.
    static func allocateBGRA(width: Int, height: Int) throws -> (buffer: PageAlignedBuffer, bytesPerRow: Int) {
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow, rowBytes <= Int.max - 63 else { throw DecodeError.outOfMemory }
        let bytesPerRow = DecodedImage.bytesPerRow(width: width)
        let (total, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow else { throw DecodeError.outOfMemory }
        return (try PageAlignedBuffer(minimumLength: total), bytesPerRow)
    }

    /// Draws `image` stretched over a fresh `width` x `height` page-aligned BGRA buffer.
    private static func draw(_ image: CGImage, width: Int, height: Int,
                             interpolation: CGInterpolationQuality) throws -> DecodedImage {
        let (buffer, bytesPerRow) = try allocateBGRA(width: width, height: height)
        let (context, space) = try makeContext(for: image, buffer: buffer, width: width, height: height, bytesPerRow: bytesPerRow)
        // Copy, not source-over, so the alpha is stored rather than composited.
        context.interpolationQuality = interpolation
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return DecodedImage(pixelSize: PixelSize(width: width, height: height), bytesPerRow: bytesPerRow,
                            buffer: buffer, colorSpace: space, hasAlphaChannel: hasAlpha(image))
    }

    /// Whether `image` carries alpha: anything but `none` and the `noneSkip` layouts (an image mask has none to keep).
    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// How far from the end of the file the PNG end marker may sit (trailing bytes after it are legal).
    private static let endMarkerWindow = 64 * 1024

    /// JPEG must reach the main image's EOI (anything after it, like a motion photo's video, is
    /// fine, so no tail window; embedded thumbnails' EOIs do not count) and PNG an IEND chunk near the end; a file copied only partway lacks both.
    private static func hasCompleteEnding(_ data: Data, type: String?) -> Bool {
        switch type {
        case "public.jpeg": return JPEGScans.mainImageEnd(data) != nil
        case "public.png": return data.suffix(endMarkerWindow).range(of: Data("IEND".utf8), options: .backwards) != nil
        default: return true
        }
    }

    /// A context over `buffer` in the image's own space if it is RGB and accepted, else Display P3.
    private static func makeContext(for image: CGImage, buffer: PageAlignedBuffer, width: Int, height: Int,
                                    bytesPerRow: Int) throws -> (CGContext, CGColorSpace) {
        func context(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: buffer.bytes, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo)
        }
        if let own = image.colorSpace, own.model == .rgb, let c = context(own) { return (c, own) }
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3), let c = context(p3) else { throw DecodeError.unreadable }
        return (c, p3)
    }
}

/// `ImageIODecoder` behind the `ImageDecoder` protocol: the decoder for every format without a
/// faster specialist, and the one that handles colour spaces and HEIC/AVIF.
public struct ImageIOImageDecoder: ImageDecoder {
    public var name: String { "ImageIO" }

    public init() {}

    public func probe(_ data: Data) throws -> ImageInfo { try ImageIODecoder.probe(data) }

    /// PNG and WebP return the full decode at level 0: their thumbnails measured slower than a
    /// full decode (M0). Other formats return the thumbnail at exactly `level`, which is clamped to
    /// the deepest level the grid has.
    public func preview(_ data: Data, info: ImageInfo, level: Int) throws -> LevelImage {
        let format = ImageFormat.detect(data)
        let grid = TileGrid(imageSize: info.pixelSize)
        let level = min(level, grid.levelCount - 1)
        if level <= 0 || format == .png || format == .webp {
            return LevelImage(image: try ImageIODecoder.decodeFull(data), level: 0)
        }
        return LevelImage(image: try ImageIODecoder.preview(data, size: grid.levelSize(level)), level: level)
    }

    public func decodeFull(_ data: Data, info: ImageInfo) throws -> DecodedImage {
        try ImageIODecoder.decodeFull(data)
    }
}
