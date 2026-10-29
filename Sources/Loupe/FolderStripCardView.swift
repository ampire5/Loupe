import AppKit

/// The retained details inside the strip's shared card plate.
@MainActor final class FolderStripCardView: NSView {
    private let facts = NSTextField(wrappingLabelWithString: "")
    private let pictures = (0..<5).map { _ in NSImageView() }
    private var imageCount = 0
    private var textHeight: CGFloat = 0
    var preferredHeight: CGFloat { textHeight + (imageCount > 0 ? 48 : 0) + (imageCount > 0 && textHeight > 0 ? 8 : 0) + 20 }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        facts.textColor = NSColor(white: 0.75, alpha: 1)
        facts.font = .systemFont(ofSize: 11.5)
        facts.maximumNumberOfLines = 3
        facts.lineBreakMode = .byTruncatingTail
        addSubview(facts)
        for picture in pictures {
            picture.imageScaling = .scaleProportionallyUpOrDown
            picture.wantsLayer = true
            picture.layer?.cornerRadius = 5
            picture.layer?.masksToBounds = true
            picture.layer?.borderWidth = 0.5
            picture.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            addSubview(picture)
        }
        setAccessibilityLabel("Folder details")
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func update(text: String, images: [CGImage]) {
        facts.stringValue = text
        textHeight = text.isEmpty ? 0 : CGFloat(min(3, text.components(separatedBy: "\n").count)) * 16
        imageCount = min(pictures.count, images.count)
        for (i, picture) in pictures.enumerated() {
            picture.isHidden = i >= imageCount
            picture.image = images.indices.contains(i) ? NSImage(cgImage: images[i], size: .zero) : nil
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let h = min(textHeight, bounds.height)
        facts.frame = CGRect(x: -2, y: 0, width: bounds.width + 2, height: h)
        guard imageCount > 0 else { return }
        let y = h + (h > 0 ? 8 : 0)
        let width = max(0, (bounds.width - CGFloat(imageCount - 1) * 4) / CGFloat(imageCount))
        for (i, picture) in pictures.enumerated() where i < imageCount {
            picture.frame = CGRect(x: CGFloat(i) * (width + 4), y: y, width: width, height: min(48, max(0, bounds.height - y)))
        }
    }
}
