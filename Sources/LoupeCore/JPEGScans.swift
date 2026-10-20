import Foundation

/// Marker-level facts about a JPEG byte stream, read without decoding anything. The viewer uses
/// them to cut a progressive file after its DC scans (a cheap blurry first look) and to tell a
/// complete download from a truncated one.
public enum JPEGScans {
    /// Byte offset of the first SOS with Ss > 0 (first AC scan) in a progressive JPEG; nil for baseline or when absent.
    ///
    /// Everything before this offset is headers plus the DC scans, so `data[..<offset] + FF D9`
    /// is a valid, decodable (very coarse) JPEG. Walks the marker structure from SOI; inside
    /// entropy-coded data `FF 00` (stuffed byte) and `FF D0`-`FF D7` (restart markers) are not
    /// segment boundaries and are skipped. Also nil if the stream ends before such a scan.
    public static func endOfDCScans(_ data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            guard n >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
            var i = 2
            while i + 1 < n {
                // Next marker: an FF followed by a non-FF, non-zero byte (FF FF is fill).
                guard b[i] == 0xFF else { i += 1; continue }
                let marker = b[i + 1]
                if marker == 0xFF { i += 1; continue }
                if marker == 0x00 || marker == 0x01 || (0xD0...0xD8).contains(marker) { i += 2; continue }
                if marker == 0xD9 { return nil }
                guard i + 3 < n else { return nil }
                let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
                guard length >= 2 else { return nil }
                if marker == 0xDA {
                    // SOS header: Ls, Ns, Ns x (Cs, Td/Ta), Ss, Se, Ah/Al.
                    guard i + 4 < n else { return nil }
                    let ssIndex = i + 5 + 2 * Int(b[i + 4])
                    guard ssIndex < n else { return nil }
                    if b[ssIndex] > 0 { return i }
                    // DC scan: skip its entropy-coded data up to the next real marker.
                    i += 2 + length
                    while i + 1 < n {
                        if b[i] == 0xFF, b[i + 1] != 0x00, !(0xD0...0xD7).contains(b[i + 1]), b[i + 1] != 0xFF { break }
                        i += 1
                    }
                } else {
                    i += 2 + length
                }
            }
            return nil
        }
    }

    /// Offset just past the main image's EOI marker, found by walking the marker structure from SOI;
    /// nil if the stream ends first (a truncated file) or does not start with SOI.
    ///
    /// Length-prefixed segments are skipped whole, so an EOI inside an embedded EXIF/MPF thumbnail
    /// (APPn) is not mistaken for the end of the main image, and entropy-coded data is crossed the
    /// same way as in `endOfDCScans`. Bytes after the returned offset (a motion photo's video, an
    /// MPF second image) are not examined.
    public static func mainImageEnd(_ data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            guard n >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
            var i = 2
            while i + 1 < n {
                guard b[i] == 0xFF else { i += 1; continue }
                let marker = b[i + 1]
                if marker == 0xFF { i += 1; continue }
                if marker == 0xD9 { return i + 2 }
                if marker == 0x00 || marker == 0x01 || (0xD0...0xD8).contains(marker) { i += 2; continue }
                guard i + 3 < n else { return nil }
                let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
                guard length >= 2 else { return nil }
                i += 2 + length
                if marker == 0xDA {
                    // Entropy-coded data up to the next real marker.
                    while i + 1 < n {
                        if b[i] == 0xFF, b[i + 1] != 0x00, !(0xD0...0xD7).contains(b[i + 1]), b[i + 1] != 0xFF { break }
                        i += 1
                    }
                }
            }
            return nil
        }
    }
}
