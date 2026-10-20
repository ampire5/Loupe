import Foundation
import Compression

/// The text chunks of a PNG (`tEXt`, `iTXt`, `zTXt`): ImageIO does not hand them out, and AI generators keep their
/// parameters there (A1111 `parameters`, ComfyUI `prompt` / `workflow`). Read from the start of the file up to the first
/// `IDAT`, never further, and never more than `scanLimit` bytes; each text is cut at `textLimit` bytes.
public enum PNGText {
    static let textLimit = 65_536
    static let scanLimit = 8 * 1024 * 1024
    private static let block = 64 * 1024
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The texts and, for the ComfyUI chunks (`prompt`, `workflow`), their true length in bytes before the cut.
    public struct Result: Equatable, Sendable {
        public var text: [String: String] = [:]
        public var sizes: [String: Int] = [:]
        public init() {}
    }

    /// Keys whose true length is wanted, and the most that is counted for a compressed one.
    private static let sized: Set<String> = ["prompt", "workflow"]
    private static let sizeLimit = 64 * 1024 * 1024

    /// keyword → text; `[:]` for a file that is not a PNG or cannot be read.
    public static func read(_ url: URL) -> [String: String] { readAll(url).text }

    /// `readAll` of bytes already in memory (an archive entry).
    public static func readAll(data: Data) -> Result {
        guard data.starts(with: signature) else { return Result() }
        return scan(data.prefix(scanLimit))
    }

    public static func readAll(_ url: URL) -> Result {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Result() }
        defer { try? handle.close() }
        var data = Data()
        var next = signature.count      // where the first chunk not yet walked starts
        while data.count < scanLimit {
            guard let part = try? handle.read(upToCount: block), !part.isEmpty else { break }
            data.append(part)
            if data.count >= signature.count, !data.starts(with: signature) { return Result() }
            if !advance(data, &next) { break }
        }
        return scan(data)
    }

    /// Walks chunk headers from `next`; false when the text chunks are all behind us (`IDAT`, `IEND`, an absurd length).
    private static func advance(_ data: Data, _ next: inout Int) -> Bool {
        while next + 8 <= data.count {
            let length = Int(u32(data, next))
            let type = data.subdata(in: next + 4 ..< next + 8)
            if type == Data("IDAT".utf8) || type == Data("IEND".utf8) { return false }
            let end = next + 12 + length
            if end > scanLimit { return false }
            if end > data.count { return true }
            next = end
        }
        return true
    }

    static func parse(_ data: Data) -> [String: String] { scan(data).text }

    static func scan(_ data: Data) -> Result {
        var result = Result()
        guard data.count >= signature.count, data.starts(with: signature) else { return result }
        var at = data.startIndex + signature.count
        while at + 8 <= data.endIndex {
            let length = Int(u32(data, at))
            let type = String(decoding: data[at + 4 ..< at + 8], as: UTF8.self)
            if type == "IDAT" || type == "IEND" { break }
            let bodyStart = at + 8
            guard length <= data.endIndex - bodyStart else { break }
            let body = data[bodyStart ..< bodyStart + length]
            switch type {
            case "tEXt", "zTXt", "iTXt":
                if let (key, text, size) = entry(type, body), result.text[key] == nil {
                    result.text[key] = text
                    if sized.contains(key) { result.sizes[key] = size }
                }
            default: break
            }
            at = bodyStart + length + 4     // body, CRC (not checked: a damaged CRC still has readable text)
        }
        return result
    }

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        (UInt32(data[at]) << 24) | (UInt32(data[at + 1]) << 16) | (UInt32(data[at + 2]) << 8) | UInt32(data[at + 3])
    }

    /// keyword, text (cut), true length in bytes (counted only for the keys in `sized`).
    private static func entry(_ type: String, _ body: Data) -> (String, String, Int)? {
        guard let nul = body.firstIndex(of: 0), nul > body.startIndex else { return nil }
        let key = String(decoding: body[body.startIndex ..< nul], as: UTF8.self)   // Latin-1 keys are ASCII in practice
        // One byte past the cut, so `decode` sees that the text was cut and drops a split UTF-8 tail.
        let limit = sized.contains(key) ? sizeLimit : textLimit + 1
        var rest = body[(nul + 1)...]
        switch type {
        case "tEXt":
            return (key, decode(rest), rest.count)
        case "zTXt":
            guard rest.count >= 1 else { return nil }      // compression method byte, then the zlib stream
            guard let plain = inflate(rest.dropFirst(), limit: limit) else { return nil }
            return (key, decode(plain.head), plain.total)
        default:   // iTXt: flag, method, language NUL, translated keyword NUL, text
            guard rest.count >= 2 else { return nil }
            let compressed = rest[rest.startIndex] == 1
            rest = rest.dropFirst(2)
            guard let l = rest.firstIndex(of: 0), let t = rest[(l + 1)...].firstIndex(of: 0) else { return nil }
            let text = rest[(t + 1)...]
            if compressed {
                guard let plain = inflate(text, limit: limit) else { return nil }
                return (key, decode(plain.head), plain.total)
            }
            return (key, decode(text), text.count)
        }
    }

    /// UTF-8 when the bytes are (what most tools write even into `tEXt`), else Latin-1 as the format says.
    /// The cut at `textLimit` may split a character: up to three bytes are dropped to keep it whole.
    private static func decode(_ bytes: Data) -> String {
        let cut = bytes.count > textLimit
        let head = cut ? bytes.prefix(textLimit) : bytes
        for drop in 0...(cut ? 3 : 0) {
            if let s = String(data: head.dropLast(drop), encoding: .utf8) { return s }
        }
        return String(data: head, encoding: .isoLatin1) ?? ""
    }

    /// A zlib stream (2-byte header, deflate body, Adler-32 trailer) inflated: the first `textLimit + 1` bytes are kept (the
    /// extra one tells `decode` that the text goes on), the
    /// rest only counted, up to `limit` bytes in all (a bomb stops there). The trailer is left unchecked. nil for an
    /// empty or broken stream; a stream that breaks midway gives what came out before.
    private static func inflate(_ stream: Data, limit: Int) -> (head: Data, total: Int)? {
        guard stream.count > 2, stream[stream.startIndex] & 0x0F == 8 else { return nil }
        let body = Data(stream.dropFirst(2))
        let scratchSize = 64 * 1024
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchSize)
        let state = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { scratch.deallocate(); state.deallocate() }
        guard compression_stream_init(state, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(state) }
        var head = Data(), total = 0
        body.withUnsafeBytes { src in
            state.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            state.pointee.src_size = body.count
            while total < limit {
                state.pointee.dst_ptr = scratch
                state.pointee.dst_size = scratchSize
                let status = compression_stream_process(state, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let made = min(scratchSize - state.pointee.dst_size, limit - total)
                if head.count <= textLimit { head.append(scratch, count: min(made, textLimit + 1 - head.count)) }
                total += made
                if status != COMPRESSION_STATUS_OK || made == 0 { break }
            }
        }
        return total > 0 ? (head, total) : nil
    }
}
