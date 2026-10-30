import Foundation
import HomeScreenModel

/// What the viewer says about the photo on screen, as one value for the toolbar's status and the stats bar: the name
/// (or the message that wins over it), the facts, each of one kind so a view gives it a slot of its own, the folder, and
/// how far along the folder the photo is. Pure, so it is tested without AppKit or a session.
public struct ImageStatus: Equatable, Sendable {
    /// Structured controls for the toolbar; the stats line remains a human-readable description.
    public struct ZoomDetails: Equatable, Sendable {
        public var mode: SmartZoomMode
        public var profile: String
        public var group: String
        public var scale: Double
        public var keepingZoom: Bool
        public init(mode: SmartZoomMode, profile: String, group: String, scale: Double, keepingZoom: Bool) {
            self.mode = mode; self.profile = profile; self.group = group
            self.scale = scale; self.keepingZoom = keepingZoom
        }
    }
    public var zoomDetails: ZoomDetails?
    /// Zero-based position and complete known count, independent of the formatted spread position.
    public var index: Int?
    public var count: Int?
    /// The facts of a photo, in the order they are shown.
    public enum Kind: CaseIterable, Sendable {
        case position, size, megapixels, exposure, fileSize, format, zoom

        public var tip: String {
            switch self {
            case .position: "Position in folder"
            case .size: "Image dimensions"
            case .megapixels: "Megapixels"
            case .exposure: "Aperture, shutter speed, ISO and focal length"
            case .fileSize: "File size"
            case .format: "File format"
            case .zoom: "Zoom mode"
            }
        }
    }

    /// What a value means, which a view paints as a camera's screen does: white for what the photo is, grey for the quiet
    /// facts, yellow for what the user changed, green, amber and red for how well it goes.
    public enum Tone: Sendable {
        case normal, quiet, adjusted, good, caution, warning
    }

    public struct Fact: Equatable, Sendable {
        public let kind: Kind
        public let value: String
        public let tone: Tone
        /// The exposure's values one by one, each with its glyph and colour where it is drawn; empty for the rest.
        public let parts: [FileFactsText.ExposureValue]

        public init(_ kind: Kind, _ value: String, tone: Tone = .normal, parts: [FileFactsText.ExposureValue] = []) {
            self.kind = kind
            self.value = value
            self.tone = tone
            self.parts = parts
        }
    }

    /// The name of the photo the viewer is on (a pair's both names), also while it loads: what is on screen is the previous
    /// photo's until it is in, and its facts stay, grey, beside the new place, so a step changes text and nothing
    /// appears or goes. The failure of the photo takes the title's place, in `warning`. Empty with nothing to say.
    public var title = ""
    public var titleTone = Tone.normal
    /// A line about the folder (`Loading folder…`, why a folder step failed), in the place of the folder's name: the
    /// news is about the folder, and nothing else moves for it.
    public var note: String?
    public var noteTone = Tone.quiet
    public var facts: [Fact] = []
    /// The facts and the decode time are the photo's before: the new one is still loading. A view greys them only when
    /// the load is felt, so a photo that comes at once does not flash its facts grey and white.
    public var stale = false
    /// The kinds still being read for the photo on screen (its EXIF comes a moment after its pixels): a view keeps the
    /// value it shows for them until it is in, so a slot does not empty and fill again.
    public var pending: Set<Kind> = []
    /// How long the photo on screen took to decode (the photo's before while `stale`), when known.
    public var decodeMilliseconds: Int?

    /// How the decode time is painted: green while the photo comes at once, amber when it is felt, red when it is waited
    /// for. A first guess at the limits (a photo that is shown from its preview first is not waited for the full decode).
    public static func decodeTone(milliseconds: Int) -> Tone {
        milliseconds <= 250 ? .good : milliseconds <= 1000 ? .caution : .warning
    }

    /// The folder of the photo, and the photo whose facts these are (its modification date is read from it).
    public var folder: URL?
    public var photo: URL?
    /// 0...1: the folder position `(index + 1) / count` the stats bar fills to; 0 while the folder is not counted.
    public var progress = 0.0
    /// Changes with a move to another photo or folder, not with a load, a zoom or a pan.
    public var navigationKey = ""

    public init() {}

    /// `value` of the fact of `kind`, nil when the status has none.
    public func value(_ kind: Kind) -> String? { facts.first { $0.kind == kind }?.value }

    /// The facts of a loaded photo. The size is as shown: oriented (M3b spec §2.1), stored when `applyingOrientation`
    /// is off (`exif-orientation=no`). `counted` false: the folder is still being listed, so the count is `…` rather
    /// than the interim playlist's. `companion` (the second page's index, spread) makes the position a range.
    /// `photo`: the photo's EXIF (its thumbnail's facts, else its header), for the megapixels and the exposure (board
    /// «Эскизы файлов» 4); nil leaves them out. `carry`: the folder's `keep-zoom-as`, which names a free zoom; `framing`:
    /// what framing while browsing looks at, which names it instead; `detectorMode`: the custom detector's mode while it
    /// is on, which goes before the zoom ("play · Fit 23 %").
    public static func facts(index: Int, companion: Int? = nil, count: Int, counted: Bool = true, info: ImageInfo,
                             applyingOrientation: Bool = true, transform: ViewTransform, photo: FileFacts? = nil,
                             carry: ZoomCarry = .share, subject: Bool = false,
                             framing: (name: String, size: Double)? = nil, detectorMode: String? = nil) -> [Fact] {
        let size = info.displaySize(applying: applyingOrientation)
        let pixels = FileFacts(width: size.width, height: size.height)
        return [
            Fact(.position, StatsLine.position(index: index, companion: companion, count: count, counted: counted)),
            Fact(.size, "\(size.width)×\(size.height)"),
            FileFactsText.megapixels(pixels).map { Fact(.megapixels, $0, tone: .quiet) },
            photo.flatMap(exposureFact),
            Fact(.fileSize, fileSizeText(info.fileSize), tone: .quiet),
            Fact(.format, StatsLine.formatName(info.typeIdentifier)),
            // Fit is what the viewer does by itself; any other zoom is the user's.
            Fact(.zoom, (detectorMode.map { "\($0) · " } ?? "")
                    + StatsLine.modeText(transform, carry: carry, subject: subject, framing: framing),
                 tone: transform.mode == .fit ? .normal : .adjusted),
        ].compactMap { $0 }
    }

    /// `1/250  f/2.8  ISO 400  35 mm  −0.3 EV`: the style guide's exposure line (F5), as a camera's screen writes it.
    public static func exposureText(_ f: FileFacts) -> String? {
        let parts = FileFactsText.exposureParts(f)
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// The exposure as a fact: its line and its values.
    public static func exposureFact(_ f: FileFacts) -> Fact? {
        exposureText(f).map { Fact(.exposure, $0, parts: FileFactsText.exposureValues(f)) }
    }

    /// The style guide's decimal size (E): `52.3 MB`, `148 MB`, `1.3 GB`, `850 B`. Not locale-dependent, so a slot is
    /// measured once.
    public static func fileSizeText(_ bytes: Int) -> String { FileFactsText.size(Int64(bytes)) }
}
