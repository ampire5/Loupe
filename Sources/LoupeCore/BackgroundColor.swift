import Foundation

/// `background`: the colour around the picture (the letterbox, and everything while no picture is shown), as
/// 8-bit sRGB-encoded components. Written as one of the `presets` (Lightroom's names) or `#RRGGBB` / `#RGB`.
/// The default is a neutral dark grey rather than black, a little darker than Lightroom's medium grey (user, 2026-10-15).
public struct BackgroundColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(gray: UInt8) { self.init(red: gray, green: gray, blue: gray) }

    public static let presets: [(name: String, color: BackgroundColor)] = [
        ("black", BackgroundColor(gray: 0x00)),
        ("dark-gray", BackgroundColor(gray: 0x1e)),
        ("medium-gray", BackgroundColor(gray: 0x33)),
        ("light-gray", BackgroundColor(gray: 0x80)),
        ("white", BackgroundColor(gray: 0xff)),
    ]

    public static let `default` = BackgroundColor(gray: 0x2a)

    /// A preset name (any case) or `#RRGGBB` / `#RGB`; nil for anything else.
    public init?(text: String) {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let preset = Self.presets.first(where: { $0.name == value }) {
            self = preset.color
            return
        }
        guard value.hasPrefix("#") else { return nil }
        var digits = String(value.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let rgb = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(rgb >> 16 & 0xff), green: UInt8(rgb >> 8 & 0xff), blue: UInt8(rgb & 0xff))
    }

    /// The preset's name when it is one, else `#rrggbb`.
    public var text: String {
        if let preset = Self.presets.first(where: { $0.color == self }) { return preset.name }
        return String(format: "#%02x%02x%02x", red, green, blue)
    }

    /// The components as encoded (0...1), for AppKit and Core Animation colours in sRGB.
    public var encoded: (red: Double, green: Double, blue: Double) {
        (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
    }

    /// The components in linear light (the sRGB transfer function undone), for a clear colour that an `_srgb`
    /// render target encodes on write.
    public var linear: (red: Double, green: Double, blue: Double) {
        let e = encoded
        return (Self.linearize(e.red), Self.linearize(e.green), Self.linearize(e.blue))
    }

    private static func linearize(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
}
