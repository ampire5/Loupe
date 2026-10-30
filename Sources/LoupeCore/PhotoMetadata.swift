import Foundation
import HomeScreenModel
import ImageIO

/// What the info panel says about a photo beyond the decoder's own facts: capture settings from ImageIO's properties,
/// the generation text of AI pictures, the file's dates. Every field is the finished string, nil when the file has none.
public struct PhotoMetadata: Equatable, Sendable, Codable {
    public var camera, lens, focalLength, aperture, exposure, iso, captured, gps, software, description: String?
    /// Exposure compensation: `−0.3 EV`, `+1 EV` (nil at zero).
    public var compensation: String?
    /// A1111 `parameters` text (PNG) or the EXIF UserComment (JPEG / WebP).
    public var generation: String?
    /// Size of the ComfyUI `workflow` (or `prompt`) chunk text, for "ComfyUI workflow, N KB"; the JSON is not parsed.
    public var comfyWorkflowBytes: Int?
    public var created, modified: Date?
    /// Bits per channel as ImageIO reports them (`kCGImagePropertyDepth`), 1...64; nil when the file does not say.
    public var bitDepth: Int?
    /// `kCGImagePropertyHasAlpha`; nil when the file does not say.
    public var hasAlpha: Bool?
    /// One short line when the file cannot be read as an image.
    public var error: String?
    /// The header facts of an ImageIO-readable file (`ImageIODecoder.probe`), so the panel's File section is complete
    /// before the decoder has read the photo; nil for a file ImageIO cannot read (JPEG XL) and for a failed read.
    public var header: ImageInfo? = nil

    // Rendering objects are not persisted. PhotoMetadataRecord keeps the portable header alongside this payload.
    private enum CodingKeys: String, CodingKey {
        case camera, lens, focalLength, aperture, exposure, iso, captured, gps, software, description
        case compensation, generation, comfyWorkflowBytes, created, modified, bitDepth, hasAlpha, error
    }

    /// `pngSizes` holds the true byte length of PNG text that the reader cut (`PNGText.readAll`); a missing key means "as long as the text".
    public init(properties: [String: Any], pngText: [String: String], pngSizes: [String: Int] = [:], created: Date?, modified: Date?) {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        self.created = created
        self.modified = modified

        let make = Self.string(tiff[kCGImagePropertyTIFFMake as String])
        let model = Self.string(tiff[kCGImagePropertyTIFFModel as String])
        switch (make, model) {
        case let (make?, model?):
            // "NIKON CORPORATION" + "NIKON Z 6": the model already starts with the make's first word.
            let brand = make.split(separator: " ").first.map { $0.lowercased() } ?? make.lowercased()
            camera = model.lowercased().hasPrefix(brand) ? model : "\(make) \(model)"
        case let (make?, nil): camera = make
        case let (nil, model?): camera = model
        default: camera = nil
        }
        if let depth = Self.double(properties[kCGImagePropertyDepth as String]), depth.isFinite, depth >= 1, depth <= 64 {
            bitDepth = Int(depth)
        }
        hasAlpha = properties[kCGImagePropertyHasAlpha as String] as? Bool
        lens = Self.string(exif[kCGImagePropertyExifLensModel as String])
        software = Self.string(tiff[kCGImagePropertyTIFFSoftware as String])
        description = Self.string(tiff[kCGImagePropertyTIFFImageDescription as String])

        if let f = Self.sane(exif[kCGImagePropertyExifFocalLength as String]) {
            var text = "\(Self.number(f)) mm"
            if let e = Self.sane(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]) { text += " (\(Self.number(e)) mm equiv.)" }
            focalLength = text
        }
        if let a = Self.sane(exif[kCGImagePropertyExifFNumber as String]) { aperture = "f/\(Self.number(a))" }
        if let t = Self.sane(exif[kCGImagePropertyExifExposureTime as String], atLeast: 1e-9) {
            // The style guide's shutter (D): `1/250 s`, `0.5 s`, `2″`.
            exposure = t < 0.4 ? "1/\(Int((1 / t).rounded())) s" : FileFactsText.shutter(t)
        }
        if let ev = Self.double(exif[kCGImagePropertyExifExposureBiasValue as String]), ev.isFinite, abs(ev) >= 0.05 {
            compensation = FileFactsText.bias(ev)
        }
        let speed = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any])?.first
        if let iso = Self.sane(speed) { self.iso = "ISO \(Int(iso.rounded()))" }
        captured = Self.string(exif[kCGImagePropertyExifDateTimeOriginal as String]).map(Self.captureDate)
        self.gps = Self.position(gps)

        generation = Self.nonEmpty(pngText["parameters"]) ?? Self.userComment(exif[kCGImagePropertyExifUserComment as String])
        if let key = ["workflow", "prompt"].first(where: { pngText[$0] != nil }) {
            comfyWorkflowBytes = pngSizes[key] ?? pngText[key]?.utf8.count
        }
    }

    /// ImageIO's properties of the file's first image (header only) plus, for a PNG, its text chunks. An entry of a
    /// zip is read whole from the archive (Stash spec §2.4): its size and mtime are the entry's stamp, its creation
    /// date the archive's.
    public static func read(_ url: URL) -> PhotoMetadata {
        if ArchivePath.split(url) != nil { return readEntry(url) }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
        let created = values?.creationDate, modified = values?.contentModificationDate
        func failed(_ message: String) -> PhotoMetadata {
            var m = PhotoMetadata(properties: [:], pngText: [:], created: created, modified: modified)
            m.error = message
            return m
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return failed("File not found") }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return failed("Not a readable image file") }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any] else {
            return failed("No image data in the file")
        }
        let isPNG = CGImageSourceGetType(source) as String? == "public.png"
        let png = isPNG ? PNGText.readAll(url) : PNGText.Result()
        var m = PhotoMetadata(properties: properties, pngText: png.text, pngSizes: png.sizes, created: created, modified: modified)
        m.header = try? ImageIODecoder.probe(source, fileSize: values?.fileSize ?? 0)
        return m
    }

    private static func readEntry(_ url: URL) -> PhotoMetadata {
        let archive = url.deletingLastPathComponent()
        let created = (try? archive.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        let bytes: FileBytes
        do {
            bytes = try ArchiveReader.shared.read(url)
        } catch {
            var m = PhotoMetadata(properties: [:], pngText: [:], created: created, modified: nil)
            m.error = (error as? ArchiveError)?.text ?? "File not found"
            return m
        }
        let modified = bytes.stamp.modified
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes.data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any] else {
            var m = PhotoMetadata(properties: [:], pngText: [:], created: created, modified: modified)
            m.error = "Not a readable image file"
            return m
        }
        let isPNG = CGImageSourceGetType(source) as String? == "public.png"
        let png = isPNG ? PNGText.readAll(data: bytes.data) : PNGText.Result()
        var m = PhotoMetadata(properties: properties, pngText: png.text, pngSizes: png.sizes, created: created,
                              modified: modified)
        m.header = try? ImageIODecoder.probe(source, fileSize: bytes.stamp.size)
        return m
    }

    // MARK: formatting

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// A positive, finite number a string can safely be made of: EXIF rationals with a zero denominator give inf / nan,
    /// and absurd values must not reach an `Int(...)` conversion.
    private static func sane(_ value: Any?, atLeast low: Double = 0.05) -> Double? {
        guard let d = double(value), d.isFinite, d >= low, d <= 1e9 else { return nil }
        return d
    }

    private static func string(_ value: Any?) -> String? {
        nonEmpty(value as? String)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\0", with: ""), !t.isEmpty else { return nil }
        return t
    }

    /// 50 → "50", 2.8 → "2.8", 5.70 → "5.7": one decimal at most, none when it would be ".0".
    private static func number(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// "2024:05:01 12:34:56" → "2024-05-01 12:34:56"; anything else as it is.
    private static func captureDate(_ raw: String) -> String {
        let c = Array(raw)
        guard c.count >= 19, c[4] == ":", c[7] == ":" else { return raw }
        var out = c
        out[4] = "-"; out[7] = "-"
        return String(out)
    }

    private static func position(_ gps: [String: Any]) -> String? {
        guard let lat = double(gps[kCGImagePropertyGPSLatitude as String]), let lon = double(gps[kCGImagePropertyGPSLongitude as String]),
              lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180
        else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() ?? (lat < 0 ? "S" : "N")
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() ?? (lon < 0 ? "W" : "E")
        var text = String(format: "%.4f° %@, %.4f° %@", abs(lat), latRef, abs(lon), lonRef)
        if let alt = double(gps[kCGImagePropertyGPSAltitude as String]), alt.isFinite, abs(alt) <= 1e9 {
            let below = double(gps[kCGImagePropertyGPSAltitudeRef as String]) == 1
            text += String(format: ", %.0f m", below ? -abs(alt) : abs(alt))
        }
        return text
    }

    /// The EXIF UserComment as a string, or as raw bytes behind their 8-byte character-code prefix.
    private static func userComment(_ value: Any?) -> String? {
        if let s = value as? String { return nonEmpty(s) }
        guard let d = value as? Data, d.count > 8 else { return nil }
        let prefix = String(decoding: d.prefix(8), as: UTF8.self)
        let body = d.dropFirst(8)
        let text = prefix.hasPrefix("UNICODE") ? String(data: body, encoding: .utf16BigEndian) : String(data: body, encoding: .utf8)
        return nonEmpty(text)
    }
}
