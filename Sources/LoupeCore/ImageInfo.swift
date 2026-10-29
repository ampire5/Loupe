import CoreGraphics
import HomeScreenModel

/// What a file header says about an image, cheap enough to read before committing to a decode.
public struct ImageInfo: Equatable, Sendable {
    /// As stored; `orientedSize` is the size as shown.
    public let pixelSize: PixelSize
    /// Uniform type identifier, e.g. "public.jpeg".
    public let typeIdentifier: String
    /// `kCGImagePropertyJFIFIsProgressive`; progressive JPEGs decode slower, which the UI may want to know.
    public let isProgressive: Bool
    public let fileSize: Int
    /// How stats name the colour space of the decoded pixels: the profile's description (`sRGB`, `Display P3`, `Adobe RGB (1998)`),
    /// `Gray → Display P3` or `CMYK → Display P3` for an image converted on decode, `ICC (unnamed)` for a profile without a
    /// description (`EmbeddedColorSpace`). Nil when the header does not say.
    /// `formatVersion` 2 wipes the rows made before M3b, so only rows made by M3b build 1 keep their old names.
    public let colorSpaceName: String?
    /// The file's own EXIF (or JXL header) orientation; the pixels are stored unrotated.
    public let orientation: ImageOrientation
    /// The colour space the decoder will hand the pixels in, when the header tells it (nil: not known before
    /// decoding). The viewer tags its layer with it ahead of the pixels when nothing else is on screen.
    public let colorSpace: CGColorSpace?
    /// The photo's facts for its card (pixels, EXIF: `PhotoFacts`), read with the thumbnail and kept in the catalog
    /// beside it; nil when not read (the viewer's own decodes do not).
    public var facts: FileFacts?

    public init(pixelSize: PixelSize, typeIdentifier: String, isProgressive: Bool, fileSize: Int, colorSpaceName: String?,
                orientation: ImageOrientation = .up, colorSpace: CGColorSpace? = nil) {
        self.pixelSize = pixelSize
        self.typeIdentifier = typeIdentifier
        self.isProgressive = isProgressive
        self.fileSize = fileSize
        self.colorSpaceName = colorSpaceName
        self.orientation = orientation
        self.colorSpace = colorSpace
    }

    /// The size as shown, with the file's orientation applied.
    public var orientedSize: PixelSize { orientation.orientedSize(pixelSize) }

    /// The orientation to draw with: the file's, or `.up` when `exif-orientation` is off.
    public func displayOrientation(applying: Bool) -> ImageOrientation { applying ? orientation : .up }

    /// The size the view lays the photo out at (`ViewTransform.imageSize`, the stats bar, a saved view): the oriented
    /// size, or the stored one when `exif-orientation` is off.
    public func displaySize(applying: Bool) -> PixelSize {
        displayOrientation(applying: applying).orientedSize(pixelSize)
    }

    /// The orientation the renderer draws a pyramid of this photo with (review focus 1). Decoded levels and previews
    /// are stored as in the file and get `displayOrientation`. A seeded pyramid (`seeded`: the stretched strip
    /// thumbnail, `ImageCache.seed`) is laid out oriented already, since thumbnails are made turned: it gets `.up`, or
    /// the turn back to the stored layout when `exif-orientation` is off. Either way the drawn picture has
    /// `displaySize`.
    public func drawOrientation(applying: Bool, seeded: Bool) -> ImageOrientation {
        guard seeded else { return displayOrientation(applying: applying) }
        return applying ? .up : orientation.inverse
    }

    /// The header as the thumbnail catalog keeps it: the colour space by name only (the orientation is kept).
    public var catalogued: ImageInfo {
        ImageInfo(pixelSize: pixelSize, typeIdentifier: typeIdentifier, isProgressive: isProgressive, fileSize: fileSize,
                  colorSpaceName: colorSpaceName, orientation: orientation)
    }
}
