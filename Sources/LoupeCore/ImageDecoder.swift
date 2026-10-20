import Foundation

/// Pixels of exactly one pyramid level: image.pixelSize == grid.levelSize(level).
public struct LevelImage: Sendable {
    public let image: DecodedImage
    public let level: Int

    public init(image: DecodedImage, level: Int) {
        self.image = image
        self.level = level
    }
}

/// One way of turning encoded bytes into pixels. The viewer talks to this instead of to ImageIO
/// directly so JPEG, JXL and the rest can each use whatever decoder measured fastest for them.
public protocol ImageDecoder: Sendable {
    /// Shown in extended stats: "ImageIO", "libjpeg-turbo", "libjxl+dc", "libheif".
    var name: String { get }
    func probe(_ data: Data) throws -> ImageInfo
    /// A level no finer than needed: result.level <= level, and always a level the grid has
    /// (a decoder without a cheap preview returns level 0).
    func preview(_ data: Data, info: ImageInfo, level: Int) throws -> LevelImage
    func decodeFull(_ data: Data, info: ImageInfo) throws -> DecodedImage
    /// A coarse picture in tens of ms when the real preview is slow (progressive JPEG); nil if none.
    func firstLook(_ data: Data, info: ImageInfo) throws -> LevelImage?
    /// The decoder to use for a call on behalf of `role` (libjxl takes fewer threads for neighbours).
    func forRole(_ role: DecodeRole) -> any ImageDecoder
    /// Whether `preview(data, info:, level:)` decodes the whole image (and holds its full buffer) to answer:
    /// such previews share the cache's gate for big decodes.
    func previewNeedsFullDecode(_ data: Data, info: ImageInfo, level: Int) -> Bool
}

/// Whom a decode is for: the photo on screen, or a neighbour or thumbnail that must leave it room.
public enum DecodeRole: Sendable {
    case current, other
}

extension ImageDecoder {
    public func firstLook(_ data: Data, info: ImageInfo) throws -> LevelImage? { nil }
    public func forRole(_ role: DecodeRole) -> any ImageDecoder { self }
    public func previewNeedsFullDecode(_ data: Data, info: ImageInfo, level: Int) -> Bool { false }
}

/// Picks the decoder for a file from its bytes.
public enum DecoderRegistry {
    /// Decoder for the sniffed format (later tasks add theirs); ImageIO for everything else.
    /// JPEG goes to libjpeg-turbo, which refuses what it does not handle best (CMYK, gray,
    /// truncated files) so ImageIO takes those.
    @Sendable public static func decoder(for data: Data) -> any ImageDecoder {
        switch ImageFormat.detect(data) {
        case .jpeg: return FallbackDecoder(primary: TurboJPEGDecoder(), fallback: ImageIOImageDecoder())
        case .jxl: return FallbackDecoder(primary: JXLDecoder(), fallback: ImageIOImageDecoder())
        default: return ImageIOImageDecoder()
        }
    }
}
