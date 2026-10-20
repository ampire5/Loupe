import CoreGraphics
import Darwin
import Foundation
import ImageIO
import LoupeCore

/// The ImageIO decode paths under test. Each takes the file's bytes (already in memory, so read
/// time stays out of the numbers) and returns the size of the pixels it produced.
enum ImageIOBench {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let previewMaxPixelSize = 3456

    /// Method name to decode function, for the harness to dispatch on. Rows are split by format
    /// (JPEG unsuffixed) so a mixed folder does not average different codecs together.
    static let methods: [String: BenchMethod] = [
        "imageio-full": BenchMethod(formats: Set(ImageFormat.allCases), decode: full, label: ImageFormat.rowLabel),
        "imageio-full-bgra": BenchMethod(formats: Set(ImageFormat.allCases), decode: fullBGRA, label: ImageFormat.rowLabel),
        "imageio-preview": BenchMethod(formats: Set(ImageFormat.allCases), decode: preview, label: ImageFormat.rowLabel),
        "imageio-own": BenchMethod(formats: Set(ImageFormat.allCases), decode: own, label: ImageFormat.rowLabel),
        "imageio-embedded": BenchMethod(formats: [.jpeg], decode: embedded, label: embeddedLabel),
    ]

    /// Decodes at full size into ImageIO's own buffer. `ShouldCacheImmediately` makes the decode
    /// happen inside the create call; the buffer is deliberately not read afterwards, because
    /// `dataProvider.data` would copy it and add that copy to the timing.
    static func full(_ data: Data) throws -> PixelSize {
        try withSource(data) { source in
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
                throw Failure(description: "CGImageSourceCreateImageAtIndex failed")
            }
            return PixelSize(width: image.width, height: image.height)
        }
    }

    /// Decodes at full size by drawing into a page-aligned BGRA8 premultiplied Display P3 buffer,
    /// the layout the viewer wants in memory and for tile upload.
    static func fullBGRA(_ data: Data) throws -> PixelSize {
        try drawn(data) { _ in CGColorSpace(name: CGColorSpace.displayP3) }
    }

    /// What the viewer's decoder does without a colour conversion: create the image lazily (no
    /// `ShouldCacheImmediately`, so ImageIO does not decode into a buffer of its own first), then
    /// draw it into a page-aligned BGRA8 buffer tagged with the image's own colour space. When the
    /// source space is not an RGB one a BGRA context accepts (gray, CMYK, indexed), sRGB stands in.
    static func own(_ data: Data) throws -> PixelSize {
        try drawn(data) { image in
            if let space = image.colorSpace, space.model == .rgb { return space }
            return CGColorSpace(name: CGColorSpace.sRGB)
        }
    }

    /// Creates the image, then draws it into a fresh page-aligned BGRA buffer in `space(image)`.
    private static func drawn(_ data: Data, space: (CGImage) -> CGColorSpace?) throws -> PixelSize {
        try withSource(data) { source in
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw Failure(description: "CGImageSourceCreateImageAtIndex failed")
            }
            let width = image.width, height = image.height
            let bytesPerRow = width * 4
            let pageSize = Int(getpagesize())
            let length = (bytesPerRow * height + pageSize - 1) / pageSize * pageSize
            var raw: UnsafeMutableRawPointer?
            guard posix_memalign(&raw, pageSize, length) == 0, let buffer = raw else {
                throw Failure(description: "posix_memalign(\(length)) failed")
            }
            defer { free(buffer) }
            guard let space = space(image),
                  let context = CGContext(
                      data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw Failure(description: "CGContext creation failed") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return PixelSize(width: width, height: height)
        }
    }

    /// The preview embedded in the file (JPEG EXIF thumbnail), as is: `FromImageIfAbsent: false`
    /// means ImageIO must not decode the full image to make one, so a file without a preview fails.
    /// The size cap is far above any embedded preview, so the returned size is the stored one.
    static func embedded(_ data: Data) throws -> PixelSize {
        guard let image = try embeddedThumbnail(data) else { throw Failure(description: "no embedded thumbnail") }
        return PixelSize(width: image.width, height: image.height)
    }

    /// Row label carrying the embedded preview's size, `imageio-embedded (WxH)`; plain when absent.
    /// Runs outside the timed region, and splits rows by size so different previews are not averaged.
    static func embeddedLabel(_ method: String, for data: Data) -> String {
        guard let image = try? embeddedThumbnail(data) else { return method }
        return "\(method) (\(image.width)x\(image.height))"
    }

    private static func embeddedThumbnail(_ data: Data) throws -> CGImage? {
        try withSource(data) { source in
            let options = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceThumbnailMaxPixelSize: 100_000,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        }
    }

    /// Decodes straight to a reduced size (long side `previewMaxPixelSize`), which lets the JPEG
    /// decoder skip work with DCT scaling instead of decoding every pixel.
    static func preview(_ data: Data) throws -> PixelSize {
        try withSource(data) { source in
            let options = [
                kCGImageSourceThumbnailMaxPixelSize: previewMaxPixelSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                throw Failure(description: "CGImageSourceCreateThumbnailAtIndex failed")
            }
            return PixelSize(width: image.width, height: image.height)
        }
    }

    /// Wraps `data` in a CFData without copying it, for the duration of `body`.
    private static func withSource<T>(_ data: Data, _ body: (CGImageSource) throws -> T) throws -> T {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress,
                  let cfData = CFDataCreateWithBytesNoCopy(nil, base.assumingMemoryBound(to: UInt8.self), bytes.count, kCFAllocatorNull),
                  let source = CGImageSourceCreateWithData(cfData, nil)
            else { throw Failure(description: "CGImageSourceCreateWithData failed") }
            return try body(source)
        }
    }
}
