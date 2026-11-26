import AppKit
import HomeChrome

/// A caption over the picture. Each line is positioned on its own so late metadata never moves the title.
@MainActor final class StripCaption: NSView {
    private static let inset: CGFloat = 10
    private static let edgeGap: CGFloat = 6
    private let titleFont = Chrome.Text.digits(.label, weight: .medium)
    private let glass = ChromeGlass(style: .overMedia(.regular), cornerRadius: 0)
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        Chrome.Palette.overMedia.apply(to: self)
        title.font = titleFont
        detail.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for field in [title, detail] {
            field.textColor = Chrome.Palette.overMedia.text
            field.alignment = .center
            field.lineBreakMode = .byTruncatingMiddle
            glass.contentView.addSubview(field)
        }
        glass.contentView.wantsLayer = true
        // Keep a readable backing before the platform glass has resolved the material over a bright photo.
        glass.contentView.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.80).cgColor
        glass.contentView.layer?.masksToBounds = true
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateTitle(_ text: String) {
        if text != title.stringValue { title.stringValue = text }
    }

    func show(title text: String, detail extra: String = "", reservedTitle: String? = nil,
              centre: CGFloat, above bottom: CGFloat, within room: NSRect, avoiding obstruction: NSRect? = nil) {
        let inset = Self.inset
        let sides = room.insetBy(dx: Self.edgeGap, dy: 0)
        guard sides.width > 2 * inset else { isHidden = true; return }
        updateTitle(text)
        if extra != detail.stringValue { detail.stringValue = extra }
        let titleWidth = reservedTitle.map { ($0 as NSString).size(withAttributes: [.font: titleFont]).width + 4 }
            ?? title.intrinsicContentSize.width
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let detailHeight = extra.isEmpty ? 0 : ceil(detail.intrinsicContentSize.height) + 2
        let y = min(bottom, room.maxY - titleHeight - 6 - Self.edgeGap)

        func line(width: CGFloat, height: CGFloat, y: CGFloat) -> NSRect {
            // Glass can give its labels a heavier legibility weight than the field's intrinsic size measures.
            let width = min(ceil(width * 1.08) + 8 + 2 * inset, sides.width)
            let x = min(max(centre - width / 2, sides.minX), sides.maxX - width)
            let proposed = NSRect(x: x, y: y, width: width, height: height)
            guard let obstruction, obstruction.intersects(proposed) else { return proposed }
            // The tools sit at the right edge. Move the line left, shortening it only if the window requires it.
            let available = obstruction.minX - sides.minX
            guard available > 2 * inset else { return proposed }
            let fitted = min(width, available)
            return NSRect(x: min(x, obstruction.minX - fitted), y: y, width: fitted, height: height)
        }

        let titleRect = line(width: titleWidth, height: titleHeight + 6, y: y)
        let fitsDetail = detailHeight > 0 && titleRect.maxY + detailHeight <= room.maxY - Self.edgeGap
        let detailRect = fitsDetail
            ? line(width: detail.intrinsicContentSize.width, height: detailHeight, y: titleRect.maxY)
            : .zero
        frame = fitsDetail ? titleRect.union(detailRect) : titleRect
        glass.frame = bounds
        glass.cornerRadius = min(13, bounds.height / 2)
        glass.contentView.layer?.cornerRadius = glass.cornerRadius
        title.frame = titleRect.insetBy(dx: inset, dy: 3).offsetBy(dx: -frame.minX, dy: -frame.minY)
        detail.isHidden = !fitsDetail
        if fitsDetail {
            detail.frame = detailRect.insetBy(dx: inset, dy: 1).offsetBy(dx: -frame.minX, dy: -frame.minY)
        }
        isHidden = false
    }
}
