import Compression
import Foundation
import zlib

/// Writes zip archives for the archive tests: stored or deflated entries, UTF-8 or raw (CP437) names, the encrypted
/// flag, any method number, an archive comment and the ZIP64 layout (32-bit fields at 0xFFFFFFFF, the 0x0001 extra
/// field, a ZIP64 end record and locator).
enum ZipFixture {
    struct Entry {
        var name: String
        var data: Data
        var method: UInt16 = 8
        var utf8 = true
        var encrypted = false
        /// The name's bytes as stored, instead of `name` in UTF-8 (for CP437 names).
        var rawName: Data?
        /// Stored CRC instead of the real one (for a damaged entry).
        var crc: UInt32?
    }

    static func make(_ entries: [Entry], comment: Data = Data(), zip64: Bool = false) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = entry.rawName ?? Data(entry.name.utf8)
            let payload: Data
            switch entry.method {
            case 8: payload = deflate(entry.data)
            default: payload = entry.data
            }
            let crc = entry.crc ?? entry.data.withUnsafeBytes {
                UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)))
            }
            var flags: UInt16 = entry.utf8 && entry.rawName == nil ? 0x0800 : 0
            if entry.encrypted { flags |= 1 }
            let offset = out.count
            out.append(le32(0x0403_4b50)); out.append(le16(20)); out.append(le16(flags)); out.append(le16(entry.method))
            out.append(le16(0)); out.append(le16(0x21)); out.append(le32(crc))
            out.append(le32(UInt32(payload.count))); out.append(le32(UInt32(entry.data.count)))
            out.append(le16(UInt16(name.count))); out.append(le16(0)); out.append(name); out.append(payload)

            var extra = Data()
            if zip64 {
                extra.append(le16(0x0001)); extra.append(le16(24))
                extra.append(le64(UInt64(entry.data.count))); extra.append(le64(UInt64(payload.count)))
                extra.append(le64(UInt64(offset)))
            }
            let big: UInt32 = 0xFFFF_FFFF
            central.append(le32(0x0201_4b50)); central.append(le16(0x031E)); central.append(le16(zip64 ? 45 : 20))
            central.append(le16(flags)); central.append(le16(entry.method)); central.append(le16(0)); central.append(le16(0x21))
            central.append(le32(crc))
            central.append(le32(zip64 ? big : UInt32(payload.count))); central.append(le32(zip64 ? big : UInt32(entry.data.count)))
            central.append(le16(UInt16(name.count))); central.append(le16(UInt16(extra.count))); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0))
            central.append(le32(zip64 ? big : UInt32(offset)))
            central.append(name); central.append(extra)
        }
        let centralOffset = out.count
        out.append(central)
        if zip64 {
            let recordOffset = out.count
            out.append(le32(0x0606_4b50)); out.append(le64(44)); out.append(le16(45)); out.append(le16(45))
            out.append(le32(0)); out.append(le32(0))
            out.append(le64(UInt64(entries.count))); out.append(le64(UInt64(entries.count)))
            out.append(le64(UInt64(central.count))); out.append(le64(UInt64(centralOffset)))
            out.append(le32(0x0706_4b50)); out.append(le32(0)); out.append(le64(UInt64(recordOffset))); out.append(le32(1))
        }
        out.append(le32(0x0605_4b50)); out.append(le16(0)); out.append(le16(0))
        let count: UInt16 = zip64 ? 0xFFFF : UInt16(entries.count)
        out.append(le16(count)); out.append(le16(count))
        out.append(le32(zip64 ? 0xFFFF_FFFF : UInt32(central.count)))
        out.append(le32(zip64 ? 0xFFFF_FFFF : UInt32(centralOffset)))
        out.append(le16(UInt16(comment.count))); out.append(comment)
        return out
    }

    /// Raw deflate (no zlib header), as zip stores method 8.
    static func deflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(n)
    }

    /// `count` pseudo-random bytes that deflate a little (a JPEG's stand-in).
    static func bytes(_ count: Int, seed: UInt8 = 1) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 31 &+ Int(seed) * 7 + ($0 >> 5)) })
    }

    /// Writes `data` to a new file under a fresh temp folder and returns its URL.
    static func write(_ data: Data, name: String = "g.zip", in folder: URL? = nil) throws -> URL {
        let dir = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("zipfixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
