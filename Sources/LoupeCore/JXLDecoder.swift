import CoreGraphics
import CJXL
import Foundation

/// JPEG XL through libjxl: the whole image to 8-bit RGBA straight into the page-aligned buffer
/// (rows padded the way `ImageIODecoder.allocateBGRA` pads them, so libjxl's own row alignment
/// produces the final layout), then swizzled to premultiplied BGRA in place. A VarDCT file (a
/// transcoded JPEG above all) also gives its 1:8 DC image for a few ms through Loupe's libjxl
/// (`JxlDecoderGetDCImage`): that is pyramid level 3, the first look and every preview at level
/// 3 or coarser (`JXLDecoder+DC.swift`). Finer previews are the full decode made smaller. Anything
/// libjxl rejects throws and `FallbackDecoder` hands the file to ImageIO.
///
/// Every call creates its own `JxlDecoder` and thread pool, so calls from the decode pool never
/// share state.
public struct JXLDecoder: ImageDecoder {
    /// "libjxl+dc": Loupe's own libjxl (scripts/build-libjxl.sh) with the 1:8 DC image functions. Calling
    /// `JxlDecoderLoupeVersion` also keeps a build against Homebrew's libjxl from linking.
    public var name: String { JxlDecoderLoupeVersion() >= 1 ? "libjxl+dc" : "libjxl" }

    public let options: JXLOptions
    public let role: DecodeRole

    /// Worker threads for libjxl's parallel runner: `jxl-threads-current` or `jxl-threads-other` by role.
    public var threads: Int { role == .current ? options.threadsCurrent : options.threadsOther }

    public init(options: JXLOptions = JXLSetting.shared.options, role: DecodeRole = .current) {
        self.options = options
        self.role = role
    }

    public func forRole(_ role: DecodeRole) -> any ImageDecoder { JXLDecoder(options: options, role: role) }

    public func probe(_ data: Data) throws -> ImageInfo {
        try Session.run(data, forPixels: false, threads: threads) { session in
            let header = try session.readHeader()
            let pixels = EmbeddedColorSpace.resolve(iccData: header.iccProfile, convertsGray: true)
            return ImageInfo(pixelSize: header.size, typeIdentifier: "public.jpeg-xl", isProgressive: false,
                             fileSize: data.count, colorSpaceName: pixels.name, orientation: header.orientation,
                             colorSpace: pixels.space)
        }
    }

    /// Level 3 or coarser from the DC image when the file has one; otherwise the full decode. For a neighbour or a
    /// thumbnail (`.other`) that is made smaller to `level`, so the cache keeps a screen-size level, not ~590 MB of a
    /// 147 MP photo; the current photo keeps it whole, as the cache holds it at full resolution anyway (one decode
    /// for both, the GPU builds the coarser levels, and no ~270 ms vImage pass at 147 MP).
    public func preview(_ data: Data, info: ImageInfo, level: Int) throws -> LevelImage {
        if level >= Self.dcLevel, let dc = try? dcImage(data, info: info) { return dc }
        let full = try decodeFull(data, info: info)
        guard role == .other else { return LevelImage(image: full, level: 0) }
        let grid = TileGrid(imageSize: info.pixelSize)
        let target = min(level, grid.levelCount - 1)
        guard target > 0 else { return LevelImage(image: full, level: 0) }
        return LevelImage(image: try ThumbnailMaker.resample(full, to: grid.levelSize(target)), level: target)
    }

    /// The DC image, when the file and `jxl-dc-preview` allow one and the pyramid has a level 3.
    public func firstLook(_ data: Data, info: ImageInfo) throws -> LevelImage? {
        try? dcImage(data, info: info)
    }

    public func previewNeedsFullDecode(_ data: Data, info: ImageInfo, level: Int) -> Bool {
        !(level >= Self.dcLevel && hasDCImage(data, info: info))
    }

    public func decodeFull(_ data: Data, info: ImageInfo) throws -> DecodedImage {
        try Session.run(data, forPixels: true, threads: threads) { session in
            let header = try session.readHeader()
            guard header.size == info.pixelSize else { throw DecodeError.unreadable }
            let (buffer, bytesPerRow) = try ImageIODecoder.allocateBGRA(width: header.size.width, height: header.size.height)
            try session.decode(into: buffer, bytesPerRow: bytesPerRow, size: header.size)
            return Self.finish(buffer, bytesPerRow: bytesPerRow, size: header.size, header: header, info: info)
        }
    }

    /// RGBA8 from libjxl in `buffer` to the viewer's premultiplied BGRA, as a `DecodedImage` of `size`.
    static func finish(_ buffer: PageAlignedBuffer, bytesPerRow: Int, size: PixelSize, header: Header,
                       info: ImageInfo) -> DecodedImage {
        // A gray photo is tagged Display P3 (the probe says so too); a gray curve other than sRGB's needs its
        // codes mapped to P3's, as the ImageIO path's draw does (`GrayConversion`).
        if let iccProfile = header.iccProfile, let gray = GrayConversion.of(iccData: iccProfile) {
            gray.apply(to: buffer.bytes, width: size.width, height: size.height, bytesPerRow: bytesPerRow,
                       premultiplied: header.hasAlpha && !header.hasStraightAlpha)
        }
        // libjxl hands back premultiplied pixels itself when the file stores them that way.
        RGBAToBGRA.convert(buffer.bytes, width: size.width, height: size.height,
                           bytesPerRow: bytesPerRow, premultiply: header.hasStraightAlpha)
        return DecodedImage(pixelSize: size, bytesPerRow: bytesPerRow, buffer: buffer,
                            colorSpace: info.colorSpace ?? EmbeddedColorSpace.resolve(iccData: header.iccProfile, convertsGray: true).space,
                            hasAlphaChannel: header.hasAlpha)
    }

    struct Header {
        let size: PixelSize
        let hasStraightAlpha: Bool
        /// The image has an alpha channel (`alpha_bits > 0`), straight or premultiplied.
        let hasAlpha: Bool
        let iccProfile: Data?
        /// The basic info's orientation (kept, not applied: `JxlDecoderSetKeepOrientation(1)`); libjxl's 1...8 are EXIF's.
        let orientation: ImageOrientation
    }

    /// One libjxl decoder (and, for pixels, its thread pool) over borrowed input bytes.
    final class Session {
        private let decoder: OpaquePointer
        private var runner: UnsafeMutableRawPointer?

        /// `dcImage`: stops at the DC (`decodeDC`) instead of the full image.
        private init(forPixels: Bool, threads: Int, dcImage: Bool) throws {
            // Once `self.decoder` is set every later throw runs deinit, which is the only place that frees.
            guard let decoder = JxlDecoderCreate(nil) else { throw DecodeError.outOfMemory }
            self.decoder = decoder
            var events = JXL_DEC_BASIC_INFO.rawValue | JXL_DEC_COLOR_ENCODING.rawValue
            if forPixels { events |= JXL_DEC_FULL_IMAGE.rawValue }
            if dcImage { events |= JXL_DEC_FRAME_PROGRESSION.rawValue }
            guard JxlDecoderSubscribeEvents(decoder, Int32(events)) == JXL_DEC_SUCCESS,
                  // Stored orientation, like every other decoder here: the grid is built from stored dimensions.
                  JxlDecoderSetKeepOrientation(decoder, 1) == JXL_DEC_SUCCESS,
                  !dcImage || JxlDecoderSetProgressiveDetail(decoder, kDC) == JXL_DEC_SUCCESS
            else { throw DecodeError.unreadable }
            if forPixels {
                guard let runner = JxlThreadParallelRunnerCreate(nil, threads) else {
                    throw DecodeError.outOfMemory
                }
                self.runner = runner
                guard JxlDecoderSetParallelRunner(decoder, JxlThreadParallelRunner, runner) == JXL_DEC_SUCCESS else {
                    throw DecodeError.unreadable
                }
            }
        }

        deinit {
            JxlDecoderDestroy(decoder)
            if let runner { JxlThreadParallelRunnerDestroy(runner) }
        }

        /// The input must stay valid for the session's life, so the session only exists inside `body`.
        static func run<T>(_ data: Data, forPixels: Bool, threads: Int, dcImage: Bool = false,
                           _ body: (Session) throws -> T) throws -> T {
            try data.withUnsafeBytes { bytes in
                let input = bytes.bindMemory(to: UInt8.self)
                guard let base = input.baseAddress else { throw DecodeError.unreadable }
                let session = try Session(forPixels: forPixels || dcImage, threads: threads, dcImage: dcImage)
                guard JxlDecoderSetInput(session.decoder, base, input.count) == JXL_DEC_SUCCESS else {
                    throw DecodeError.unreadable
                }
                JxlDecoderCloseInput(session.decoder)
                return try body(session)
            }
        }

        /// Runs to the colour-encoding event, which libjxl always sends after the basic info.
        func readHeader() throws -> Header {
            var info: JxlBasicInfo?
            while true {
                switch JxlDecoderProcessInput(decoder) {
                case JXL_DEC_BASIC_INFO:
                    var basic = JxlBasicInfo()
                    guard JxlDecoderGetBasicInfo(decoder, &basic) == JXL_DEC_SUCCESS else { throw DecodeError.unreadable }
                    info = basic
                case JXL_DEC_COLOR_ENCODING:
                    guard let info, info.xsize > 0, info.ysize > 0 else { throw DecodeError.unreadable }
                    return Header(size: PixelSize(width: Int(info.xsize), height: Int(info.ysize)),
                                  hasStraightAlpha: info.alpha_bits > 0 && info.alpha_premultiplied == 0,
                                  hasAlpha: info.alpha_bits > 0,
                                  iccProfile: iccProfile(),
                                  orientation: ImageOrientation(rawValue: Int(info.orientation.rawValue)) ?? .up)
                default:
                    throw DecodeError.unreadable
                }
            }
        }

        /// The profile describing the pixels libjxl outputs; nil when the image has none to give.
        private func iccProfile() -> Data? {
            var length = 0
            guard JxlDecoderGetICCProfileSize(decoder, JXL_COLOR_PROFILE_TARGET_DATA, &length) == JXL_DEC_SUCCESS,
                  length > 0 else { return nil }
            var profile = Data(count: length)
            let status = profile.withUnsafeMutableBytes {
                JxlDecoderGetColorAsICCProfile(decoder, JXL_COLOR_PROFILE_TARGET_DATA,
                                               $0.bindMemory(to: UInt8.self).baseAddress, length)
            }
            return status == JXL_DEC_SUCCESS ? profile : nil
        }

        /// The first frame's DC image as RGBA8 into `buffer` (`size` = level 3, rows `bytesPerRow` apart). No full-size
        /// buffer is set: libjxl gets a callback it never calls, as the session ends at the DC. False when the file
        /// gives no DC image after all (no DC event, or `JxlDecoderGetDCImage` refuses).
        func decodeDC(into buffer: PageAlignedBuffer, bytesPerRow: Int, size: PixelSize) throws -> Bool {
            var format = JxlPixelFormat(num_channels: 4, data_type: JXL_TYPE_UINT8, endianness: JXL_NATIVE_ENDIAN, align: 64)
            while true {
                switch JxlDecoderProcessInput(decoder) {
                case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                    guard JxlDecoderSetImageOutCallback(decoder, &format, { _, _, _, _, _ in }, nil) == JXL_DEC_SUCCESS
                    else { throw DecodeError.unreadable }
                case JXL_DEC_FRAME_PROGRESSION:
                    guard bytesPerRow * size.height <= buffer.length else { throw DecodeError.unreadable }
                    return JxlDecoderGetDCImage(decoder, &format, buffer.bytes, bytesPerRow * size.height) == JXL_DEC_SUCCESS
                case JXL_DEC_FULL_IMAGE, JXL_DEC_SUCCESS:
                    return false
                default:
                    throw DecodeError.unreadable
                }
            }
        }

        /// Decodes the first frame as RGBA8 into `buffer`, rows `bytesPerRow` apart.
        func decode(into buffer: PageAlignedBuffer, bytesPerRow: Int, size: PixelSize) throws {
            // Aligning rows to 64 bytes makes libjxl's stride equal `bytesPerRow` (a multiple of 64).
            var format = JxlPixelFormat(num_channels: 4, data_type: JXL_TYPE_UINT8, endianness: JXL_NATIVE_ENDIAN, align: 64)
            while true {
                switch JxlDecoderProcessInput(decoder) {
                case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                    var length = 0
                    guard JxlDecoderImageOutBufferSize(decoder, &format, &length) == JXL_DEC_SUCCESS,
                          length <= bytesPerRow * size.height, length <= buffer.length,
                          JxlDecoderSetImageOutBuffer(decoder, &format, buffer.bytes, length) == JXL_DEC_SUCCESS
                    else { throw DecodeError.unreadable }
                case JXL_DEC_FULL_IMAGE:
                    return
                default:
                    // Includes NEED_MORE_INPUT (truncated: the input is closed) and SUCCESS without a frame.
                    throw DecodeError.unreadable
                }
            }
        }
    }
}
