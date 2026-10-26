import Foundation

/// What the viewer says about the photo on screen, as one value for the toolbar's status and the stats bar: the name
/// (or the message that wins over it), the facts, each of one kind so a view gives it a slot of its own, the folder, and
/// how far along the folder the photo is. Pure, so it is tested without AppKit or a session.
public struct ImageStatus: Equatable, Sendable {
    /// The facts of a photo, in the order they are shown.
    public enum Kind: CaseIterable, Sendable {
        case position, size, fileSize, format, zoom

        public var tip: String {
            switch self {
            case .position: "Position in folder"
            case .size: "Image dimensions"
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

        public init(_ kind: Kind, _ value: String, tone: Tone = .normal) {
            self.kind = kind
            self.value = value
            self.tone = tone
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
    /// How long the photo took to decode, when known.
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
    public static func facts(index: Int, companion: Int? = nil, count: Int, counted: Bool = true, info: ImageInfo,
                             applyingOrientation: Bool = true, transform: ViewTransform) -> [Fact] {
        let size = info.displaySize(applying: applyingOrientation)
        return [
            Fact(.position, StatsLine.position(index: index, companion: companion, count: count, counted: counted)),
            Fact(.size, "\(size.width)×\(size.height)"),
            Fact(.fileSize, fileSizeText(info.fileSize), tone: .quiet),
            Fact(.format, StatsLine.formatName(info.typeIdentifier)),
            // Fit is what the viewer does by itself; any other zoom is the user's.
            Fact(.zoom, StatsLine.modeText(transform), tone: transform.mode == .fit ? .normal : .adjusted),
        ]
    }

    /// Decimal units, as Finder counts: `52.3 MB`, `1.3 GB`, `850 KB`. Not locale-dependent, so a slot is measured once.
    public static func fileSizeText(_ bytes: Int) -> String {
        switch Double(bytes) {
        case 1e9...: String(format: "%.1f GB", Double(bytes) / 1e9)
        case 1e6...: String(format: "%.1f MB", Double(bytes) / 1e6)
        case 1e3...: String(format: "%.0f KB", Double(bytes) / 1e3)
        default: "\(bytes) bytes"
        }
    }
}
