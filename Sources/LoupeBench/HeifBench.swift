import CHeif
import Darwin
import Dispatch
import Foundation
import LoupeCore

/// The libheif decode paths under test for HEIC and AVIF: the whole image, and only the tiles
/// that cover a centred 100 %-view-sized rectangle. Both decode to interleaved RGBA8 (libheif has
/// no BGRA output, so unlike the other methods the channel order and straight alpha differ; the
/// decode cost is what is compared). libheif allocates the output; it is released inside the
/// timed call and never read.
///
/// Parallelism is fixed so the rows are comparable with `jxl-full` (10 threads): libheif has two
/// thread knobs, its own pool for decoding grid tiles (`heif_context_set_max_decoding_threads`)
/// and the codec's internal threading (`num_codec_threads`). Codec threads are pinned to 1 in
/// both methods. `heif-full` gives the pool 10 threads; `heif-tiles` sets the pool to 0 (tiles
/// decoded on the calling thread) and parallelises itself with 10 workers, so the two never stack.
enum HeifBench {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Centre crop the tile decode must cover: the same rectangle `turbo-region` decodes.
    static let regionWidth = 6144
    static let regionHeight = 3456
    /// Worker threads: libheif's tile pool for `heif-full`, our own workers for `heif-tiles`.
    static let tileThreads = 10
    /// Threads inside each codec instance (libde265, dav1d, ...); 0 would mean the codec's default.
    static let codecThreads: Int32 = 1

    static let methods: [String: BenchMethod] = [
        "heif-full": BenchMethod(formats: [.heic, .avif], decode: full, label: ImageFormat.rowLabel),
        "heif-tiles": BenchMethod(formats: [.heic, .avif], decode: tiles, label: tilesLabel),
    ]

    /// Decodes the whole primary image.
    static func full(_ data: Data) throws -> PixelSize {
        try withPrimaryHandle(data, poolThreads: tileThreads, decodeWhole)
    }

    private static func decodeWhole(_ handle: OpaquePointer) throws -> PixelSize {
        let options = heif_decoding_options_alloc()
        defer { heif_decoding_options_free(options) }
        options?.pointee.num_codec_threads = codecThreads
        var image: OpaquePointer?
        try check(heif_decode_image(handle, &image, heif_colorspace_RGB, heif_chroma_interleaved_RGBA, options), "heif_decode_image")
        defer { heif_image_release(image) }
        return PixelSize(width: Int(heif_image_get_width(image, heif_channel_interleaved)),
                         height: Int(heif_image_get_height(image, heif_channel_interleaved)))
    }

    /// Decodes only the tiles that intersect the centred `regionWidth` x `regionHeight` rectangle,
    /// spread over `tileThreads` workers, each with its own libheif context. The reported size is the bounding box of the decoded
    /// tiles (what was actually decoded, clamped to the image), not the requested rectangle.
    /// An image libheif reports as a single tile is decoded whole instead.
    static func tiles(_ data: Data) throws -> PixelSize {
        try withPrimaryHandle(data, poolThreads: 0) { handle in
            var tiling = heif_image_tiling()
            try check(heif_image_handle_get_image_tiling(handle, 1, &tiling), "heif_image_handle_get_image_tiling")
            guard tiling.num_columns > 1 || tiling.num_rows > 1 else {
                return try decodeWhole(handle)
            }
            let plan = TilePlan(tiling, regionWidth: regionWidth, regionHeight: regionHeight)
            let options = heif_decoding_options_alloc()
            defer { heif_decoding_options_free(options) }
            options?.pointee.num_codec_threads = codecThreads

            // Each worker opens its own context on the same bytes: libheif serialises tile decodes
            // that share a context (measured: durations stack up behind one another), so a shared
            // handle would give no parallelism. Opening the file is cheap next to decoding.
            let lock = NSLock()
            var firstError: Error?
            let workers = min(tileThreads, plan.count)
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                do {
                    try withPrimaryHandle(data, poolThreads: 0) { handle in
                        var index = worker
                        while index < plan.count {
                            let (col, row) = plan.tile(index)
                            var image: OpaquePointer?
                            try check(
                                heif_image_handle_decode_image_tile(
                                    handle, &image, heif_colorspace_RGB, heif_chroma_interleaved_RGBA, options, UInt32(col), UInt32(row)),
                                "tile \(col),\(row)")
                            heif_image_release(image)
                            index += workers
                        }
                    }
                } catch {
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
            }
            if let firstError { throw firstError }
            return plan.decodedSize
        }
    }

    /// Row label: the tile size (it differs per file, e.g. 1024x1024 HEIC versus AVIF strips, and
    /// decides the cost), or `untiled` when the image has nothing to decode independently.
    static func tilesLabel(_ name: String, _ data: Data) -> String {
        let tile: String? = try? withPrimaryHandle(data, poolThreads: 0) { handle in
            var tiling = heif_image_tiling()
            try check(heif_image_handle_get_image_tiling(handle, 1, &tiling), "tiling")
            guard tiling.num_columns > 1 || tiling.num_rows > 1 else { return nil }
            return "\(tiling.tile_width)x\(tiling.tile_height)"
        }
        let format = ImageFormat.variantName(data) ?? "heif"
        return tile.map { "\(name) (\(format), \($0) tiles)" } ?? "\(name) (\(format), untiled)"
    }

    /// The tiles covering the centred region, in row-major order.
    struct TilePlan {
        let firstColumn: Int, firstRow: Int, columns: Int, rows: Int
        let decodedSize: PixelSize

        init(_ tiling: heif_image_tiling, regionWidth: Int, regionHeight: Int) {
            let imageW = Int(tiling.image_width), imageH = Int(tiling.image_height)
            let tileW = Int(tiling.tile_width), tileH = Int(tiling.tile_height)
            let w = min(regionWidth, imageW), h = min(regionHeight, imageH)
            let x0 = (imageW - w) / 2, y0 = (imageH - h) / 2
            // The grid may start at a negative offset (cropped or rotated images).
            let originX = -Int(tiling.left_offset), originY = -Int(tiling.top_offset)
            let cols = Int(tiling.num_columns), rowsTotal = Int(tiling.num_rows)
            firstColumn = max(0, (x0 - originX) / tileW)
            firstRow = max(0, (y0 - originY) / tileH)
            let lastColumn = min(cols - 1, (x0 + w - 1 - originX) / tileW)
            let lastRow = min(rowsTotal - 1, (y0 + h - 1 - originY) / tileH)
            columns = lastColumn - firstColumn + 1
            rows = lastRow - firstRow + 1
            let left = max(0, originX + firstColumn * tileW), top = max(0, originY + firstRow * tileH)
            let right = min(imageW, originX + (lastColumn + 1) * tileW)
            let bottom = min(imageH, originY + (lastRow + 1) * tileH)
            decodedSize = PixelSize(width: right - left, height: bottom - top)
        }

        var count: Int { columns * rows }

        func tile(_ index: Int) -> (column: Int, row: Int) {
            (firstColumn + index % columns, firstRow + index / columns)
        }
    }

    // MARK: - libheif plumbing

    private static func message(_ error: heif_error) -> String {
        error.message.map { String(cString: $0) } ?? "error \(error.code.rawValue)"
    }

    private static func check(_ error: heif_error, _ what: String) throws {
        if error.code != heif_error_Ok { throw Failure(description: "\(what): \(message(error))") }
    }

    /// Opens `data` without copying it and hands `body` the primary image handle; everything is
    /// released afterwards. The context must outlive the handle, so both live in this scope.
    /// `poolThreads` sizes libheif's own tile-decoding pool (0 = decode on the calling thread).
    private static func withPrimaryHandle<T>(
        _ data: Data, poolThreads: Int, _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        try data.withUnsafeBytes { bytes in
            guard let context = heif_context_alloc() else { throw Failure(description: "heif_context_alloc failed") }
            defer { heif_context_free(context) }
            heif_context_set_max_decoding_threads(context, Int32(poolThreads))
            try check(heif_context_read_from_memory_without_copy(context, bytes.baseAddress, bytes.count, nil), "heif_context_read_from_memory_without_copy")
            var handle: OpaquePointer?
            try check(heif_context_get_primary_image_handle(context, &handle), "heif_context_get_primary_image_handle")
            guard let handle else { throw Failure(description: "no primary image") }
            defer { heif_image_handle_release(handle) }
            return try body(handle)
        }
    }
}
