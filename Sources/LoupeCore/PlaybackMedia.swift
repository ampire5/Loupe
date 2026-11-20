import AVFoundation
import CoreGraphics
import Foundation
import HomeScreenModel
import ImageIO
import UniformTypeIdentifiers

/// Files the installed playback extension can open directly from a read-only descriptor.
public enum PlaybackMedia: Equatable, Sendable {
    case video
    case animation

    public static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "mts", "m2ts", "ts", "mpg", "mpeg", "wmv", "flv", "3gp",
    ]

    /// Classification by name is cheap enough for folder listings and the photo-cache planner.
    /// An animation candidate still needs a frame-count probe because GIF and WebP also hold photos.
    public static func candidate(_ url: URL) -> Self? {
        let ext = url.pathExtension.lowercased()
        let kind: Self
        if videoExtensions.contains(ext) {
            kind = .video
        } else if ext == "gif" || ext == "webp" {
            kind = .animation
        } else {
            return nil
        }
        return url.isFileURL && ArchivePath.split(url) == nil ? kind : nil
    }

    static func isFilesystemGIF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gif" && candidate(url) == .animation
    }

    /// The renderer and the catalog only need the still picture. The provider reads the original descriptor.
    static func readPosterBytes(_ url: URL, reader: any FileReading, priority: ReadPriority) async throws -> FileBytes {
        guard isFilesystemGIF(url) else { return try await reader.read(url, priority: priority) }
        let bytes = try await reader.readPrefix(url, priority: priority) { data in
            GIFPoster.hasSignature(data)
                && (GIFPoster.scan(data).firstImageEnd != nil || data.count >= GIFPoster.scanLimit)
        }
        guard GIFPoster.hasSignature(bytes.data) else { return bytes }
        guard let end = GIFPoster.scan(bytes.data).firstImageEnd else { throw DecodeError.unreadable }
        return FileBytes(data: GIFPoster.still(bytes.data, through: end), stamp: bytes.stamp)
    }

    /// Blocking ImageIO metadata read and first-frame thumbnail. Run off the main thread.
    public static func animationPoster(_ url: URL, maximumSide: Int) -> (Bool, CGImage?) {
        guard candidate(url) == .animation else { return (false, nil) }
        let source: CGImageSource?
        if isFilesystemGIF(url) {
            guard let poster = GIFPoster.read(url, detectAnimation: true), poster.animated else { return (false, nil) }
            source = poster.source
        } else {
            source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            guard let source, CGImageSourceGetCount(source) > 1 else { return (false, nil) }
        }
        guard let source else { return (true, nil) }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSide,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return (true, CGImageSourceCreateThumbnailAtIndex(source, 0, options))
    }

    /// Blocks its caller. Thumbnail and selected-poster work use bounded pools, never the UI thread.
    public static func videoPoster(_ url: URL, maximumSide: Int) throws -> CGImage {
        let generator = posterGenerator(for: AVURLAsset(url: url), maximumSide: maximumSide)
        return try generator.copyCGImage(at: .zero, actualTime: nil)
    }

    public static func frameScrubLink(for url: URL, presentedTime: Double) -> URL? {
        guard candidate(url) == .video else { return nil }
        var link = URLComponents()
        link.scheme = "framescrub"
        link.host = "open"
        link.queryItems = [
            .init(name: "path", value: url.path),
            .init(name: "t", value: String(presentedTime.isFinite ? max(0, presentedTime) : 0)),
            .init(name: "paused", value: "1"),
        ]
        return link.url
    }

    /// The catalog keeps the source's display dimensions and stream facts beside the resized poster.
    static func videoThumbnail(_ url: URL, maximumSide: Int, fileSize: Int) async throws -> (Data, ImageInfo) {
        let asset = AVURLAsset(url: url)
        let (poster, _) = try await posterGenerator(for: asset, maximumSide: maximumSide).image(at: .zero)
        try Task.checkCancellation()
        let facts = await videoFacts(for: asset)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ThumbnailMakerError.cannotEncode }
        CGImageDestinationAddImage(encoder, poster, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw ThumbnailMakerError.cannotEncode }
        var info = ImageInfo(pixelSize: PixelSize(width: facts.width ?? poster.width, height: facts.height ?? poster.height),
                             typeIdentifier: UTType.movie.identifier, isProgressive: false, fileSize: fileSize,
                             colorSpaceName: nil)
        // Keep an empty record if the stream supplied no video metadata, so the poster can still be reused.
        info.facts = facts.isVideo ? facts : FileFacts()
        return (data as Data, info)
    }

    private static func posterGenerator(for asset: AVAsset, maximumSide: Int) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumSide, height: maximumSide)
        return generator
    }

    private static func videoFacts(for asset: AVAsset) async -> FileFacts {
        let duration = (try? await asset.load(.duration))?.seconds
        var facts = FileFacts(duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        guard !Task.isCancelled, let track = try? await asset.loadTracks(withMediaType: .video).first else { return facts }
        if let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let displayed = CGRect(origin: .zero, size: size).applying(transform).size
            facts.width = Int(exactly: displayed.width.rounded()).flatMap { $0 > 0 ? $0 : nil }
            facts.height = Int(exactly: displayed.height.rounded()).flatMap { $0 > 0 ? $0 : nil }
        }
        if let (rate, bitrate, formats) = try? await track.load(.nominalFrameRate, .estimatedDataRate, .formatDescriptions) {
            if rate.isFinite, rate > 0 { facts.fps = Double(rate) }
            facts.bitrate = Int(exactly: bitrate.rounded()).flatMap { $0 > 0 ? $0 : nil }
            if let format = formats.first {
                facts.codec = codecName(CMFormatDescriptionGetMediaSubType(format))
                let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String {
                    facts.transfer = .hdr10
                } else if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String {
                    facts.transfer = .hlg
                }
            }
        }
        return facts
    }

    private static func codecName(_ codec: FourCharCode) -> String? {
        switch codec {
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: "HEVC"
        case kCMVideoCodecType_AV1: "AV1"
        case kCMVideoCodecType_VP9: "VP9"
        case kCMVideoCodecType_MPEG4Video: "MPEG-4"
        case kCMVideoCodecType_MPEG2Video: "MPEG-2"
        case kCMVideoCodecType_JPEG, kCMVideoCodecType_JPEG_OpenDML: "MJPEG"
        case kCMVideoCodecType_AppleProRes4444XQ, kCMVideoCodecType_AppleProRes4444,
             kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
             kCMVideoCodecType_AppleProResRAW, kCMVideoCodecType_AppleProResRAWHQ: "ProRes"
        default: nil
        }
    }
}
