import Foundation

/// Versioned, portable inspector data. Unknown optional values in a successful record mean "absent", not "unread".
/// No decoded pixels, runtime colour-space objects or arbitrary source dictionaries are retained.
struct PhotoMetadataRecord: Codable {
    static let readerVersion = 1
    // Storage budgets, not preallocation: at most 256 KiB per file and 16 MiB of payloads in the catalog.
    static let maximumBytes = 256 * 1024
    static let totalBytes = 16 * 1024 * 1024
    static let maximumRecords = 2048
    var metadata: PhotoMetadata
    var header: Header?

    struct Header: Codable {
        var width, height: Int
        var typeIdentifier: String
        var progressive: Bool
        var fileSize: Int
        var colorSpace: String?
        var orientation: Int
    }

    init(_ metadata: PhotoMetadata) {
        self.metadata = metadata
        if let h = metadata.header {
            header = Header(width: h.pixelSize.width, height: h.pixelSize.height, typeIdentifier: h.typeIdentifier,
                            progressive: h.isProgressive, fileSize: h.fileSize, colorSpace: h.colorSpaceName,
                            orientation: h.orientation.rawValue)
        }
    }

    var value: PhotoMetadata {
        var value = metadata
        if let h = header {
            value.header = ImageInfo(pixelSize: PixelSize(width: h.width, height: h.height), typeIdentifier: h.typeIdentifier,
                                     isProgressive: h.progressive, fileSize: h.fileSize, colorSpaceName: h.colorSpace,
                                     orientation: ImageOrientation(rawValue: h.orientation) ?? .up)
        }
        return value
    }
}
