import CJXL
import Foundation

/// The 1:8 DC image of Loupe's libjxl (`JxlDecoderGetDCImage`, ~15 ms and ~0.12 s of CPU for a 147 MP transcoded
/// JPEG against 126 ms and 1.2 s for the full image): pyramid level 3 exactly, `ceil(w/8) x ceil(h/8)`.
extension JXLDecoder {
    /// The pyramid level the DC image is.
    static let dcLevel = 3

    /// How many leading bytes of the file hold its DC image (`JxlDecoderGetDCByteCount`, headers and TOC only);
    /// nil when the file has none (modular lossless, animation, alpha, upsampling) or `data` stops before the TOC.
    static func dcByteCount(_ data: Data) -> Int? {
        var count: UInt64 = 0
        let status = data.withUnsafeBytes { bytes in
            JxlDecoderGetDCByteCount(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &count)
        }
        return status == JXL_DEC_SUCCESS ? Int(count) : nil
    }

    /// Whether `dcImage` can answer for this file: `jxl-dc-preview` on, a pyramid with a level 3, and the DC
    /// image within `data`.
    func hasDCImage(_ data: Data, info: ImageInfo) -> Bool {
        guard options.dcPreview, TileGrid(imageSize: info.pixelSize).levelCount > Self.dcLevel,
              let count = Self.dcByteCount(data) else { return false }
        return count <= data.count
    }

    /// The DC image as level 3; nil when this file or setting has none.
    func dcImage(_ data: Data, info: ImageInfo) throws -> LevelImage? {
        guard hasDCImage(data, info: info) else { return nil }
        return try Session.run(data, forPixels: false, threads: threads, dcImage: true) { session in
            let header = try session.readHeader()
            guard header.size == info.pixelSize else { throw DecodeError.unreadable }
            let size = TileGrid(imageSize: header.size).levelSize(Self.dcLevel)
            let (buffer, bytesPerRow) = try ImageIODecoder.allocateBGRA(width: size.width, height: size.height)
            guard try session.decodeDC(into: buffer, bytesPerRow: bytesPerRow, size: size) else { return nil }
            return LevelImage(image: Self.finish(buffer, bytesPerRow: bytesPerRow, size: size, header: header, info: info,
                                                 workers: threads),
                              level: Self.dcLevel)
        }
    }
}
