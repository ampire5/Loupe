import CoreGraphics
import Foundation

/// The colour space the decoded pixels are tagged with, and the name stats show for it (M3b spec §5). Every decoder
/// answers through here, so a probe and the decode that follows it say the same thing: the viewer pretags its layer
/// from the probe's space, and a mismatch would cost a re-tag, and so a frame, at launch.
public enum EmbeddedColorSpace {
    /// The space the pixels are in and how stats name it.
    struct Resolved {
        let space: CGColorSpace
        let name: String
    }

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    private static func displayP3() -> CGColorSpace { CGColorSpace(name: CGColorSpace.displayP3)! }

    /// What a decoder that hands over RGB pixels itself (libjpeg-turbo, libjxl) tags them with, for the embedded
    /// profile: an RGB profile's own space when a BGRA bitmap context accepts it (so the pixels need no conversion);
    /// sRGB for everything else (no profile, an unreadable one, or CMYK), the safe reading of untagged RGB. A gray
    /// profile does the same, unless the decoder converts gray (`convertsGray`: libjxl, whose gray photos are replicated
    /// into RGB and then mapped by `GrayConversion`): Display P3, as the ImageIO path draws gray. A gray profile on
    /// the RGB pixels of a JPEG is malformed, and not converted.
    static func resolve(iccData: Data?, convertsGray: Bool = false) -> Resolved {
        let srgb = Resolved(space: CGColorSpace(name: CGColorSpace.sRGB)!, name: "sRGB")
        guard let iccData, !iccData.isEmpty, let space = CGColorSpace(iccData: iccData as CFData) else { return srgb }
        switch space.model {
        case .monochrome where convertsGray: return Resolved(space: displayP3(), name: convertedName(from: space))
        case .rgb where accepts(space): return Resolved(space: space, name: name(of: space, iccData: iccData, profileName: nil))
        default: return srgb
        }
    }

    /// What ImageIO's draw into our BGRA buffer gives an image whose own space is `source` (and its
    /// `kCGImagePropertyProfileName`): the image's own RGB space when a bitmap context accepts it, else Display P3
    /// (gray, CMYK, and whatever else is not RGB).
    static func imageIOPixels(source: CGColorSpace?, profileName: String?) -> Resolved {
        guard let source else { return Resolved(space: displayP3(), name: "Display P3") }
        if source.model == .rgb, accepts(source) {
            return Resolved(space: source, name: name(of: source, iccData: nil, profileName: profileName))
        }
        return Resolved(space: displayP3(), name: convertedName(from: source))
    }

    /// Whether a BGRA bitmap context takes `space`: not every RGB profile can be drawn into.
    private static func accepts(_ space: CGColorSpace) -> Bool {
        CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo) != nil
    }

    /// `Gray → Display P3`, `CMYK → Display P3`: a photo whose own space is not RGB is converted, and the stats say so.
    static func convertedName(from source: CGColorSpace) -> String {
        let from = switch source.model {
        case .monochrome: "Gray"
        case .cmyk: "CMYK"
        case .lab: "Lab"
        case .indexed: "Indexed"
        default: name(of: source, iccData: nil, profileName: nil)
        }
        return from + " → Display P3"
    }

    /// The name stats show for the space of a picture on screen (the fallback when the header's own name is not
    /// known): `sRGB`, `Display P3`, a profile's ICC description, else the CF name.
    public static func displayName(of space: CGColorSpace) -> String { name(of: space, iccData: nil, profileName: nil) }

    /// The readable name of an RGB space: the well-known ones by name (no profile to read), else the profile's ICC
    /// description (`profileName` is ImageIO's already-parsed one; `iccData` the raw profile when the decoder has
    /// it, else the space's own is copied), else the CF name, else `ICC (unnamed)`.
    private static func name(of space: CGColorSpace, iccData: Data?, profileName: String?) -> String {
        let cfName = space.name as String?
        if let cfName, let known = wellKnown[cfName] { return known }
        if let profileName, !profileName.isEmpty { return profileName }
        if let description = ICCDescription.read(iccData ?? space.copyICCData() as Data?) { return description }
        guard let cfName else { return "ICC (unnamed)" }
        return cfName.hasPrefix("kCGColorSpace") ? String(cfName.dropFirst("kCGColorSpace".count)) : cfName
    }

    /// Spaces by their CF name, which have no ICC profile to read a description from (the HDR ones) or whose profile's
    /// description is the less readable one.
    private static let wellKnown: [String: String] = [
        CGColorSpace.sRGB as String: "sRGB",
        CGColorSpace.displayP3 as String: "Display P3",
        CGColorSpace.adobeRGB1998 as String: "Adobe RGB (1998)",
        CGColorSpace.rommrgb as String: "ProPhoto RGB",
        CGColorSpace.linearSRGB as String: "Linear sRGB",
        CGColorSpace.extendedSRGB as String: "sRGB (extended)",
        CGColorSpace.extendedLinearSRGB as String: "Linear sRGB (extended)",
        CGColorSpace.linearDisplayP3 as String: "Linear Display P3",
        CGColorSpace.extendedDisplayP3 as String: "Display P3 (extended)",
        CGColorSpace.extendedLinearDisplayP3 as String: "Linear Display P3 (extended)",
        CGColorSpace.itur_2100_PQ as String: "Rec. 2100 PQ",
        CGColorSpace.itur_2100_HLG as String: "Rec. 2100 HLG",
        CGColorSpace.displayP3_PQ as String: "Display P3 PQ",
        CGColorSpace.displayP3_HLG as String: "Display P3 HLG",
        CGColorSpace.extendedITUR_2020 as String: "Rec. 2020 (extended)",
        CGColorSpace.extendedLinearITUR_2020 as String: "Linear Rec. 2020 (extended)",
        CGColorSpace.linearITUR_2020 as String: "Linear Rec. 2020",
    ]
}

/// The profile description of an ICC profile: its 'desc' tag, in the v2 (`desc`, ASCII) or v4 (`mluc`, UTF-16BE) form.
/// A parse of the header's tag table, microseconds, so it can run on the launch path; nil for anything malformed.
enum ICCDescription {
    static func read(_ data: Data?) -> String? {
        guard let data, data.count > 132 else { return nil }
        return data.withUnsafeBytes { raw -> String? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let count = u32(bytes, 128), count <= 1000 else { return nil }
            for index in 0..<count {
                let entry = 132 + 12 * index
                guard u32(bytes, entry) == tag("desc"), let start = u32(bytes, entry + 4), let length = u32(bytes, entry + 8),
                      length >= 12, start + length <= bytes.count, let kind = u32(bytes, start) else { continue }
                if kind == tag("desc") {
                    // ASCII text: a byte count (with the terminating NUL) at +8, the text at +12; a C string, so
                    // whatever follows an embedded NUL inside the count is not part of the name.
                    guard let size = u32(bytes, start + 8), size > 1, 12 + size <= length else { return nil }
                    let text = bytes[(start + 12)..<(start + 12 + size)]
                    return clean(String(decoding: text.prefix { $0 != 0 }, as: UTF8.self))
                }
                return kind == tag("mluc") ? multilocalized(bytes, start: start, length: length) : nil
            }
            return nil
        }
    }

    /// The English record of a `mluc` tag at `start`, else its first. Records are (language, country, byte length,
    /// offset from the tag's start), 12 bytes each, from +16; the strings are UTF-16BE.
    private static func multilocalized(_ bytes: UnsafeBufferPointer<UInt8>, start: Int, length: Int) -> String? {
        guard let count = u32(bytes, start + 8), count > 0, count <= 64 else { return nil }
        var chosen: Range<Int>?
        for index in 0..<count {
            let record = start + 16 + 12 * index
            guard 16 + 12 * (index + 1) <= length, let size = u32(bytes, record + 4), let offset = u32(bytes, record + 8),
                  size >= 2, offset + size <= length else { return nil }
            let text = (start + offset)..<(start + offset + size)
            if chosen == nil { chosen = text }
            if bytes[record] == UInt8(ascii: "e"), bytes[record + 1] == UInt8(ascii: "n") {
                chosen = text
                break
            }
        }
        guard let chosen else { return nil }
        let units = stride(from: chosen.lowerBound, to: chosen.upperBound - 1, by: 2).map {
            UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
        }
        return clean(String(decoding: units, as: UTF16.self))
    }

    private static func u32(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    private static func tag(_ text: String) -> Int {
        text.utf8.reduce(0) { $0 << 8 | Int($1) }
    }

    /// Without the terminating NULs and the padding spaces profiles carry; nil when nothing is left.
    private static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed
    }
}
