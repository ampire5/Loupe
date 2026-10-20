import CTurboJPEG
import Darwin
import Foundation
import LoupeCore

/// The libjpeg-turbo (TurboJPEG 3) decode paths under test: whole image, DCT-scaled, and a
/// centre crop. All decode into a page-aligned BGRA buffer allocated inside the timed call, the
/// same way `imageio-full-bgra` does, so the two are comparable.
enum TurboBench {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Long side the scaled decode must still reach (a retina-sized fit preview).
    static let previewMinLongSide = 3456
    /// Centre crop for the region decode: roughly what a 100 % view of a large window shows.
    static let regionWidth = 6144
    static let regionHeight = 3456

    /// Method name to decode function. All of these are JPEG-only; the harness skips other files.
    static let methods: [String: BenchMethod] = [
        "turbo-full": BenchMethod(formats: [.jpeg], decode: full, label: rowLabel),
        "turbo-scaled": BenchMethod(formats: [.jpeg], decode: scaled, label: rowLabel),
        "turbo-region": BenchMethod(formats: [.jpeg], decode: region, label: rowLabel),
        // Progressive files only; a baseline file has no AC scan to cut at, so it is skipped, not failed.
        "turbo-dc": BenchMethod(
            formats: [.jpeg], decode: dcPrefix, label: rowLabel,
            isApplicable: { JPEGScans.endOfDCScans($0) != nil }),
    ]

    /// Row label for `method` on this file: progressive files get a suffix, since progressive
    /// decoding is much slower and the two kinds must not be averaged together. Parsing the
    /// header again here is outside the timed region.
    static func rowLabel(_ method: String, for data: Data) -> String {
        guard let handle = ltj_init_decompress() else { return method }
        defer { tj3Destroy(handle) }
        let ok = data.withUnsafeBytes { bytes in
            tj3DecompressHeader(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) == 0
        }
        return ok && ltj_get_progressive(handle) != 0 ? "\(method) (progressive)" : method
    }

    /// Decodes the whole image.
    static func full(_ data: Data) throws -> PixelSize {
        try decode(data) { _ in (factor: TJUNSCALED, crop: nil) }
    }

    /// Decodes at the largest DCT reduction whose long side is still at least `previewMinLongSide`
    /// (the IDCT does proportionally less work). Falls back to full size for smaller images.
    static func scaled(_ data: Data) throws -> PixelSize {
        try decode(data) { info in
            var count: Int32 = 0
            guard let factors = tj3GetScalingFactors(&count) else { return (TJUNSCALED, nil) }
            var best = TJUNSCALED
            var bestSide = Int.max
            for i in 0..<Int(count) {
                let f = factors[i]
                let side = max(scaledSize(info.width, f), scaledSize(info.height, f))
                if side >= previewMinLongSide && side < bestSide {
                    best = f
                    bestSide = side
                }
            }
            return (best, nil)
        }
    }

    /// First look of a progressive file: the bytes up to the first AC scan plus an EOI, decoded at
    /// 1/8 (a DC-only image needs no IDCT work beyond that). The prefix copy is inside the timed
    /// call because the viewer pays for it too.
    static func dcPrefix(_ data: Data) throws -> PixelSize {
        guard let end = JPEGScans.endOfDCScans(data) else { throw Failure(description: "no AC scan to cut at (baseline file)") }
        var prefix = Data(capacity: end + 2)
        prefix.append(data.prefix(end))
        prefix.append(contentsOf: [0xFF, 0xD9])
        return try decode(prefix) { _ in (factor: tjscalingfactor(num: 1, denom: 8), crop: nil) }
    }

    /// Decodes a centred `regionWidth` x `regionHeight` rectangle at full scale. TurboJPEG needs
    /// the left edge on an iMCU boundary, so x is aligned down and the width up (clamped to the image).
    static func region(_ data: Data) throws -> PixelSize {
        try decode(data) { info in
            let mcu = Int(ltj_mcu_width(Int32(info.subsamp)))
            guard mcu > 0 else {
                throw Failure(description: "unsupported chroma subsampling (\(info.subsamp)); cropping needs a known iMCU size")
            }
            let w = min(regionWidth, info.width), h = min(regionHeight, info.height)
            let x = (info.width - w) / 2 / mcu * mcu
            let alignedW = min((w + mcu - 1) / mcu * mcu, info.width - x)
            let y = (info.height - h) / 2
            return (TJUNSCALED, tjregion(x: Int32(x), y: Int32(y), w: Int32(alignedW), h: Int32(h)))
        }
    }

    private static func scaledSize(_ dimension: Int, _ factor: tjscalingfactor) -> Int {
        Int(ltj_scaled(Int32(dimension), factor))
    }

    private struct Header {
        var width: Int
        var height: Int
        var subsamp: Int
    }

    /// Shared body: init, header, settings from `plan`, decompress into a fresh page-aligned
    /// BGRA buffer, destroy. Only the decode itself does real work; nothing reads the pixels back.
    private static func decode(
        _ data: Data, plan: (Header) throws -> (factor: tjscalingfactor, crop: tjregion?)
    ) throws -> PixelSize {
        guard let handle = ltj_init_decompress() else { throw Failure(description: "tj3Init failed") }
        defer { tj3Destroy(handle) }
        func check(_ result: Int32, _ what: String) throws {
            if result != 0 { throw Failure(description: "\(what): \(String(cString: tj3GetErrorStr(handle)))") }
        }
        return try data.withUnsafeBytes { bytes in
            let jpeg = bytes.bindMemory(to: UInt8.self)
            try check(tj3DecompressHeader(handle, jpeg.baseAddress, jpeg.count), "tj3DecompressHeader")
            try check(ltj_set_fast_dct(handle, 0), "tj3Set(FASTDCT)")
            // Explicitly off (also the default): a cut-short or oddly terminated stream should still give pixels.
            try check(ltj_set_stop_on_warning(handle, 0), "tj3Set(STOPONWARNING)")
            let info = Header(
                width: Int(ltj_get_width(handle)), height: Int(ltj_get_height(handle)),
                subsamp: Int(ltj_get_subsamp(handle)))
            let (factor, crop) = try plan(info)
            var outWidth = scaledSize(info.width, factor)
            var outHeight = scaledSize(info.height, factor)
            if factor.num != 1 || factor.denom != 1 {
                try check(tj3SetScalingFactor(handle, factor), "tj3SetScalingFactor")
            }
            if let crop {
                try check(tj3SetCroppingRegion(handle, crop), "tj3SetCroppingRegion")
                outWidth = Int(crop.w)
                outHeight = Int(crop.h)
            }
            let bytesPerRow = outWidth * 4
            let pageSize = Int(getpagesize())
            let length = (bytesPerRow * outHeight + pageSize - 1) / pageSize * pageSize
            var raw: UnsafeMutableRawPointer?
            guard posix_memalign(&raw, pageSize, length) == 0, let buffer = raw else {
                throw Failure(description: "posix_memalign(\(length)) failed")
            }
            defer { free(buffer) }
            try check(
                tj3Decompress8(
                    handle, jpeg.baseAddress, jpeg.count, buffer.assumingMemoryBound(to: UInt8.self),
                    Int32(bytesPerRow), ltj_pixel_format_bgra()),
                "tj3Decompress8")
            return PixelSize(width: outWidth, height: outHeight)
        }
    }
}
