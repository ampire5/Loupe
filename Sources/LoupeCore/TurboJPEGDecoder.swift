import CoreGraphics
import CTurboJPEG
import Foundation
import ImageIO

/// JPEG through libjpeg-turbo (TurboJPEG 3): the whole image straight into a BGRA page-aligned
/// buffer, and previews decoded with the IDCT itself scaled by 1/2, 1/4 or 1/8, which does
/// proportionally less work than decoding everything and shrinking. Everything it is not the best
/// tool for throws, and `FallbackDecoder` hands that file to ImageIO: CMYK/YCCK and grayscale
/// (ImageIO converts them per the colour rules), and any file libjpeg warns about (truncated or
/// corrupt data; `STOPONWARNING` turns a silent grey-filled picture into an error).
public struct TurboJPEGDecoder: ImageDecoder {
    public var name: String { "libjpeg-turbo" }

    /// The deepest DCT reduction libjpeg offers (1/8).
    static let maxScaledLevel = 3

    /// Sessions whose handle is still owned (taken in init, released in `deinit` or by the init's own failure path): a test hook
    /// for the handle being destroyed on every path out of a decode, refusals included. Per decoder value, so a test
    /// that owns its decoder is not disturbed by decodes running elsewhere.
    let liveSessions = LiveCount()

    final class LiveCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func add(_ delta: Int) { lock.lock(); count += delta; lock.unlock() }
    }

    public init() {}

    public func probe(_ data: Data) throws -> ImageInfo {
        let session = try Session(data, forPixels: false, live: liveSessions)
        return ImageInfo(pixelSize: session.size, typeIdentifier: "public.jpeg", isProgressive: session.isProgressive,
                         fileSize: data.count, colorSpaceName: session.pixels.name,
                         orientation: Self.orientation(data), colorSpace: session.pixels.space)
    }

    /// The EXIF orientation: read from the APP1 segment (`JPEGExif`, microseconds; TurboJPEG does not parse EXIF), and
    /// by ImageIO from the same bytes only when that reader does not recognise the file. `.up` when ImageIO cannot
    /// open them or the tag is absent.
    private static func orientation(_ data: Data) -> ImageOrientation {
        if let found = JPEGExif.orientation(data) { return found }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return .up }
        return ImageIODecoder.orientation(of: properties)
    }

    /// Exactly `levelSize(min(level, 3, levelCount - 1))`; that level is returned. Deeper levels
    /// than 1/8 would need a second pass, so the caller gets level 3 and scales from there.
    public func preview(_ data: Data, info: ImageInfo, level: Int) throws -> LevelImage {
        let grid = TileGrid(imageSize: info.pixelSize)
        let level = max(0, min(level, Self.maxScaledLevel, grid.levelCount - 1))
        let session = try Session(data, forPixels: true, live: liveSessions)
        guard session.size == info.pixelSize else { throw DecodeError.unreadable }
        return LevelImage(image: try session.decode(level: level, expected: grid.levelSize(level)), level: level)
    }

    public func decodeFull(_ data: Data, info: ImageInfo) throws -> DecodedImage {
        let session = try Session(data, forPixels: true, live: liveSessions)
        guard session.size == info.pixelSize else { throw DecodeError.unreadable }
        return try session.decode(level: 0, expected: info.pixelSize)
    }

    /// One TurboJPEG handle with the header already parsed; destroyed with it.
    private final class Session {
        private let handle: tjhandle
        private let data: Data
        private let live: LiveCount
        let size: PixelSize
        let isProgressive: Bool
        /// The space the pixels will be in and its name: what ImageIO produces for a gray or CMYK file (this decoder
        /// throws on them for the pixels, so the fallback decodes them), else the embedded profile's.
        let pixels: EmbeddedColorSpace.Resolved
        var colorSpace: CGColorSpace { pixels.space }

        /// Throws `.unreadable` for anything that is not a JPEG header libjpeg accepts. `forPixels`
        /// (a decode, not a probe) also turns warnings into errors and rejects the colour models
        /// this decoder leaves to ImageIO; a probe of a damaged or CMYK file still reports its size.
        init(_ data: Data, forPixels: Bool, live: LiveCount) throws {
            guard let handle = ltj_init_decompress() else { throw DecodeError.outOfMemory }
            self.handle = handle
            self.data = data
            self.live = live
            live.add(1)
            var ok = ltj_set_save_icc(handle) == 0 && ltj_set_stop_on_warning(handle, forPixels ? 1 : 0) == 0
            ok = ok && data.withUnsafeBytes { bytes in
                tj3DecompressHeader(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) == 0
            }
            let width = Int(ltj_get_width(handle)), height = Int(ltj_get_height(handle))
            guard ok, width > 0, height > 0 else {
                // `size` is not set yet, so this throw skips `deinit`: release here.
                tj3Destroy(handle)
                live.add(-1)
                throw DecodeError.unreadable
            }
            size = PixelSize(width: width, height: height)
            isProgressive = ltj_get_progressive(handle) != 0
            // CMYK/YCCK and gray are left to ImageIO for the pixels, but a probe still says what that decode will
            // produce. Every stored property is set before the refusal below: a class init that throws earlier
            // never runs `deinit`, which leaked the handle once per such decode.
            let leftToImageIO: Bool
            switch ltj_get_colorspace(handle) {
            case Int32(TJCS_CMYK.rawValue), Int32(TJCS_YCCK.rawValue):
                pixels = EmbeddedColorSpace.imageIOPixels(source: CGColorSpaceCreateDeviceCMYK(), profileName: nil)
                leftToImageIO = true
            case Int32(TJCS_GRAY.rawValue):
                pixels = EmbeddedColorSpace.imageIOPixels(source: CGColorSpaceCreateDeviceGray(), profileName: nil)
                leftToImageIO = true
            default:
                pixels = Self.embeddedColorSpace(handle)
                leftToImageIO = false
            }
            if forPixels && leftToImageIO { throw DecodeError.unreadable }
        }

        deinit {
            tj3Destroy(handle)
            live.add(-1)
        }

        /// The embedded profile's colour space and name (sRGB when absent or not usable).
        private static func embeddedColorSpace(_ handle: tjhandle) -> EmbeddedColorSpace.Resolved {
            var buffer: UnsafeMutablePointer<UInt8>?
            var length = 0
            guard tj3GetICCProfile(handle, &buffer, &length) == 0, let buffer else {
                return EmbeddedColorSpace.resolve(iccData: nil)
            }
            defer { tj3Free(buffer) }
            return EmbeddedColorSpace.resolve(iccData: Data(bytes: buffer, count: length))
        }

        /// Decodes at 1/2^level into a fresh buffer; `expected` is the size the grid says that
        /// level has, which the scaled output must match exactly (TJSCALED rounds up like the grid).
        func decode(level: Int, expected: PixelSize) throws -> DecodedImage {
            if level > 0 {
                guard ltj_set_scaling(handle, 1, Int32(1 << level)) == 0 else { throw DecodeError.unreadable }
            }
            // libjpeg writes its own idea of the scaled size into the buffer sized from `expected`;
            // if the two ever differ that is a heap overrun, so check before decompressing.
            let divisor = 1 << level
            guard (size.width + divisor - 1) / divisor == expected.width,
                  (size.height + divisor - 1) / divisor == expected.height else { throw DecodeError.unreadable }
            let (buffer, bytesPerRow) = try ImageIODecoder.allocateBGRA(width: expected.width, height: expected.height)
            let status = data.withUnsafeBytes { bytes in
                tj3Decompress8(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                               buffer.bytes.assumingMemoryBound(to: UInt8.self), Int32(bytesPerRow), ltj_pixel_format_bgra())
            }
            guard status == 0 else { throw DecodeError.unreadable }
            return DecodedImage(pixelSize: expected, bytesPerRow: bytesPerRow, buffer: buffer, colorSpace: colorSpace,
                                hasAlphaChannel: false)
        }
    }
}
