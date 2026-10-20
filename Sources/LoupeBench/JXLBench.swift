import CJXL
import Darwin
import Foundation
import LoupeCore

/// The libjxl decode path under test: whole image to RGBA8 with the library's own thread pool.
/// The output buffer is allocated inside the timed call and freed after, and never read.
enum JXLBench {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Worker threads for the parallel runner.
    static let threads = 10

    static let methods: [String: BenchMethod] = [
        "jxl-full": BenchMethod(formats: [.jxl], decode: full, label: ImageFormat.rowLabel),
        "jxl-dc": BenchMethod(formats: [.jxl], decode: dc, label: ImageFormat.rowLabel),
    ]

    /// Loupe's first look: header plus the 1:8 DC image (`JXLDecoder.firstLook`, Loupe's libjxl) as level 3 in BGRA.
    static func dc(_ data: Data) throws -> PixelSize {
        let decoder = JXLDecoder(options: JXLOptions(threadsCurrent: threads))
        let info = try decoder.probe(data)
        guard let look = try decoder.firstLook(data, info: info) else {
            throw Failure(description: "no DC image (modular, animation, alpha, or under 2049 px)")
        }
        return look.image.pixelSize
    }

    /// Decodes the whole image to interleaved RGBA8 (libjxl has no BGRA output).
    static func full(_ data: Data) throws -> PixelSize {
        guard let decoder = JxlDecoderCreate(nil) else { throw Failure(description: "JxlDecoderCreate failed") }
        defer { JxlDecoderDestroy(decoder) }
        guard let runner = JxlThreadParallelRunnerCreate(nil, threads) else {
            throw Failure(description: "JxlThreadParallelRunnerCreate failed")
        }
        defer { JxlThreadParallelRunnerDestroy(runner) }
        try check(JxlDecoderSetParallelRunner(decoder, JxlThreadParallelRunner, runner), "JxlDecoderSetParallelRunner")
        try check(JxlDecoderSubscribeEvents(decoder, Int32(JXL_DEC_BASIC_INFO.rawValue | JXL_DEC_FULL_IMAGE.rawValue)), "JxlDecoderSubscribeEvents")

        return try data.withUnsafeBytes { bytes in
            let input = bytes.bindMemory(to: UInt8.self)
            try check(JxlDecoderSetInput(decoder, input.baseAddress, input.count), "JxlDecoderSetInput")
            JxlDecoderCloseInput(decoder)

            var format = JxlPixelFormat(num_channels: 4, data_type: JXL_TYPE_UINT8, endianness: JXL_NATIVE_ENDIAN, align: 0)
            var size: PixelSize?
            var buffer: UnsafeMutableRawPointer?
            defer { free(buffer) }

            while true {
                switch JxlDecoderProcessInput(decoder) {
                case JXL_DEC_BASIC_INFO:
                    var info = JxlBasicInfo()
                    try check(JxlDecoderGetBasicInfo(decoder, &info), "JxlDecoderGetBasicInfo")
                    size = PixelSize(width: Int(info.xsize), height: Int(info.ysize))
                case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                    var length = 0
                    try check(JxlDecoderImageOutBufferSize(decoder, &format, &length), "JxlDecoderImageOutBufferSize")
                    let pageSize = Int(getpagesize())
                    let aligned = (length + pageSize - 1) / pageSize * pageSize
                    guard posix_memalign(&buffer, pageSize, aligned) == 0 else {
                        throw Failure(description: "posix_memalign(\(aligned)) failed")
                    }
                    try check(JxlDecoderSetImageOutBuffer(decoder, &format, buffer, length), "JxlDecoderSetImageOutBuffer")
                case JXL_DEC_FULL_IMAGE:
                    guard let size else { throw Failure(description: "image decoded before basic info") }
                    return size
                case JXL_DEC_SUCCESS:
                    throw Failure(description: "decoder finished without a full image")
                case JXL_DEC_NEED_MORE_INPUT:
                    throw Failure(description: "truncated input")
                default:
                    throw Failure(description: "JxlDecoderProcessInput: unexpected status or error")
                }
            }
        }
    }

    private static func check(_ status: JxlDecoderStatus, _ what: String) throws {
        if status != JXL_DEC_SUCCESS { throw Failure(description: "\(what) failed (status \(status.rawValue))") }
    }
}
