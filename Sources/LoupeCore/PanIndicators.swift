import CoreGraphics
import Foundation

/// One position pill (M4b spec §5): its rectangle in the area it stands in (`PanIndicators.pills`), origin top-left. The pill's shape is the rectangle's
/// rounded ends, radius half its thickness.
public struct PanIndicatorPill: Equatable, Sendable {
    public var rect: CGRect

    public init(rect: CGRect) {
        self.rect = rect
    }
}

/// The pan position indicators' maths (M4b spec §5): where the pills stand and how opaque they are. Pure: the app draws
/// the rectangles in an overlay over the window's content (`PanIndicatorsView`).
public enum PanIndicators {
    /// Pill thickness, distance from the area's edge and minimum length, in points (× the window's backing scale).
    public static let thicknessPoints = 5.0
    public static let insetPoints = 4.0
    public static let minLengthPoints = 24.0

    /// The pills of `t`, standing in `area` (origin top-left, in the units `backingScale` turns points into): a
    /// horizontal one at the area's bottom when the picture is wider than the view, a vertical one at its right when it
    /// is taller. The area is the window's container (full screen: the screen), not the viewer, so the pills sit at the
    /// window's edge over the strip and side panels whatever the strip's placement; windowed, its top is below the stats
    /// bar. A pill's length is the visible share of its track (at least `minLengthPoints`), its position the visible
    /// rect's place in the picture, both from `t` alone; a rubber-banded picture pins it at the track's end, not
    /// squeezed. A track shorter than the minimum length gives no pill.
    public static func pills(for t: ViewTransform, backingScale: Double, in area: CGRect) -> [PanIndicatorPill] {
        let axes = t.pannableAxes
        // `size`, not `width`, `height`: those are absolute, so a negative area would pass.
        guard axes.x || axes.y, area.size.width > 0, area.size.height > 0 else { return [] }
        let k = max(backingScale, 0)
        let thickness = thicknessPoints * k, inset = insetPoints * k, minLength = minLengthPoints * k
        let visible = t.visibleRect
        let image = t.imageSize
        let corner = thickness + inset   // what the other pill's thickness takes off this one's track

        var result: [PanIndicatorPill] = []
        if axes.x, inset + thickness <= area.height {   // too short an area: no pill, never one above its top
            let end = area.maxX - inset - (axes.y ? corner : 0)
            if let (start, length) = span(from: area.minX + inset, to: end, minLength: minLength,
                                          visibleMin: visible.minX, visibleSize: visible.width, image: image.width) {
                result.append(PanIndicatorPill(rect: CGRect(x: start, y: area.maxY - inset - thickness,
                                                            width: length, height: thickness)))
            }
        }
        if axes.y {
            let end = area.maxY - inset - (axes.x ? corner : 0)
            if let (start, length) = span(from: area.minY + inset, to: end, minLength: minLength,
                                          visibleMin: visible.minY, visibleSize: visible.height, image: image.height) {
                result.append(PanIndicatorPill(rect: CGRect(x: area.maxX - inset - thickness, y: start,
                                                            width: thickness, height: length)))
            }
        }
        return result
    }

    /// Start and length of the pill on the track `from ... to`, nil when the track is shorter than `minLength`.
    private static func span(from: Double, to: Double, minLength: Double, visibleMin: Double, visibleSize: Double,
                             image: Double) -> (Double, Double)? {
        let track = to - from
        guard track >= minLength, track > 0, image > 0 else { return nil }
        let share = min(max(visibleSize / image, 0), 1)
        let length = min(max(minLength, track * share), track)
        let room = image - visibleSize
        let place = room > 0 ? min(max(visibleMin / room, 0), 1) : 0
        return (from + (track - length) * place, length)
    }

    /// The pills' opacity at `now` (seconds, any clock the caller keeps): `always` 1, `no` 0; `auto` 1 until `hide`
    /// seconds after `lastMotion`, then linear to 0 over `fade`, and 0 when nothing has moved yet. A zero `fade` hides
    /// at once after `hide`.
    public static func alpha(mode: PanIndicatorMode, now: TimeInterval, lastMotion: TimeInterval?, hide: TimeInterval,
                             fade: TimeInterval) -> Double {
        switch mode {
        case .always: return 1
        case .no: return 0
        case .auto:
            guard let lastMotion else { return 0 }
            let since = now - lastMotion
            if since <= hide { return 1 }
            guard fade > 0 else { return 0 }
            return min(max(1 - (since - hide) / fade, 0), 1)
        }
    }

    /// Whether a change handed to the renderer is motion, which shows the pills in `auto` (M4b spec §5.2): the visible
    /// part, the drawn zoom or the picture's size changed on the same picture (a pan, a zoom, an animation, a window
    /// resize). Another picture (a photo switch, whose size, zoom and visible part change with it) is motion only with
    /// `pan-indicators-on-switch=yes` (`onSwitch`); with `no` it leaves the pills as they are (fading ones keep
    /// fading).
    public static func isMotion(sameImage: Bool, imageSizeChanged: Bool, scaleChanged: Bool, visibleChanged: Bool,
                                onSwitch: Bool) -> Bool {
        guard sameImage else { return onSwitch }
        return imageSizeChanged || scaleChanged || visibleChanged
    }

    /// `rect` (points) with each edge on the nearest backing pixel (`backingScale` pixels per point), so a pill's
    /// 1 px outline lands on whole pixels and stays crisp.
    public static func pixelAligned(_ rect: CGRect, backingScale: Double) -> CGRect {
        let scale = max(backingScale, 1)
        func snap(_ v: Double) -> Double { (v * scale).rounded() / scale }
        let minX = snap(rect.minX), minY = snap(rect.minY)
        return CGRect(x: minX, y: minY, width: snap(rect.maxX) - minX, height: snap(rect.maxY) - minY)
    }

    /// The toast of the `P` key for `mode`, and of `⇧P`.
    public static func toast(for mode: PanIndicatorMode) -> String {
        switch mode {
        case .auto: return "Pan indicators: auto"
        case .always: return "Pan indicators: always"
        case .no: return "Pan indicators: off"
        }
    }

    public static let savedToast = "Pan indicators saved as default"
}
