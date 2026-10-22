import Foundation

/// libjxl can only write RGBA; the renderer wants BGRA premultiplied. Done in place over the
/// decoder's own output so a large image never needs a second buffer.
enum RGBAToBGRA {
    /// Swaps R and B in every pixel and, when `premultiply`, scales the colour by alpha, in `workers` row bands at once
    /// (the decoder's own thread count: a neighbour's pass never takes every core). Rows are `bytesPerRow` apart; only
    /// the first `width * 4` bytes of each are touched. The pass is bound by memory, not the cores: 147 MP takes ~90 ms
    /// on 2 bands as on 16 (i7-10700K, `LoupeBench panload --cpu --no-upload --workers N`).
    static func convert(_ base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int, premultiply: Bool,
                        workers: Int) {
        let bands = max(1, workers)
        let rowsPerBand = (height + bands - 1) / bands
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let start = band * rowsPerBand, end = min(height, start + rowsPerBand)
            guard start < end else { return }
            for y in start..<end {
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
                if premultiply {
                    for x in 0..<width { row[x] = premultipliedBGRA(row[x]) }
                } else {
                    for x in 0..<width { row[x] = swizzled(row[x]) }
                }
            }
        }
    }

    /// Little-endian RGBA word to BGRA word (alpha stays on top, bytes 0 and 2 trade places).
    @inline(__always) static func swizzled(_ p: UInt32) -> UInt32 {
        (p & 0xFF00_FF00) | (p & 0xFF) << 16 | (p >> 16) & 0xFF
    }

    /// `swizzled` with each colour channel multiplied by alpha/255, rounded to nearest.
    @inline(__always) static func premultipliedBGRA(_ p: UInt32) -> UInt32 {
        let alpha = p >> 24
        if alpha == 0xFF { return swizzled(p) }
        func scale(_ c: UInt32) -> UInt32 {
            let t = c * alpha + 128
            return (t + (t >> 8)) >> 8
        }
        return alpha << 24 | scale(p & 0xFF) << 16 | scale((p >> 8) & 0xFF) << 8 | scale((p >> 16) & 0xFF)
    }
}
