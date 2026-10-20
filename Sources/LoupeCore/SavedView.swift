import CoreGraphics
import Foundation

/// How the folder's last photo was being looked at when the user left it: zoom mode, relative centre and the
/// photo's pixel size as laid out (oriented, M3b spec §2.1), stored with the folder's position (`FolderPositions`,
/// `folder_positions.view`) so the photo reopens at that zoom and spot. A fit-family mode is kept as the mode itself
/// (`fit-width`, not its scale), so it still fits a window of another size; `actual` and `free` keep their number.
public struct SavedView: Equatable, Sendable {
    public var mode: ZoomMode
    /// The transform's stored (desired) centre, 0…1 of the image.
    public var center: CGPoint
    /// Image pixels, the transform's (oriented) image size: the view is restored only onto a photo laid out at this
    /// size (`applies(to:)`). A view saved before M3b for a turned photo has its stored size, and does not apply.
    public var imageSize: CGSize

    public init(mode: ZoomMode, center: CGPoint, imageSize: CGSize) {
        self.mode = mode
        self.center = center
        self.imageSize = imageSize
    }

    /// The view of `t`.
    public init(_ t: ViewTransform) {
        self.init(mode: t.mode, center: t.center, imageSize: t.imageSize)
    }

    /// `<mode> <x> <y> <width>x<height>`, e.g. `actual:2.0 0.31 0.62 6000x4000`; the mode is `fit`, `fit-width`,
    /// `fit-height`, `fill`, `actual:<scale>` or `free:<times fit>`. Numbers in their shortest exact spelling.
    public var text: String {
        let modeText: String
        switch mode {
        case .fit: modeText = "fit"
        case .fitWidth: modeText = "fit-width"
        case .fitHeight: modeText = "fit-height"
        case .fill: modeText = "fill"
        case .actual(let k): modeText = "actual:\(k)"
        case .free(let r): modeText = "free:\(r)"
        }
        return "\(modeText) \(Double(center.x)) \(Double(center.y)) \(Int(imageSize.width))x\(Int(imageSize.height))"
    }

    /// Reads `text`; nil for anything else (a non-finite or non-positive number, a missing or extra field).
    public init?(text: String) {
        let fields = text.split(separator: " ")
        guard fields.count == 4, let mode = Self.mode(fields[0]),
              let x = Double(fields[1]), let y = Double(fields[2]), x.isFinite, y.isFinite else { return nil }
        let sides = fields[3].split(separator: "x", omittingEmptySubsequences: false)
        guard sides.count == 2, let w = Int(sides[0]), let h = Int(sides[1]), w > 0, h > 0 else { return nil }
        self.init(mode: mode, center: CGPoint(x: x, y: y), imageSize: CGSize(width: w, height: h))
    }

    private static func mode(_ field: Substring) -> ZoomMode? {
        switch field {
        case "fit": return .fit
        case "fit-width": return .fitWidth
        case "fit-height": return .fitHeight
        case "fill": return .fill
        default:
            let parts = field.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let v = Double(parts[1]), v.isFinite, v > 0 else { return nil }
            switch parts[0] {
            case "actual": return .actual(v)
            case "free": return .free(v)
            default: return nil
            }
        }
    }

    /// Whether the view may be restored onto a photo of `size`: only the size it was saved for, so a file replaced
    /// by another photo under the same name opens in the normal view.
    public func applies(to size: CGSize) -> Bool { size == imageSize }
}

/// `folder-view-memory`: which photos open in the folder's saved view. `folder`: any photo that arrives fresh in a
/// folder (opened from Finder, a launch, a folder step); `photo`: only the folder's recorded file; `off`: none (the
/// view is still recorded, so turning it back on restores again).
public enum FolderViewMemory: Sendable {
    case folder, photo, off

    /// The key's value: `folder`, `photo` or `no`.
    public var text: String {
        switch self {
        case .folder: return "folder"
        case .photo: return "photo"
        case .off: return "no"
        }
    }

    /// Reads the key's value; `yes` is the recommended "on", `folder`. Nil for anything else.
    public init?(text: String) {
        switch text.lowercased() {
        case "folder", "yes", "true", "1": self = .folder
        case "photo": self = .photo
        case "no", "false", "0": self = .off
        default: return nil
        }
    }
}

/// The saved view waiting for a photo that arrived fresh (a folder step, opening a file that is not on screen): applied
/// once, at the photo's first show, when the user has not zoomed or panned since the arrival (the screen then still
/// showed the previous photo). For the folder's recorded file (`samePhoto`) the mode and centre, and only onto a
/// photo of the saved size; for another photo of the folder (`folderMode`, `folder-view-memory=folder`) the mode, and
/// the centre only when the photo has the saved size, else 0.5, 0.5. Otherwise the photo opens in the normal view.
/// Pure, so the viewer's decision is tested here.
public struct ViewRestore: Equatable, Sendable {
    /// Why the view applies, for the debug log.
    public enum Rule: Sendable {
        case samePhoto, folderMode, folderModeCentreDropped

        public var text: String {
            switch self {
            case .samePhoto: return "same photo"
            case .folderMode: return "folder mode"
            case .folderModeCentreDropped: return "folder mode, centre dropped for size"
            }
        }
    }

    public let file: URL
    public let view: SavedView
    /// The view was saved with `file` itself (not another photo of the folder).
    public let ofSamePhoto: Bool
    /// Mode and centre when the photo became current: a different one at its show is the user's zoom or pan.
    private let arrivalMode: ZoomMode
    private let arrivalCenter: CGPoint

    /// The restore waiting for `file`, or nil when there is no saved view, `memory` is off (`folder-view-memory=no`:
    /// the saved view is never applied; it is still recorded, so turning the key back on restores again), or it is
    /// `photo` and the view was saved with another file. `savedFile`: the file name the folder's view was saved with.
    public static func pending(file: URL, savedFile: String?, saved: SavedView?, arrival: ViewTransform,
                               memory: FolderViewMemory) -> ViewRestore? {
        guard let saved else { return nil }
        let same = savedFile == file.lastPathComponent
        switch memory {
        case .off: return nil
        case .photo where !same: return nil
        default: return ViewRestore(file: file, view: saved, ofSamePhoto: same, arrival: arrival)
        }
    }

    public init(file: URL, view: SavedView, ofSamePhoto: Bool = true, arrival: ViewTransform) {
        self.file = file
        self.view = view
        self.ofSamePhoto = ofSamePhoto
        arrivalMode = arrival.mode
        arrivalCenter = arrival.center
    }

    /// What the photo laid out at `imageSize` gets: the saved mode with the saved or the middle centre, and the rule;
    /// nil when the view does not apply (the saved file at another size).
    public func target(imageSize: CGSize) -> (mode: ZoomMode, center: CGPoint, rule: Rule)? {
        if view.applies(to: imageSize) {
            return (view.mode, view.center, ofSamePhoto ? .samePhoto : .folderMode)
        }
        return ofSamePhoto ? nil : (view.mode, CGPoint(x: 0.5, y: 0.5), .folderModeCentreDropped)
    }

    /// The transform to show `url` at `imageSize` with, given the transform now (`t`, still the previous photo's
    /// size): the saved mode and centre (`target`) at the view size of now, or nil for the normal view (another photo,
    /// a size the view does not apply to, or a zoom or pan since the arrival).
    public func transform(for url: URL, imageSize: CGSize, over t: ViewTransform) -> ViewTransform? {
        guard url == file, let target = target(imageSize: imageSize), t.mode == arrivalMode,
              t.center == arrivalCenter else { return nil }
        return ViewTransform(imageSize: imageSize, viewSize: t.viewSize, mode: target.mode, center: target.center)
    }
}
