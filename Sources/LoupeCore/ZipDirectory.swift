import Foundation

/// Why an archive or one of its entries cannot be read (Stash spec §2.4).
public enum ArchiveError: Error, Equatable, Sendable {
    case damaged, encrypted, unsupportedMethod(UInt16), entryNotFound

    public var text: String {
        switch self {
        case .damaged: "Damaged archive"
        case .encrypted: "Encrypted entry"
        case .unsupportedMethod(let m): "Unsupported compression (\(m))"
        case .entryNotFound: "Not in the archive"
        }
    }
}

extension ArchiveError: LocalizedError {
    public var errorDescription: String? { text }
}

/// One file of a zip's central directory.
public struct ZipEntry: Equatable, Sendable {
    public let name: String
    public let method: UInt16
    public let isEncrypted: Bool
    public let crc32: UInt32
    public let compressedSize: Int
    public let size: Int
    public let localHeaderOffset: Int

    public var isDirectory: Bool { name.hasSuffix("/") }
}

/// A zip's central directory, parsed without I/O: `locate` finds it from the file's tail (the end record, or the
/// ZIP64 one), `parse` reads its entries. Names are UTF-8 with flag bit 11, CP437 otherwise; sizes and offsets come
/// from the ZIP64 extra field (0x0001) where the 32-bit fields say 0xFFFFFFFF.
public struct ZipDirectory: Equatable, Sendable {
    public let entries: [ZipEntry]

    /// The most of a file's end that can hold the end record: the record, its longest comment, the ZIP64 locator and
    /// the ZIP64 end record.
    public static let tailLength = 65_557 + 20 + 56
    public static let localHeaderLength = 30

    /// The central directory's absolute offset and size. `tail` is the file's last bytes (at most `tailLength`).
    public static func locate(tail: Data, fileSize: Int) throws -> (offset: Int, size: Int) {
        let t = [UInt8](tail), base = fileSize - t.count
        guard t.count >= 22 else { throw ArchiveError.damaged }
        // The record whose comment ends the file; failing that, the last one with bytes after it (seen: six zero
        // bytes after the record, which unzip reads) whose directory ends right where it starts, or that has a ZIP64
        // locator in front.
        var eocd: Int?, loose: Int?
        var i = t.count - 22
        while i >= 0 {
            if t.u32(i) == 0x0605_4b50 {
                let end = i + 22 + Int(t.u16(i + 20))
                if end == t.count { eocd = i; break }
                if loose == nil, end < t.count,
                   Int(t.u32(i + 16)) + Int(t.u32(i + 12)) == base + i || (i >= 20 && t.u32(i - 20) == 0x0706_4b50) {
                    loose = i
                }
            }
            i -= 1
        }
        guard let e = eocd ?? loose else { throw ArchiveError.damaged }
        var size = Int(t.u32(e + 12)), offset = Int(t.u32(e + 16))
        if size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF || t.u16(e + 10) == 0xFFFF {
            // The ZIP64 locator sits just before the end record and points at the ZIP64 end record.
            let l = e - 20
            guard l >= 0, t.u32(l) == 0x0706_4b50 else { throw ArchiveError.damaged }
            guard let at = Int(exactly: t.u64(l + 8)), at >= base, at - base + 56 <= t.count,
                  t.u32(at - base) == 0x0606_4b50 else { throw ArchiveError.damaged }
            let record = at - base
            guard let s = Int(exactly: t.u64(record + 40)), let o = Int(exactly: t.u64(record + 48)) else {
                throw ArchiveError.damaged
            }
            size = s
            offset = o
        }
        let (end, overflow) = offset.addingReportingOverflow(size)
        guard offset >= 0, size >= 0, !overflow, end <= fileSize else { throw ArchiveError.damaged }
        return (offset, size)
    }

    public static func parse(_ centralDirectory: Data) throws -> ZipDirectory {
        let d = [UInt8](centralDirectory)
        var entries: [ZipEntry] = []
        var p = 0
        while p < d.count {
            guard p + 46 <= d.count, d.u32(p) == 0x0201_4b50 else { throw ArchiveError.damaged }
            let flags = d.u16(p + 8), method = d.u16(p + 10), crc = d.u32(p + 16)
            var compressed = UInt64(d.u32(p + 20)), size = UInt64(d.u32(p + 24))
            let nameLength = Int(d.u16(p + 28)), extraLength = Int(d.u16(p + 30)), commentLength = Int(d.u16(p + 32))
            var offset = UInt64(d.u32(p + 42))
            let nameStart = p + 46, extraStart = nameStart + nameLength, next = extraStart + extraLength + commentLength
            guard next <= d.count else { throw ArchiveError.damaged }
            let nameBytes = Array(d[nameStart..<extraStart])
            let name = flags & 0x0800 != 0 ? String(decoding: nameBytes, as: UTF8.self) : CP437.decode(nameBytes)
            // ZIP64 extra field: only the fields whose 32-bit value is 0xFFFFFFFF, in this order.
            var x = extraStart
            while x + 4 <= extraStart + extraLength {
                let id = d.u16(x), length = Int(d.u16(x + 2))
                var f = x + 4
                if id == 0x0001 {
                    func take() throws -> UInt64 {
                        guard f + 8 <= x + 4 + length else { throw ArchiveError.damaged }
                        defer { f += 8 }
                        return d.u64(f)
                    }
                    if size == 0xFFFF_FFFF { size = try take() }
                    if compressed == 0xFFFF_FFFF { compressed = try take() }
                    if offset == 0xFFFF_FFFF { offset = try take() }
                }
                x += 4 + length
            }
            guard size < UInt64(Int.max), compressed < UInt64(Int.max), offset < UInt64(Int.max) else {
                throw ArchiveError.damaged
            }
            entries.append(ZipEntry(name: name, method: method, isEncrypted: flags & 1 != 0, crc32: crc,
                                    compressedSize: Int(compressed), size: Int(size), localHeaderOffset: Int(offset)))
            p = next
        }
        return ZipDirectory(entries: entries)
    }

    /// The most an entry may inflate to: deflate's best ratio is about 1032:1, and no photo is bigger than this.
    static let sizeLimit = 2 << 30

    /// Refuses sizes a sound entry cannot have, before anything is allocated for it: stored data the size of the
    /// file, deflate within its ratio, everything within `sizeLimit`.
    static func checkSizes(_ entry: ZipEntry) throws {
        let fits = entry.method == 0 ? entry.size == entry.compressedSize
                                     : entry.size <= entry.compressedSize * 1032 + 64
        guard fits, entry.size <= sizeLimit else { throw ArchiveError.damaged }
    }

    /// Where `entry`'s data starts, from its 30-byte local header (whose name and extra lengths may differ from the
    /// central directory's).
    public static func dataOffset(localHeader: Data, entry: ZipEntry) throws -> Int {
        let h = [UInt8](localHeader)
        guard h.count >= localHeaderLength, h.u32(0) == 0x0403_4b50 else { throw ArchiveError.damaged }
        return entry.localHeaderOffset + localHeaderLength + Int(h.u16(26)) + Int(h.u16(28))
    }
}

/// IBM code page 437, the zip default for names without the UTF-8 flag.
enum CP437 {
    private static let high: [Character] = Array(
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀"
        + "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}")

    static func decode(_ bytes: [UInt8]) -> String {
        String(bytes.map { $0 < 0x80 ? Character(Unicode.Scalar($0)) : high[Int($0) - 0x80] })
    }
}

private extension Array where Element == UInt8 {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
}
