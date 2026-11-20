import Foundation
import ImageIO

/// Finds a complete first GIF picture and the start of a second without decoding LZW or reading the full file.
enum GIFPoster {
    // A 4K, 8-bit canvas has at most ~12 MiB of GIF LZW codes. Leave room for palettes and metadata.
    static let scanLimit = 16 << 20

    struct Scan {
        var firstImageEnd: Int?
        var animated = false
        var ended = false
    }

    static func hasSignature(_ bytes: Data) -> Bool {
        let signature = bytes.prefix(6)
        return signature.elementsEqual("GIF87a".utf8) || signature.elementsEqual("GIF89a".utf8)
    }

    static func scan(_ data: Data) -> Scan {
        guard hasSignature(data) else { return Scan() }
        return data.prefix(scanLimit).withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Scan in
            guard bytes.count >= 13 else { return Scan() }
            var cursor = 13 + paletteLength(bytes[10])
            var result = Scan()
            while cursor < bytes.count {
                switch bytes[cursor] {
                case 0x3b:
                    result.ended = true
                    return result
                case 0x21:
                    cursor += 2   // extension label, followed by data sub-blocks
                case 0x2c:
                    if result.firstImageEnd != nil {
                        result.animated = true
                        return result
                    }
                    guard cursor + 10 < bytes.count else { return result }
                    cursor += 11 + paletteLength(bytes[cursor + 9]) // descriptor, palette and LZW code size
                    guard skipBlocks(bytes, cursor: &cursor) else { return result }
                    result.firstImageEnd = cursor
                    continue
                default:
                    return result
                }
                guard skipBlocks(bytes, cursor: &cursor) else { return result }
            }
            return result
        }
    }

    private static func paletteLength(_ flags: UInt8) -> Int {
        flags & 0x80 == 0 ? 0 : 3 * (2 << Int(flags & 7))
    }

    private static func skipBlocks(_ bytes: UnsafeRawBufferPointer, cursor: inout Int) -> Bool {
        while cursor < bytes.count {
            let length = Int(bytes[cursor])
            cursor += 1 + length
            if length == 0 { return true }
        }
        return false
    }

    /// Used by callers that already have an off-main I/O slot.
    static func read(_ url: URL, detectAnimation: Bool = false) -> (source: CGImageSource, animated: Bool)? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        var prefix = Data()
        var result = Scan()
        while prefix.count < scanLimit,
              let chunk = try? file.read(upToCount: min(1 << 20, scanLimit - prefix.count)),
              !chunk.isEmpty {
            prefix.append(chunk)
            guard hasSignature(prefix) else { return nil }
            result = scan(prefix)
            if result.animated || result.ended || (!detectAnimation && result.firstImageEnd != nil) { break }
        }
        guard let end = result.firstImageEnd,
              let source = CGImageSourceCreateWithData(still(prefix, through: end) as CFData, nil) else { return nil }
        return (source, result.animated)
    }

    static func still(_ bytes: Data, through end: Int) -> Data {
        var data = Data(bytes.prefix(end))
        data.append(0x3b)
        return data
    }
}
