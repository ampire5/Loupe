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

/// Readable groups, independent of the AppKit layout. Only facts about the selected item belong here.
public struct BrowserInspectorContent: Equatable, Sendable {
    public var name: String
    public var subtitle: String
    public var summary: [InfoRow]
    public var sections: [InfoSection]
    public var message: String?

    public static func make(entry: BrowserEntry?, result: BrowserInspectorResult?, pending: Bool) -> Self {
        guard let entry else {
            return Self(name: "", subtitle: "", summary: [], sections: [], message: "Select a file to see its information.")
        }
        let metadata = result?.metadata
        let header = metadata?.header
        let size = result?.fileSize ?? entry.size.flatMap(Int.init(exactly:))
        let file = InfoFileFacts(name: entry.name, folder: entry.url.deletingLastPathComponent().path,
                                 fileSize: size, info: header, applyingOrientation: true, error: metadata?.error)
        let original = InfoPanelContent.sections(file: file, metadata: metadata, metadataPending: false,
                                                 display: nil, diagnostics: [])
        let fileRows = original.first { $0.title == "File" }?.rows ?? []
        let primary: Set<String> = ["Dimensions", "Size", "Modified", "Profile", "Bit depth"]
        var summary = fileRows.filter { primary.contains($0.label) }
        if header == nil, let w = entry.facts?.width, let h = entry.facts?.height {
            summary.insert(InfoRow(label: "Dimensions", value: "\(w) × \(h)"), at: 0)
        }
        if metadata?.modified == nil, let date = entry.date {
            summary.append(InfoRow(label: "Modified", value: InfoPanelContent.dateText(date)))
        }
        let captureRows = original.first { $0.title == "Capture" }?.rows ?? []
        let generationLabels: Set<String> = ["Generation", "ComfyUI"]
        let capture = captureRows.filter { !generationLabels.contains($0.label) }
        let generation = captureRows.filter { generationLabels.contains($0.label) }
        let locationRows = [InfoRow(label: "Name", value: entry.name), InfoRow(label: "Path", value: entry.url.isFileURL ? entry.url.path : entry.url.absoluteString)]
            + fileRows.filter { $0.label == "Created" }
        let technical = fileRows.filter { ["Format", "Alpha", "Orientation"].contains($0.label) }
        var sections: [InfoSection] = []
        func add(_ title: String, _ rows: [InfoRow]) { if !rows.isEmpty { sections.append(InfoSection(title: title, rows: rows)) } }
        add("Capture", capture)
        add("Generation", generation)
        add("File and Location", locationRows)
        add("Technical Details", technical)
        let format = header.map { StatsLine.formatName($0.typeIdentifier) }
            ?? (entry.isFile ? entry.url.pathExtension.uppercased() : entry.kind == .archive ? "ZIP archive" : "Folder")
        let subtitle = [format, size.map { FileFactsText.size(Int64($0)) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let message: String?
        if let error = metadata?.error { message = error }
        else if entry.isFile && !entry.url.isFileURL { message = "Extended metadata is unavailable for this source." }
        else { message = pending ? "Reading metadata…" : nil }
        return Self(name: entry.name, subtitle: subtitle, summary: summary, sections: sections, message: message)
    }
}
