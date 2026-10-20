import Foundation

/// Tries `primary`, and when it fails for any reason except `.tooLarge` tries `fallback`. A
/// specialist decoder can then be strict (throw on warnings, on colour models it does not
/// convert) without the viewer losing the file; `.tooLarge` is a property of the image, not of
/// the decoder, so a second try would only repeat the verdict.
///
/// `name` is the primary's: a call cannot report which decoder produced its pixels without shared
/// state, so extended stats may name the primary for a file the fallback decoded.
public struct FallbackDecoder: ImageDecoder {
    public let primary: any ImageDecoder
    public let fallback: any ImageDecoder

    public var name: String { primary.name }

    public init(primary: any ImageDecoder, fallback: any ImageDecoder) {
        self.primary = primary
        self.fallback = fallback
    }

    public func probe(_ data: Data) throws -> ImageInfo {
        try attempt({ try primary.probe(data) }, or: { try fallback.probe(data) })
    }

    public func preview(_ data: Data, info: ImageInfo, level: Int) throws -> LevelImage {
        try attempt({ try primary.preview(data, info: info, level: level) },
                    or: { try fallback.preview(data, info: info, level: level) })
    }

    public func decodeFull(_ data: Data, info: ImageInfo) throws -> DecodedImage {
        try attempt({ try primary.decodeFull(data, info: info) }, or: { try fallback.decodeFull(data, info: info) })
    }

    /// The primary's answer: it is the one that decodes unless it fails.
    public func previewNeedsFullDecode(_ data: Data, info: ImageInfo, level: Int) -> Bool {
        primary.previewNeedsFullDecode(data, info: info, level: level)
    }

    public func forRole(_ role: DecodeRole) -> any ImageDecoder {
        FallbackDecoder(primary: primary.forRole(role), fallback: fallback.forRole(role))
    }

    public func firstLook(_ data: Data, info: ImageInfo) throws -> LevelImage? {
        try attempt({ try primary.firstLook(data, info: info) }, or: { try fallback.firstLook(data, info: info) })
    }

    private func attempt<T>(_ first: () throws -> T, or second: () throws -> T) throws -> T {
        do {
            return try first()
        } catch DecodeError.tooLarge {
            throw DecodeError.tooLarge
        } catch {
            return try second()
        }
    }
}
