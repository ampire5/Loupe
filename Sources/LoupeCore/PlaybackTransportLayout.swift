import CoreGraphics

/// The transport is pinned to the playback surface. A floating filmstrip starts above it.
public struct PlaybackTransportLayout {
    public let height: CGFloat

    public init(height: CGFloat) { self.height = height }

    public func stripClearance(reservesSpace: Bool, bottomInset: CGFloat) -> CGFloat {
        height > 0 && !reservesSpace ? height + bottomInset : 0
    }

    public func contains(_ offsetFromBottom: CGFloat) -> Bool {
        offsetFromBottom >= 0 && offsetFromBottom < height
    }
}
