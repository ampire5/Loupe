import Foundation

/// Container formats the viewer routes to decoders, recognised by magic bytes (never by extension,
/// so a mis-named file is still routed to the right decoder).
public enum ImageFormat: Sendable, CaseIterable {
    case jpeg, png, webp, heic, avif, jxl

    /// Sniffs `data`; nil when the bytes are none of the known formats.
    public static func detect(_ data: Data) -> ImageFormat? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        // JXL: bare codestream, or the ISOBMFF-style container signature box.
        if data.starts(with: [0xFF, 0x0A]) { return .jxl }
        if data.starts(with: [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]) { return .jxl }
        let bytes = [UInt8](data.prefix(12))
        if bytes.count == 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WEBP".utf8) {
            return .webp
        }
        return heifFormat(data)
    }

    /// HEIC vs AVIF from the `ftyp` box: any AV1 brand means AVIF, any HEVC brand means HEIC.
    /// `mif1`/`msf1` alone are generic HEIF and are treated as HEIC.
    private static func heifFormat(_ data: Data) -> ImageFormat? {
        let head = [UInt8](data.prefix(64))
        guard head.count >= 16, head[4..<8].elementsEqual("ftyp".utf8) else { return nil }
        let boxSize = Int(head[0]) << 24 | Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
        let end = min(max(boxSize, 16), head.count)
        // Brands: the major brand at 8, then (after the 4-byte minor version) the compatible ones.
        var brands: [String] = [String(decoding: head[8..<12], as: UTF8.self)]
        var i = 16
        while i + 4 <= end {
            brands.append(String(decoding: head[i..<i + 4], as: UTF8.self))
            i += 4
        }
        if brands.contains(where: { $0 == "avif" || $0 == "avis" }) { return .avif }
        let heic: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]
        if brands.contains(where: heic.contains) { return .heic }
        return nil
    }
}
