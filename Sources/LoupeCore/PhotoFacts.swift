import Foundation
import HomeScreenModel
import ImageIO

/// A photo's facts for its card (HomeScreenKit's file-cards spec): its pixels and EXIF (camera, lens, exposure, the
/// date taken), from ImageIO's properties of bytes already read for the thumbnail, or of the file's header alone.
public enum PhotoFacts {
    /// From bytes in memory (the thumbnail's read: a whole file or a prefix with its header); nil when ImageIO cannot
    /// read their header (JPEG XL).
    public static func read(_ data: Data) -> FileFacts? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return read(source)
    }

    /// From the file's header (ImageIO reads only what the properties need): a thumbnail made before facts were kept.
    public static func read(url: URL) -> FileFacts? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return read(source)
    }

    static func read(_ source: CGImageSource) -> FileFacts? {
        guard CGImageSourceGetCount(source) > 0,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                  as? [CFString: Any] else { return nil }
        return facts(properties: p)
    }

    /// The facts in ImageIO's properties: the size as shown (a quarter turn by EXIF orientation trades the sides).
    public static func facts(properties p: [CFString: Any]) -> FileFacts? {
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var width = p[kCGImagePropertyPixelWidth] as? Int, height = p[kCGImagePropertyPixelHeight] as? Int
        if let o = p[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { swap(&width, &height) }
        let speed = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first
        let facts = FileFacts(width: width, height: height,
                              camera: FileFactsText.camera(make: text(tiff[kCGImagePropertyTIFFMake]),
                                                           model: text(tiff[kCGImagePropertyTIFFModel])),
                              lens: text(exif[kCGImagePropertyExifLensModel]),
                              exposure: positive(exif[kCGImagePropertyExifExposureTime]),
                              aperture: positive(exif[kCGImagePropertyExifFNumber]),
                              iso: positive(speed).map { Int($0.rounded()) },
                              focalLength: positive(exif[kCGImagePropertyExifFocalLength]),
                              exposureBias: nonZero(exif[kCGImagePropertyExifExposureBiasValue]),
                              taken: text(exif[kCGImagePropertyExifDateTimeOriginal]).flatMap(date))
        return facts == FileFacts() ? nil : facts
    }

    private static func text(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              !s.isEmpty else { return nil }
        return s
    }

    private static func nonZero(_ value: Any?) -> Double? {
        guard let n = (value as? NSNumber)?.doubleValue, n.isFinite, n != 0 else { return nil }
        return n
    }

    private static func positive(_ value: Any?) -> Double? {
        guard let n = (value as? NSNumber)?.doubleValue, n.isFinite, n > 0 else { return nil }
        return n
    }

    /// EXIF's `2024:06:01 14:03:22`, in the photo's own (unknown) zone: read as local time, as cameras write it.
    static func date(_ text: String) -> Date? { exifDate.date(from: text) }

    private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}
