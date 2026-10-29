import CoreGraphics
import SlotModel

public enum ViewerSlotLayout {
    public struct Insets: Equatable, Sendable {
        public var left: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0
        public static let zero = Insets()
    }
    public static func area(in bounds: CGRect, top: CGFloat, bottom: CGFloat) -> CGRect {
        let bottom = min(max(0, bottom), bounds.height)
        return CGRect(x: bounds.minX, y: bounds.minY + bottom, width: bounds.width,
                      height: max(0, bounds.height - bottom - max(0, top)))
    }
    public static func pinnedInsets(layout: SlotLayout, area: CGRect) -> Insets {
        pinnedInsets(video: layout.video, area: area)
    }
    public static func pinnedInsets(video: CGRect, area: CGRect) -> Insets {
        Insets(left: max(0, video.minX), right: max(0, area.width - video.maxX),
               bottom: video.minY > 0 ? area.minY + video.minY : 0)
    }
}
