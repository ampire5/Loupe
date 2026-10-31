import Foundation

extension SubjectComposition {
    public enum Adjustment: Equatable, Sendable {
        case none, shifted, zoomedOut, blocked
        public var note: String? {
            switch self {
            case .none: return nil
            case .shifted: return "Shifted to preserve protected objects"
            case .zoomedOut: return "Zoom reduced to preserve protected objects"
            case .blocked: return "Keep zoom prevents full protection"
            }
        }
    }
    public struct Resolution: Equatable, Sendable {
        public var transform: ViewTransform
        public var adjustment: Adjustment
        public var protectedCount: Int
    }

    /// The feasible centre interval is exact on each axis. Its intersection keeps every required region visible;
    /// its nearest point changes pan first. Scale decreases only when either intersection cannot exist at all.
    public func resolve(_ t: ViewTransform, autoZoom: Bool, size: Double,
                        preferredCenter: CGPoint? = nil) -> Resolution {
        let inputs = [t.imageSize.width, t.imageSize.height, t.viewSize.width, t.viewSize.height,
                      frame.width, frame.height, frame.minX, frame.minY, desiredCenter.x, desiredCenter.y, size]
        guard inputs.allSatisfy(\.isFinite), inputs.prefix(6).allSatisfy({ $0 > 0 }) else {
            return .init(transform: t, adjustment: .none, protectedCount: 0)
        }
        var proposal = proposedTransform(t, autoZoom: autoZoom, size: size)
        if let preferredCenter, preferredCenter.x.isFinite, preferredCenter.y.isFinite {
            proposal.center = preferredCenter
            proposal = proposal.clamped
        }
        let group = SubjectFraming.validRect(support ?? frame)
        let protection = protectedRegions.compactMap { SubjectFraming.validRect($0.rect) }
        var required = CGRect.null
        // Keep zoom explicitly allows a clipped group. Protection still gets every feasible pan at this scale.
        if autoZoom || panOverflow == .fit, let group { required = group }
        for region in protection { required = required.union(region) }
        guard !required.isNull else {
            return .init(transform: proposal, adjustment: .none, protectedCount: 0)
        }
        let cap = min(t.viewSize.width / (required.width * t.imageSize.width),
                      t.viewSize.height / (required.height * t.imageSize.height))
        var result = proposal
        let canOutzoom = autoZoom || panOverflow == .fit
        if canOutzoom, cap < proposal.scale {
            let scale = min(proposal.scale, max(t.fitScale, cap))
            if scale < proposal.scale { result = proposal.withMode(.actual(scale)) }
        }
        let window = CGSize(width: t.viewSize.width / (result.scale * t.imageSize.width),
                            height: t.viewSize.height / (result.scale * t.imageSize.height))
        func project(_ target: Double, _ lo: Double, _ hi: Double, _ width: Double) -> Double {
            guard width < 1 else { return 0.5 }
            let lower = max(width / 2, hi - width / 2)
            let upper = min(1 - width / 2, lo + width / 2)
            if lower > upper + 1e-12 { return min(max(target, width / 2), 1 - width / 2) }
            return min(max(target, lower), max(lower, upper))
        }
        result.center = CGPoint(x: project(proposal.clamped.center.x, required.minX, required.maxX, window.width),
                                y: project(proposal.clamped.center.y, required.minY, required.maxY, window.height))
        result = result.clamped
        let blocked = !protection.isEmpty && (required.width > window.width + 1e-10 || required.height > window.height + 1e-10)
        let adjustment: Adjustment
        if blocked { adjustment = .blocked }
        else if !protection.isEmpty && result.scale < proposal.scale - 1e-10 { adjustment = .zoomedOut }
        else if !protection.isEmpty && hypot(result.center.x - proposal.clamped.center.x,
                                            result.center.y - proposal.clamped.center.y) > 1e-10 { adjustment = .shifted }
        else { adjustment = .none }
        return .init(transform: result, adjustment: adjustment, protectedCount: protection.count)
    }
}
