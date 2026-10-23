import CoreGraphics
import LoupeCore
import Foundation
import Metal
@testable import LoupeRender

/// Shared helpers for the renderer tests: synthetic decoded images and texture read-back.
enum TestImages {
    /// A `DecodedImage` whose pixel (x, y) is `pixel(x, y)` as BGRA, stored in a page-aligned buffer
    /// with the decoder's 64-byte row padding.
    static func synthetic(_ width: Int, _ height: Int,
                          colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                          pixel: (Int, Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) -> DecodedImage {
        let bytesPerRow = DecodedImage.bytesPerRow(width: width)
        let buffer = try! PageAlignedBuffer(minimumLength: bytesPerRow * height)
        memset(buffer.bytes, 0, buffer.length)
        let base = buffer.bytes.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixel(x, y), o = y * bytesPerRow + x * 4
                base[o] = p.b; base[o + 1] = p.g; base[o + 2] = p.r; base[o + 3] = p.a
            }
        }
        return DecodedImage(pixelSize: PixelSize(width: width, height: height), bytesPerRow: bytesPerRow,
                            buffer: buffer, colorSpace: colorSpace)
    }

    /// The default pattern: (b: x & 255, g: y & 255, r: (x >> 8) * 16 + (y >> 8), a: 255), unique enough
    /// that a misplaced tile, apron or off-by-one shows up as a different value.
    static func synthetic(_ width: Int, _ height: Int,
                          colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> DecodedImage {
        synthetic(width, height, colorSpace: colorSpace, pixel: pattern)
    }

    static func pattern(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        (UInt8(x & 255), UInt8(y & 255), UInt8(truncatingIfNeeded: (x >> 8) * 16 + (y >> 8)), 255)
    }

    /// Detail no misaligned tap, wrong tap window or wrong tile slot can hide from a PSNR: independent hashed noise
    /// per channel and pixel, overlaid with hard black and white blocks of 37 x 29 px whose edges cross the tile seams
    /// at odd offsets (so ringing and edge handling are exercised next to the seams too).
    static func noiseAndEdges(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        switch (x / 37 + y / 29) % 5 {
        case 0: return (255, 255, 255, 255)
        case 2: return (0, 0, 0, 255)
        default:
            var h = UInt32(truncatingIfNeeded: x) &* 0x9E37_79B1 ^ UInt32(truncatingIfNeeded: y) &* 0x85EB_CA77
            h ^= h >> 15; h = h &* 0x2C1B_3C6D; h ^= h >> 12; h = h &* 0x297A_2D39; h ^= h >> 15
            return (UInt8(truncatingIfNeeded: h), UInt8(truncatingIfNeeded: h >> 8), UInt8(truncatingIfNeeded: h >> 16), 255)
        }
    }

    /// Copies one 528x528 slice of a private texture array through a shared staging buffer and returns its
    /// BGRA bytes (row-major, 528 * 528 * 4). Waits with a completion handler, not a blocking wait.
    static func readSlice(_ texture: MTLTexture, slice: Int, level: Int = 0,
                          context: MetalContext = .shared) async throws -> [UInt8] {
        let side = TileGrid.slotSize, bytesPerRow = side * 4, length = bytesPerRow * side
        guard let staging = context.device.makeBuffer(length: length, options: .storageModeShared),
              let commands = context.queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { throw DecodeError.outOfMemory }
        blit.copy(from: texture, sourceSlice: slice, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: side, height: side, depth: 1), to: staging, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length)
        blit.endEncoding()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            commands.addCompletedHandler { cb in
                if let error = cb.error { c.resume(throwing: error) } else { c.resume() }
            }
            commands.commit()
        }
        return Array(UnsafeBufferPointer(start: staging.contents().assumingMemoryBound(to: UInt8.self), count: length))
    }

    /// The BGRA texel at (x, y) of bytes returned by `readSlice`.
    static func texel(_ bytes: [UInt8], x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let o = (y * TileGrid.slotSize + x) * 4
        return (bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3])
    }

    /// A private 2D render target, as the drawable would be (the read-back below blits it to shared memory). It can be
    /// written by the `resample` compute kernel too, as the drawable can once the layer is not `framebufferOnly`.
    static func renderTarget(_ width: Int, _ height: Int, pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb,
                             context: MetalContext = .shared) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        d.storageMode = .private
        d.usage = [.renderTarget, .shaderWrite]
        return context.device.makeTexture(descriptor: d)!
    }

    /// Copies a 2D texture through a shared staging buffer and returns its BGRA bytes (row-major, tightly packed).
    static func readTexture(_ texture: MTLTexture, context: MetalContext = .shared) async throws -> [UInt8] {
        let bytesPerRow = texture.width * 4, length = bytesPerRow * texture.height
        guard let staging = context.device.makeBuffer(length: length, options: .storageModeShared),
              let commands = context.queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { throw DecodeError.outOfMemory }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: staging,
                  destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length)
        blit.endEncoding()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            commands.addCompletedHandler { cb in
                if let error = cb.error { c.resume(throwing: error) } else { c.resume() }
            }
            commands.commit()
        }
        return Array(UnsafeBufferPointer(start: staging.contents().assumingMemoryBound(to: UInt8.self), count: length))
    }

    /// Reads back pyramid level `level` of `texture` (one `type2DArray` level texture of `grid`) into a
    /// `DecodedImage` of `grid.levelSize(level)`: each tile's content, without aprons, at its content rect.
    static func readLevel(_ texture: MTLTexture, grid: TileGrid, level: Int,
                          colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) async throws -> DecodedImage {
        let size = grid.levelSize(level)
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        for row in 0..<grid.rows(level) {
            for column in 0..<grid.columns(level) {
                let tile = TileID(level: level, column: column, row: row)
                let slice = try await readSlice(texture, slice: grid.slice(of: tile))
                let content = grid.contentRect(tile), slot = grid.slotOrigin(tile)
                for y in content.y..<content.maxY {
                    for x in content.x..<content.maxX {
                        let p = texel(slice, x: x - slot.x, y: y - slot.y), o = (y * size.width + x) * 4
                        pixels[o] = p.b; pixels[o + 1] = p.g; pixels[o + 2] = p.r; pixels[o + 3] = p.a
                    }
                }
            }
        }
        return synthetic(size.width, size.height, colorSpace: colorSpace) { x, y in
            let o = (y * size.width + x) * 4
            return (pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3])
        }
    }
}
