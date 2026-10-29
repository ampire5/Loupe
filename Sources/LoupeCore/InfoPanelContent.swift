import Foundation
import HomeScreenModel
// The panel's model (`InfoRow`, `InfoSection`, `PanelPlacement`, `PanelSize`) is InfoPanelKit's, for every target that
// imports LoupeCore.
@_exported import InfoPanelModel

/// What the window knows about the file before (and without) the metadata read.
public struct InfoFileFacts: Equatable, Sendable {
    public var name: String
    public var folder: String
    public var fileSize: Int?
    /// The header facts; nil while the photo is still loading.
    public var info: ImageInfo?
    /// `exif-orientation`: whether the dimensions are oriented (as the stats bar's) or as stored.
    public var applyingOrientation: Bool
    /// One short line when the photo could not be read.
    public var error: String?

    public init(name: String, folder: String, fileSize: Int?, info: ImageInfo?, applyingOrientation: Bool, error: String?) {
        self.name = name
        self.folder = folder
        self.fileSize = fileSize
        self.info = info
        self.applyingOrientation = applyingOrientation
        self.error = error
    }
}

/// The view state the Display section reports.
public struct InfoDisplayFacts: Equatable, Sendable {
    /// `StatsLine.modeText` of the transform.
    public var mode: String
    /// `StatsLine.filterName`; nil without a picture.
    public var filter: String?
    /// `StatsLine.colour`; nil without a photo. The row is labelled already, so its `Colour: ` prefix is dropped.
    public var colour: String?

    public init(mode: String, filter: String?, colour: String?) {
        self.mode = mode
        self.filter = filter
        self.colour = colour
    }
}

/// The info panel's text as a pure function (M4a spec §3.2), so what the panel says is tested without AppKit.
public enum InfoPanelContent {
    /// The sections in panel order. A row with no value and a section with no rows are left out. While
    /// `metadataPending` (the read is slow, spec §3.4) Capture is the single row `Capture: Reading…` and the
    /// metadata's dates and error are not used yet.
    public static func sections(file: InfoFileFacts?, metadata: PhotoMetadata?, metadataPending: Bool,
                                display: InfoDisplayFacts?, diagnostics: [InfoRow]) -> [InfoSection] {
        let known = metadataPending ? nil : metadata
        var result: [InfoSection] = []
        func add(_ title: String, _ rows: [InfoRow?]) {
            let rows = rows.compactMap { $0 }
            if !rows.isEmpty { result.append(InfoSection(title: title, rows: rows)) }
        }
        add("File", fileRows(file, known))
        if metadataPending {
            add("Capture", [InfoRow(label: "Capture", value: "Reading…")])
        } else if let known {
            add("Capture", captureRows(known))
        }
        if let display {
            add("Display", [row("Zoom", display.mode), row("Filter", display.filter), row("Colour", display.colour.map(colourValue))])
        }
        add("Diagnostics", diagnostics.filter { !$0.value.isEmpty })
        return result
    }

    /// `6 (rotated 90° CW)`: the EXIF number and a short word.
    public static func orientationText(_ orientation: ImageOrientation) -> String {
        let word = switch orientation {
        case .up: "normal"
        case .upMirrored: "mirrored"
        case .down: "rotated 180°"
        case .downMirrored: "flipped vertically"
        case .leftMirrored: "transposed"
        case .right: "rotated 90° CW"
        case .rightMirrored: "anti-transposed"
        case .left: "rotated 90° CCW"
        }
        return "\(orientation.rawValue) (\(word))"
    }

    /// `Colour: auto · Δ 4.1` → `auto · Δ 4.1`: the stats line's colour text without the label the row has already.
    public static func colourValue(_ text: String) -> String {
        let prefix = "Colour: "
        return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    // MARK: rows

    private static func row(_ label: String, _ value: String?) -> InfoRow? {
        guard let value, !value.isEmpty else { return nil }
        return InfoRow(label: label, value: value)
    }

    private static func fileRows(_ file: InfoFileFacts?, _ metadata: PhotoMetadata?) -> [InfoRow?] {
        guard let file else { return [row("Modified", metadata?.modified.map(dateText)),
                                      row("Created", metadata?.created.map(dateText)),
                                      row("Error", metadata?.error)] }
        let info = file.info
        let size = info.map { info in
            let shown = info.displaySize(applying: file.applyingOrientation)
            return "\(shown.width) × \(shown.height)"
        }
        let format = info.map { StatsLine.formatName($0.typeIdentifier) + ($0.isProgressive ? " progressive" : "") }
        let orientation = info.flatMap { $0.orientation == .up ? nil : orientationText($0.orientation) }
        return [
            row("Name", file.name),
            row("Folder", file.folder),
            row("Size", file.fileSize.map(sizeText)),
            row("Modified", metadata?.modified.map(dateText)),
            row("Created", metadata?.created.map(dateText)),
            row("Format", format),
            row("Dimensions", size),
            row("Bit depth", metadata?.bitDepth.map { "\($0)-bit" }),
            row("Profile", info?.colorSpaceName),
            row("Alpha", metadata?.hasAlpha.map { $0 ? "yes" : "no" }),
            row("Orientation", orientation),
            row("Error", file.error ?? metadata?.error),
        ]
    }

    /// A camera's photo shows every capture field, `—` where the file has none (style guide E, «Отсутствующие
    /// значения»); a picture without a camera (a render, a screenshot) shows only what it has.
    private static func captureRows(_ m: PhotoMetadata) -> [InfoRow?] {
        let camera = m.camera != nil
        func field(_ label: String, _ value: String?) -> InfoRow? { row(label, value ?? (camera ? "\u{2014}" : nil)) }
        return [
            field("Camera", m.camera), field("Lens", m.lens), field("Focal length", m.focalLength),
            field("Aperture", m.aperture), field("Exposure", m.exposure), field("ISO", m.iso),
            row("Compensation", m.compensation), field("Captured", m.captured), field("GPS", m.gps),
            row("Software", m.software), row("Description", m.description), row("Generation", m.generation),
            row("ComfyUI", m.comfyWorkflowBytes.map { "workflow, " + ($0 < 1024 ? "<1" : "\(Int((Double($0) / 1024).rounded()))") + " KB" }),
        ]
    }

    /// `24.6 MB (24 612 908 B)`: the style guide's size and, from a kilobyte, the bytes grouped by thin spaces.
    static func sizeText(_ bytes: Int) -> String {
        let short = FileFactsText.size(Int64(bytes))
        guard bytes >= 1000 else { return short }
        var digits = String(bytes), grouped = ""
        if digits.count >= 5 {
            while digits.count > 3 {
                grouped = "\u{202F}" + digits.suffix(3) + grouped
                digits.removeLast(3)
            }
        }
        return short + " (" + digits + grouped + "\u{00A0}B)"
    }

    /// `2024-05-01 12:34`, local time. One formatter for every call: making one costs more than the rest of the panel's
    /// text, and the diagnostics timer rebuilds the text twice a second.
    public static func dateText(_ date: Date) -> String {
        dateFormat.format(date)
    }

    private static let dateFormat = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        locale: Locale(identifier: "en_US_POSIX"), timeZone: .current, calendar: Calendar(identifier: .gregorian))
}
