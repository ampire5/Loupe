import Foundation

/// The EXIF orientation read straight from the JPEG bytes: a walk over the marker segments up to the APP1 "Exif"
/// one and a scan of its first IFD, a few microseconds where handing the file to ImageIO takes 2 to 12 ms (the
/// launch path probes every opened JPEG). Pure and bounds-checked on every read; damaged or hostile input gives
/// nil, never a trap.
enum JPEGExif {
    /// Segments walked before giving up. A real file has its Exif APP1 in the first few markers (SOI, APP0/APP1,
    /// maybe APP2 ICC); 256 is far more than any sane header and keeps a hostile run of empty segments from costing
    /// anything measurable. A walk that gives up is "unrecognised" and ImageIO decides.
    static let maxSegments = 256

    /// - Returns: the orientation among the Exif tags (values outside 1...8 count as `.up`, what
    ///   `ImageIODecoder.orientation(of:)` yields), `.up` when the file has no Exif segment or no orientation tag
    ///   (the scan ended at SOS/EOI, or IFD0 does not list the tag), nil when the bytes are not what this reader
    ///   understands: not a JPEG, truncated or inconsistent segments, a bad TIFF header, an orientation entry that
    ///   is not one SHORT. The caller then asks ImageIO.
    static func orientation(_ data: Data) -> ImageOrientation? {
        // Zero-based view, so a slice with a non-zero startIndex reads the same.
        data.withUnsafeBytes { orientation(in: $0) }
    }

    private static func orientation(in bytes: UnsafeRawBufferPointer) -> ImageOrientation? {
        let count = bytes.count
        guard count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var offset = 2
        for _ in 0..<maxSegments {
            // A marker is 0xFF (any number of 0xFF fill bytes) and a code.
            guard offset < count, bytes[offset] == 0xFF else { return nil }
            while offset < count, bytes[offset] == 0xFF { offset += 1 }
            guard offset < count else { return nil }
            let marker = bytes[offset]
            offset += 1
            switch marker {
            case 0xD9, 0xDA: return .up          // EOI, SOS: the headers are over and held no Exif orientation
            case 0x00: return nil                // 0xFF00 is not a marker
            case 0x01, 0xD0...0xD8: continue     // TEM, RSTn, SOI: no length
            default: break
            }
            guard offset + 2 <= count else { return nil }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard length >= 2, offset + length <= count else { return nil }
            if marker == 0xE1, length >= 2 + 6, isExifHeader(bytes, at: offset + 2) {
                return tiffOrientation(bytes, start: offset + 8, end: offset + length)
            }
            offset += length
        }
        return nil
    }

    private static func isExifHeader(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Bool {
        let magic: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0, 0]   // "Exif\0\0"
        return (0..<6).allSatisfy { bytes[offset + $0] == magic[$0] }
    }

    /// The orientation in the TIFF block `bytes[start..<end]` (offsets inside it are relative to `start`).
    private static func tiffOrientation(_ bytes: UnsafeRawBufferPointer, start: Int, end: Int) -> ImageOrientation? {
        guard end - start >= 8 else { return nil }
        let little: Bool
        switch (bytes[start], bytes[start + 1]) {
        case (0x49, 0x49): little = true     // "II"
        case (0x4D, 0x4D): little = false    // "MM"
        default: return nil
        }
        func u16(_ at: Int) -> Int {
            little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1])
        }
        func u32(_ at: Int) -> Int {
            little ? u16(at) | u16(at + 2) << 16 : u16(at) << 16 | u16(at + 2)
        }
        guard u16(start + 2) == 42 else { return nil }
        let ifd = u32(start + 4)
        guard ifd >= 8, ifd <= end - start - 2 else { return nil }
        let entries = u16(start + ifd)
        let first = start + ifd + 2
        guard first + entries * 12 <= end else { return nil }
        for index in 0..<entries {
            let entry = first + index * 12
            guard u16(entry) == 0x0112 else { continue }
            // SHORT (3), count 1, the value in the first two bytes of the value field.
            guard u16(entry + 2) == 3, u32(entry + 4) == 1 else { return nil }
            return ImageOrientation(rawValue: u16(entry + 8)) ?? .up
        }
        return .up
    }
}
