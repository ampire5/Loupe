import Foundation

/// Composition settings are independent of detection and of image resolution.
public struct CompositionOptions: Equatable, Sendable {
    public enum Normalization: String, Sendable { case `class`, object }
    public enum PanOverflow: String, Sendable { case fit, keep }
    public var panOverflow = PanOverflow.fit
    public var maxZoom = 1.0
    public var margin = 0.08
    public var normalization = Normalization.class
    public var weights: [SubjectKind: Double] = [:]
    public init() {}

    /// nil: another key; false: recognized but invalid. Invalid input leaves the value intact.
    public mutating func set(_ key: String, _ value: String) -> Bool? {
        switch key {
        case "pan-overflow":
            guard let v = PanOverflow(rawValue: value.lowercased()) else { return false }; panOverflow = v
        case "max-zoom":
            guard let v = DetectorSetup.share(value), v.isFinite, (0.25...4).contains(v) else { return false }
            maxZoom = v
        case "margin":
            guard let v = DetectorSetup.share(value), v.isFinite, (0...1).contains(v) else { return false }
            margin = v
        case "weight-normalization":
            guard let v = Normalization(rawValue: value.lowercased()) else { return false }; normalization = v
        case "weights":
            var parsed: [SubjectKind: Double] = [:]
            if !value.isEmpty {
                for item in value.split(separator: ",", omittingEmptySubsequences: false) {
                    let pair = item.split(separator: ":", omittingEmptySubsequences: false)
                    guard pair.count == 2, let kind = SubjectKind(rawValue: String(pair[0])), !kind.isCombination,
                          let weight = Double(pair[1].trimmingCharacters(in: .whitespaces)), weight.isFinite,
                          (0.25...4).contains(weight) else { return false }
                    parsed[kind] = weight
                }
            }
            weights = parsed
        default: return nil
        }
        return true
    }
    public var values: [String: String] {
        ["pan-overflow": panOverflow.rawValue, "max-zoom": "\(maxZoom * 100)%", "margin": "\(margin * 100)%", "weight-normalization": normalization.rawValue,
         "weights": weights.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue):\($0.value)" }.joined(separator: ",")]
    }
}

public struct SubjectComposition: Equatable, Sendable {
    public var frame: CGRect
    public var desiredCenter: CGPoint
    public var maxZoom: Double
    public var panOverflow = CompositionOptions.PanOverflow.fit
    public var objects: [CGRect] = []

    /// The desired center projected onto the range preserving every selected box where it fits.
    /// An oversized axis keeps the weighted center; photo bounds always take precedence.
    public func transform(_ t: ViewTransform, autoZoom: Bool, size: Double) -> ViewTransform {
        guard t.imageSize.width > 0, t.imageSize.height > 0, t.viewSize.width > 0, t.viewSize.height > 0 else { return t }
        var result = t
        if autoZoom {
            let q = min(max(size, 0.2), 1)
            let s = min(t.viewSize.width * q / (frame.width * t.imageSize.width),
                        t.viewSize.height * q / (frame.height * t.imageSize.height), maxZoom)
            // Fit is the useful lower bound, even when a tiny source exceeds the native cap at Fit.
            result = s <= t.fitScale ? t.withMode(.fit) : t.withMode(.actual(s))
        }
        if !autoZoom && panOverflow == .fit {
            let fitGroup = min(t.viewSize.width / (frame.width * t.imageSize.width),
                               t.viewSize.height / (frame.height * t.imageSize.height))
            // Pan never zooms in. Only an oversized group can reduce the retained scale.
            if fitGroup < t.scale { result = t.withMode(.actual(min(t.scale, max(t.fitScale, fitGroup)))) }
        }
        func project(_ target: Double, _ lo: Double, _ hi: Double, _ window: Double) -> Double {
            guard window < 1 else { return 0.5 }
            var lower = window / 2, upper = 1 - window / 2
            if hi - lo <= window + 1e-12 {
                lower = max(lower, hi - window / 2)
                upper = min(upper, lo + window / 2)
            }
            if lower > upper { return min(max(target, window / 2), 1 - window / 2) }
            return min(max(target, lower), upper)
        }
        let window = CGSize(width: result.viewSize.width / (result.scale * result.imageSize.width),
                            height: result.viewSize.height / (result.scale * result.imageSize.height))
        result.center = CGPoint(x: project(desiredCenter.x, frame.minX, frame.maxX, window.width),
                                y: project(desiredCenter.y, frame.minY, frame.maxY, window.height))
        result = result.clamped
        if !autoZoom && panOverflow == .keep && !objects.isEmpty {
            let visible = CGRect(x: result.center.x - window.width / 2, y: result.center.y - window.height / 2,
                                 width: window.width, height: window.height)
            if !objects.contains(where: { visible.intersects($0) }),
               let nearest = objects.min(by: {
                   hypot($0.midX - desiredCenter.x, $0.midY - desiredCenter.y)
                       < hypot($1.midX - desiredCenter.x, $1.midY - desiredCenter.y)
               }) {
                result.center = CGPoint(x: nearest.midX, y: nearest.midY)
            }
        }
        return result.clamped
    }
}

extension SubjectFraming {
    public static func composition(_ boxes: SubjectBoxes, kind: SubjectKind,
                                   options: CompositionOptions) -> SubjectComposition? {
        var objects: [CGRect] = []
        var union = CGRect.null, sx = 0.0, sy = 0.0, total = 0.0
        for part in kind.parts {
            let rects = boxes.boxes(part).compactMap(validRect)
            guard !rects.isEmpty else { return nil }
            let configured = options.weights[part] ?? 1
            let weight = (configured.isFinite && configured > 0 ? configured : 1)
                / (options.normalization == .class ? Double(rects.count) : 1)
            objects += rects
            for r in rects {
                sx += r.midX * weight; sy += r.midY * weight; total += weight
                union = union.union(kind.parts.count == 1 && framesHead(part) ? head(r) : r)
            }
        }
        let margin = options.margin.isFinite ? min(max(options.margin, 0), 1) : 0.08
        let frame = union.insetBy(dx: -union.width * margin, dy: -union.height * margin)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard total > 0, let valid = validRect(frame) else { return nil }
        return SubjectComposition(frame: valid, desiredCenter: CGPoint(x: sx / total, y: sy / total),
                                  maxZoom: options.maxZoom.isFinite ? min(max(options.maxZoom, 0.25), 4) : 1,
                                  panOverflow: options.panOverflow, objects: objects)
    }
}
