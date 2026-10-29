import AppKit
import HomeChrome
import HomeScreenKit
import HomeScreenModel
import LoupeCore

/// The look of a camera's information screen, the infographic of photo and video cameras: white for the numbers that
/// are what the photo is, grey for the quiet ones, yellow for what the user changed (a camera lights a mode one set by
/// hand), green, amber and red for how well something goes (a card, a battery, a level), a small symbol before each
/// value, hairlines between the groups. It belongs to no view: the toolbar's status and the stats bar both speak it,
/// and the symbols and colours are meant to become the style of the other apps' chrome too. The colours are those of a
/// dark ground (the one a camera's screen has), so they hold on any photo behind the dark strip; `monochrome` leaves
/// only white and grey.
enum ProCameraStyle {
    static let primary = NSColor.white
    static let secondary = NSColor.white.withAlphaComponent(0.62)
    static let separator = NSColor.white.withAlphaComponent(0.24)
    static let yellow = NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)
    // Lighter than the system's own, so that they hold on the strip over a white sky (about 4:1 for the green, the
    // yellow and the amber; the red, the hardest on a dark ground, about 3:1, helped by the shadow).
    static let green = NSColor(srgbRed: 0.37, green: 0.88, blue: 0.48, alpha: 1)
    static let amber = NSColor(srgbRed: 1, green: 0.70, blue: 0.25, alpha: 1)
    static let red = NSColor(srgbRed: 1, green: 0.54, blue: 0.50, alpha: 1)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        // As in HomeChrome's counter styles: readable system letters, stable-width digits.
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// A soft shadow that keeps text readable on whatever the picture is.
    static let shadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        return shadow
    }()

    /// The symbol in front of a fact of `kind`.
    static func symbol(_ kind: ImageStatus.Kind) -> String {
        switch kind {
        case .position: "square.stack"
        case .size: "arrow.up.left.and.arrow.down.right"
        case .megapixels: "square.grid.3x3"
        case .exposure: "camera.aperture"
        case .fileSize: "externaldrive"
        case .format: "doc.richtext"
        case .zoom: "magnifyingglass"
        }
    }

    static let folderSymbol = "folder"
    static let dateSymbol = "calendar"
    static let decodeSymbol = "timer"

    /// The colour of a value of `tone`; with `monochrome` only white and grey.
    static func color(_ tone: ImageStatus.Tone, monochrome: Bool) -> NSColor {
        switch tone {
        case .normal: primary
        case .quiet: secondary
        case .adjusted: monochrome ? primary : yellow
        case .good: monochrome ? primary : green
        case .caution: monochrome ? primary : amber
        case .warning: monochrome ? primary : red
        }
    }

    struct Options: Equatable {
        var size: CGFloat
        var icons = false
        var monochrome = false
        var shadow = false
    }

    /// One fact as it is drawn: the symbol (with `icons`) and the value in the colour of its tone, the position's number
    /// lit and its total dim.
    static func text(_ fact: ImageStatus.Fact, _ options: Options) -> NSAttributedString {
        let tint = color(fact.tone, monochrome: options.monochrome)
        let result = NSMutableAttributedString()
        // EXIF already carries conventional labels (f/, ISO, mm, EV). Repeating a glyph for
        // every value crowds the line; quiet separators make those values easier to scan.
        if fact.kind == .exposure {
            let value = fact.parts.isEmpty ? fact.value
                : fact.parts.map(\.text).joined(separator: "  ·  ")
            result.append(plain(value, options.size, .medium, tint, options))
            return result
        }
        if options.icons { result.append(icon(symbol(fact.kind), tint: tint, options)) }
        switch fact.kind {
        case .position:
            let parts = fact.value.components(separatedBy: " / ")
            result.append(plain(parts[0], options.size, .semibold, primary, options))
            if parts.count > 1 { result.append(plain(" / " + parts[1], options.size, .medium, secondary, options)) }
        case .fileSize, .megapixels:
            result.append(plain(fact.value, options.size, .medium, tint, options))
        case .exposure:
            result.append(plain(fact.value, options.size, .semibold, tint, options))
        case .size, .format, .zoom:
            result.append(plain(fact.value, options.size, .semibold, tint, options))
        }
        return result
    }

    /// A line of the quieter facts (the date, the decode time): a symbol and the text in the colour of its tone.
    static func detail(_ symbol: String, _ value: String, tone: ImageStatus.Tone, _ options: Options) -> NSAttributedString {
        let tint = color(tone, monochrome: options.monochrome)
        let result = NSMutableAttributedString()
        if options.icons { result.append(icon(symbol, tint: tint, options)) }
        result.append(plain(value, options.size, .medium, tint, options))
        return result
    }

    /// A name (a file, a folder) in the system's own font, with the shadow: it is not a number, so it is not monospaced.
    static func name(_ value: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                       .foregroundColor: color, .shadow: shadow])
    }

    static func plain(_ value: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
                      _ options: Options) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(size, weight), .foregroundColor: color]
        if options.shadow { attributes[.shadow] = shadow }
        return NSAttributedString(string: value, attributes: attributes)
    }

    /// The symbol in the icon set picked, as a character of the line (Lucide) or an attachment (SF Symbols).
    private static func icon(_ symbol: String, tint: NSColor, _ options: Options) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: Icons.inline(symbol, size: options.size, color: tint,
                                                                              shadow: options.shadow ? shadow : nil,
                                                                              space: ""))
        result.append(plain(" ", options.size, .regular, tint, options))
        return result
    }
}
