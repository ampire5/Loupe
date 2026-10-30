import Foundation
import CoreGraphics
import HomeScreenModel

/// The selected file's read, kept separately from the viewer's current image and diagnostics.
public struct BrowserInspectorResult: @unchecked Sendable {
    public var metadata: PhotoMetadata
    public var fileSize: Int?
    public var thumbnail: CGImage?

    public init(metadata: PhotoMetadata, fileSize: Int? = nil, thumbnail: CGImage? = nil) {
        self.metadata = metadata
        self.fileSize = fileSize ?? metadata.header?.fileSize
        self.thumbnail = thumbnail
    }

    /// Call off the main actor. No image decode, recursive folder work or source downloads.
    public static func read(_ entry: BrowserEntry) -> Self {
        guard entry.isFile, entry.url.isFileURL else {
            return Self(metadata: PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil))
        }
        let metadata = PhotoMetadata.read(entry.url)
        let size: Int?
        if let header = metadata.header { size = header.fileSize }
        else if ArchivePath.split(entry.url) != nil { size = (try? ArchiveReader.shared.stamp(entry.url))?.size }
        else { size = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
        return Self(metadata: metadata, fileSize: size)
    }
}

/// Catalog data is a progressive seed, not a completed source-metadata read.
public struct BrowserInspectorSeed: @unchecked Sendable {
    public var facts: FileFacts?
    public var thumbnail: CGImage?
    public var metadata: PhotoMetadata?
    public init(facts: FileFacts? = nil, thumbnail: CGImage? = nil, metadata: PhotoMetadata? = nil) {
        self.facts = facts; self.thumbnail = thumbnail; self.metadata = metadata
    }

    /// Fill unknown fields without replacing newer values already delivered by the selected card.
    public static func supplement(_ preferred: FileFacts?, with fallback: FileFacts?) -> FileFacts? {
        guard var value = preferred else { return fallback }
        guard let fallback else { return value }
        value.width = value.width ?? fallback.width
        value.height = value.height ?? fallback.height
        value.duration = value.duration ?? fallback.duration
        value.codec = value.codec ?? fallback.codec
        value.fps = value.fps ?? fallback.fps
        value.bitrate = value.bitrate ?? fallback.bitrate
        value.transfer = value.transfer ?? fallback.transfer
        value.camera = value.camera ?? fallback.camera
        value.lens = value.lens ?? fallback.lens
        value.exposure = value.exposure ?? fallback.exposure
        value.aperture = value.aperture ?? fallback.aperture
        value.iso = value.iso ?? fallback.iso
        value.focalLength = value.focalLength ?? fallback.focalLength
        value.exposureBias = value.exposureBias ?? fallback.exposureBias
        value.taken = value.taken ?? fallback.taken
        value.colorSpace = value.colorSpace ?? fallback.colorSpace
        value.orientation = value.orientation ?? fallback.orientation
        value.progressive = value.progressive ?? fallback.progressive
        value.typeIdentifier = value.typeIdentifier ?? fallback.typeIdentifier
        return value
    }
}

/// Readable groups, independent of AppKit. Row order and section presence do not depend on read timing.
public struct BrowserInspectorContent: Equatable, Sendable {
    public var name: String
    public var subtitle: String
    public var summary: [InfoRow]
    public var sections: [InfoSection]
    public var message: String?
    public var pendingSections: Set<String> = []

    public static func make(entry: BrowserEntry?, result: BrowserInspectorResult?, pending: Bool) -> Self {
        guard let entry else {
            return Self(name: "", subtitle: "", summary: [], sections: [], message: "Select a file to see its information.")
        }
        let metadata = result?.metadata, header = metadata?.header, facts = entry.facts
        let waiting = pending && entry.isFile && entry.url.isFileURL && result == nil
        let size = result?.fileSize ?? entry.size.flatMap(Int.init(exactly:))
        let file = InfoFileFacts(name: entry.name, folder: entry.url.deletingLastPathComponent().path,
                                 fileSize: size, info: header, applyingOrientation: true, error: metadata?.error)
        let original = InfoPanelContent.sections(file: file, metadata: metadata, metadataPending: false,
                                                 display: nil, diagnostics: [])
        let fileRows = original.first { $0.title == "File" }?.rows ?? []
        var cachedFile: [String: String] = [:]
        if let w = facts?.width, let h = facts?.height { cachedFile["Dimensions"] = "\(w) × \(h)" }
        cachedFile["Profile"] = facts?.colorSpace
        if let date = entry.date { cachedFile["Modified"] = InfoPanelContent.dateText(date) }
        let knownFormat = header.map { StatsLine.formatName($0.typeIdentifier) + ($0.isProgressive ? " progressive" : "") }
            ?? facts?.typeIdentifier.map { StatsLine.formatName($0) + (facts?.progressive == true ? " progressive" : "") }
        cachedFile["Format"] = knownFormat ?? (entry.isFile ? entry.url.pathExtension.uppercased() : "Folder")
        if let raw = facts?.orientation, let orientation = ImageOrientation(rawValue: raw) {
            cachedFile["Orientation"] = InfoPanelContent.orientationText(orientation)
        }
        func values(_ rows: [InfoRow], fallback: [String: String] = [:]) -> [String: String] {
            var value = fallback
            for row in rows where !row.value.isEmpty && row.value != "—" { value[row.label] = row.value }
            return value
        }
        let known = values(fileRows, fallback: cachedFile)
        let missing = waiting ? "Requesting…" : "—"
        let summary = ["Dimensions", "Size", "Modified", "Profile", "Bit depth"].compactMap { key -> InfoRow? in
            guard entry.isFile || known[key] != nil else { return nil }
            return InfoRow(label: key, value: known[key] ?? missing)
        }
        var cachedCapture: [String: String] = [:]
        cachedCapture["Camera"] = facts?.camera; cachedCapture["Lens"] = facts?.lens
        if let f = facts {
            for value in FileFactsText.exposureValues(f) {
                let label: String
                switch value.kind {
                case .shutter: label = "Exposure"
                case .aperture: label = "Aperture"
                case .iso: label = "ISO"
                case .focalLength: label = "Focal length"
                case .bias: label = "Compensation"
                }
                // Use the same ISO spelling as the full metadata reader.
                cachedCapture[label] = value.text.replacingOccurrences(of: "\u{00A0}", with: " ")
            }
        }
        if let taken = facts?.taken { cachedCapture["Captured"] = InfoPanelContent.dateText(taken) }
        let captureRows = original.first { $0.title == "Capture" }?.rows ?? []
        let capture = values(captureRows, fallback: cachedCapture)
        let captureOrder = ["Camera", "Lens", "Focal length", "Aperture", "Exposure", "ISO", "Compensation", "Captured", "GPS", "Software", "Description"]
        let camera = capture["Camera"] != nil
        let mainCapture: Set<String> = ["Camera", "Lens", "Focal length", "Aperture", "Exposure", "ISO", "Captured", "GPS"]
        let shownCapture = captureOrder.compactMap { key -> InfoRow? in
            if let value = capture[key] { return InfoRow(label: key, value: value) }
            return camera && mainCapture.contains(key) ? InfoRow(label: key, value: missing) : nil
        }
        let generation = captureRows.filter { ["Generation", "ComfyUI"].contains($0.label) }
        let location = [InfoRow(label: "Name", value: entry.name),
                        InfoRow(label: "Path", value: entry.url.isFileURL ? entry.url.path : entry.url.absoluteString),
                        InfoRow(label: "Created", value: known["Created"] ?? missing),
                        InfoRow(label: "Last Viewed", value: entry.lastViewedAt.map(InfoPanelContent.dateText) ?? "—")]
        let technical = ["Format", "Orientation", "Alpha"].map { InfoRow(label: $0, value: known[$0] ?? missing) }
        var sections: [InfoSection] = []
        for (title, rows) in [("Capture", shownCapture), ("Generation", generation),
                              ("File and Location", location), ("Technical Details", technical)] {
            if entry.isFile || !rows.isEmpty { sections.append(InfoSection(title: title, rows: rows)) }
        }
        let format = knownFormat ?? cachedFile["Format"] ?? ""
        let subtitle = [format, size.map { FileFactsText.size(Int64($0)) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let message = metadata?.error ?? (entry.isFile && !entry.url.isFileURL ? "Extended metadata is unavailable for this source." : nil)
        return Self(name: entry.name, subtitle: subtitle, summary: summary, sections: sections, message: message,
                    pendingSections: waiting ? Set(sections.map(\.title)) : [])
    }
}
