import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A saved result belongs to one revision of a photo, including a member of a ZIP. Copies stay out of playlists.
package struct SavedUpscale: Sendable, Hashable {
    package static let directoryName = ".loupe-upscales"
    package static let badge = "Upscale"
    private static let avif = ThumbnailEncoding.Format.avif.typeIdentifier
    // M4 Max, 7680×4320: ImageIO q78 was 1.81 MB at 0.60 s, against PNG's 28.92 MB at 1.11 s.
    private static let avifQuality = 0.78
    private static let promotedAttribute = "com.loupe.upscale.promoted"
    package let source: URL
    package let stamp: FileStamp

    package init(source: URL, stamp: FileStamp) {
        self.source = source.standardizedFileURL
        self.stamp = stamp
    }

    package var file: URL {
        let original = Data(source.lastPathComponent.utf8)
        let name = String(decoding: original.prefix(96), as: UTF8.self)
        let identity: Data
        if let archive = ArchivePath.split(source)?.archive {
            var qualified = Data(archive.lastPathComponent.utf8)
            qualified.append(0)
            qualified.append(original)
            identity = qualified
        } else {
            identity = original
        }
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return Self.directory(for: source)
            .appendingPathComponent("\(name)--\(digest)-\(Self.revision(stamp)).avif")
    }

    var previewFile: URL { file.deletingPathExtension().appendingPathExtension("thumb.jpg") }

    private static func revision(_ stamp: FileStamp) -> String {
        let date = String(stamp.modified.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
        return "\(date)-\(stamp.size)"
    }

    package static func directory(in folder: URL) -> URL {
        folder.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func directory(for source: URL) -> URL {
        directory(in: (ArchivePath.split(source)?.archive ?? source).deletingLastPathComponent())
    }

    package static func supports(_ url: URL) -> Bool {
        url.isFileURL && PhotosLocation.asset(in: url) == nil && !WebImageLocation.owns(url)
            && PlaybackMedia.candidate(url) == nil
    }

    private func sourceAttributes() throws -> stat {
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, FileStamp(info) == stamp else {
            throw SaveError.sourceChanged
        }
        return info
    }

    private func validateSource() throws {
        if ArchivePath.split(source) != nil {
            guard try ArchiveReader.shared.stamp(source) == stamp else { throw SaveError.sourceChanged }
        } else {
            _ = try sourceAttributes()
        }
    }

    package var exists: Bool {
        guard Self.supports(source), (try? validateSource()) != nil else { return false }
        var info = stat()
        return lstat(file.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    package var isPromoted: Bool {
        guard ArchivePath.split(source) == nil, (try? sourceAttributes()) != nil else { return false }
        let expected = Array(Self.revision(stamp).utf8)
        var bytes = [UInt8](repeating: 0, count: expected.count)
        let count = getxattr(source.path, Self.promotedAttribute, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        return count == expected.count && bytes == expected
    }

    package func matches(model: String) -> Bool {
        modelIdentity == model
    }

    package var modelIdentity: String? { metadata?.model }

    package var metadata: (orientation: ImageOrientation, model: String)? {
        guard let image = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageSourceGetType(image) as String? == Self.avif,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let comment = exif[kCGImagePropertyExifUserComment] as? String,
              let separator = comment.firstIndex(of: ":"),
              let raw = Int(comment[..<separator]), let orientation = ImageOrientation(rawValue: raw)
        else { return nil }
        return (orientation, String(comment[comment.index(after: separator)...]))
    }

    package func write(_ pixels: DecodedImage, orientation: ImageOrientation, model: String,
                       beforeCommit: () throws -> Void = {}) throws {
        try validateSource()
        let target = file
        let directory = target.deletingLastPathComponent()
        try Self.makeDirectory(directory)
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // ImageIO writes AVIF upright. Store the display orientation in the pixels and remember the original
        // orientation in EXIF so a viewer pyramid or an original replacement can restore the stored axes.
        let oriented = try ThumbnailMaker.orientedPixels(pixels, by: orientation)
        let image = try Self.makeImage(oriented)
        try Self.encode(image, to: temporary, type: Self.avif, orientation: .up,
                        comment: "\(orientation.rawValue):\(model)")
        try beforeCommit()
        try validateSource()
        try Self.rename(temporary, to: target)
        // File View reads a small pre-rendered JPEG, keeping the original thumbnail catalog intact.
        let previewSize = ThumbnailMaker.thumbnailSize(of: pixels.pixelSize, maxSide: Config().thumbSize)
        do {
            let preview = try ThumbnailMaker.encode(pixels, size: previewSize, orientation: orientation)
            try preview.write(to: previewFile, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: previewFile)
        }
    }

    private static func makeImage(_ pixels: DecodedImage) throws -> CGImage {
        let retained = Unmanaged.passRetained(pixels.buffer)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: pixels.buffer.bytes,
                                            size: pixels.bytesPerRow * pixels.pixelSize.height, releaseData: { info, _, _ in
            if let info { Unmanaged<PageAlignedBuffer>.fromOpaque(info).release() }
        }) else {
            retained.release()
            throw SaveError.encode
        }
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(width: pixels.pixelSize.width, height: pixels.pixelSize.height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: pixels.bytesPerRow, space: pixels.colorSpace,
                                  bitmapInfo: bitmap, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .relativeColorimetric) else { throw SaveError.encode }
        return image
    }

    package var replacementType: UTType? {
        guard ArchivePath.split(source) == nil else { return nil }
        return switch source.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe": .jpeg
        case "png": .png
        default: nil
        }
    }

    /// Stage a same-format replacement and keep the complete original before committing the rename.
    package func replaceOriginal() throws {
        guard let type = replacementType else { throw SaveError.format }
        let info = try sourceAttributes()
        guard let original = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetType(original) as String? == type.identifier else { throw SaveError.format }
        guard exists, let metadata,
              let properties = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw SaveError.missingCopy }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let decoder = ImageIOImageDecoder()
        let header = try decoder.probe(data)
        let sourceSize = metadata.orientation.orientedSize(PixelSize(width: width, height: height))
        guard [2, 4].contains(where: { header.pixelSize.width == sourceSize.width * $0
            && header.pixelSize.height == sourceSize.height * $0 }) else { throw SaveError.missingCopy }
        let decoded = try decoder.decodeFull(data, info: header)
        let pixels = try ThumbnailMaker.orientedPixels(decoded, by: metadata.orientation.inverse)
        let image = try Self.makeImage(pixels)
        let rawOrientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let orientation = ImageOrientation(rawValue: rawOrientation) ?? .up
        let directory = file.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.encode(image, to: temporary, type: type.identifier, orientation: orientation)
        guard chmod(temporary.path, mode_t(info.st_mode & 0o777)) == 0 else { throw Self.posixError }
        var replacement = stat()
        guard lstat(temporary.path, &replacement) == 0 else { throw Self.posixError }
        let marker = Array(Self.revision(FileStamp(replacement)).utf8)
        let marked = marker.withUnsafeBytes {
            setxattr(temporary.path, Self.promotedAttribute, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard marked == 0 else { throw Self.posixError }
        let backups = directory.appendingPathComponent("Originals", isDirectory: true)
        try Self.makeDirectory(backups)
        let filename = source.lastPathComponent
        let name = filename.utf8.count <= 200 ? filename : "original.\(source.pathExtension)"
        let backup = backups.appendingPathComponent("\(UUID().uuidString)-\(name)")
        do {
            try FileManager.default.copyItem(at: source, to: backup)
            _ = try sourceAttributes()
            try Self.rename(temporary, to: source)
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw error
        }
    }

    private static func encode(_ image: CGImage, to url: URL, type: String,
                               orientation: ImageOrientation, comment: String? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)
        else { throw SaveError.encode }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation.rawValue]
        if type == UTType.jpeg.identifier { properties[kCGImageDestinationLossyCompressionQuality] = 0.98 }
        if type == avif { properties[kCGImageDestinationLossyCompressionQuality] = avifQuality }
        if let comment { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: comment] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SaveError.encode }
    }

    private static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw SaveError.format }
    }

    private static func rename(_ from: URL, to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw posixError }
    }

    private static var posixError: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private enum SaveError: LocalizedError {
        case sourceChanged, format, encode, missingCopy

        var errorDescription: String? {
            switch self {
            case .sourceChanged: "The original has changed or is no longer available."
            case .format: "Only regular JPEG and PNG photos can be replaced."
            case .encode: "Loupe could not encode the enhanced photo."
            case .missingCopy: "The saved upscale is missing or unreadable."
            }
        }
    }
}
