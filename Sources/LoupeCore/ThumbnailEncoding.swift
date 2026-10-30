import Foundation
import ImageIO

/// Same thumbnail policy as FrameScrub. ImageIO JPEG q80 remains the measured fast default; optional encoders
/// trade CPU for disk space without adding a runtime library. Settings take effect on the next launch.
public struct ThumbnailEncoding: Equatable, Sendable {
    public enum Format: String, CaseIterable, Sendable {
        case jpeg, heic, avif
        public var typeIdentifier: String {
            switch self { case .jpeg: "public.jpeg"; case .heic: "public.heic"; case .avif: "public.avif" }
        }
    }
    public let format: Format
    public let quality: Double
    private static let availableTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? ["public.jpeg"]
    public static let standard = ThumbnailEncoding(format: .jpeg, quality: 0.8)
    /// Lazy process snapshot: encoding and the disk namespace always use the same settings.
    public static let current = configured()

    public init(format: Format, quality: Double) {
        self.init(format: format, quality: quality, availableTypes: Self.availableTypes)
    }
    init(format: Format, quality: Double, availableTypes: [String]) {
        self.format = availableTypes.contains(format.typeIdentifier) ? format : .jpeg
        self.quality = quality.isFinite ? (min(1, max(0.1, quality)) * 100).rounded() / 100 : 0.8
    }
    public static func configured(_ defaults: UserDefaults = .standard) -> Self {
        let format = defaults.string(forKey: "thumbnail-format").flatMap(Format.init(rawValue:)) ?? .jpeg
        let percent = defaults.object(forKey: "thumbnail-quality") == nil ? 80 : defaults.double(forKey: "thumbnail-quality")
        return Self(format: format, quality: percent / 100)
    }
    public var cacheKey: String { "\(format.rawValue)-q\(Int((quality * 100).rounded()))" }

    func encode(_ image: CGImage) throws -> Data {
        func attempt(_ format: Format) -> Data? {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, format.typeIdentifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }
        if let data = attempt(format) { return data }
        if format != .jpeg, let data = attempt(.jpeg) { return data }
        throw ThumbnailMakerError.cannotEncode
    }
}
