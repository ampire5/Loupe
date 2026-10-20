import Foundation

/// `transparency`: what shows through a photo's transparent pixels (M3b spec §3). Outside the picture it is always
/// `background`.
public enum TransparencyMode: String, CaseIterable, Sendable {
    /// A checkerboard of `checker-colors`, `checker-size` pt cells anchored at the picture's top-left on screen.
    case checker
    /// The `background` colour.
    case background
    case black, white

    /// Case-insensitive.
    public init?(text: String) {
        self.init(rawValue: text.lowercased())
    }
}

/// `checker-colors`: the checkerboard's two cell colours, the top-left cell's first. `light` (#FFFFFF / #CCCCCC) and
/// `dark` (#333333 / #262626) by name, anything else as `#RRGGBB,#RRGGBB` (`#RGB` too, as `background` takes it; no
/// space after the comma in loupe.conf, where ` #` starts a comment).
public struct CheckerColors: Equatable, Sendable {
    public var first: BackgroundColor
    public var second: BackgroundColor

    public init(_ first: BackgroundColor, _ second: BackgroundColor) {
        self.first = first
        self.second = second
    }

    public static let light = CheckerColors(BackgroundColor(gray: 0xff), BackgroundColor(gray: 0xcc))
    public static let dark = CheckerColors(BackgroundColor(gray: 0x33), BackgroundColor(gray: 0x26))

    /// `light`, `dark` (any case) or two hex colours separated by a comma; nil for anything else.
    public init?(text: String) {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "light": self = .light
        case "dark": self = .dark
        default:
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // Hex only: a preset name such as `white` is a `background` value, not a checker colour.
            guard parts.count == 2, parts.allSatisfy({ $0.hasPrefix("#") }),
                  let first = BackgroundColor(text: parts[0]), let second = BackgroundColor(text: parts[1])
            else { return nil }
            self.init(first, second)
        }
    }

    /// `light` or `dark` when it is one, else `#rrggbb,#rrggbb`.
    public var text: String {
        if self == .light { return "light" }
        if self == .dark { return "dark" }
        return String(format: "#%02x%02x%02x,#%02x%02x%02x", first.red, first.green, first.blue,
                      second.red, second.green, second.blue)
    }
}

/// The transparency keys as the renderer reads them: what lies under a photo's pixels with alpha < 1, resolved to two
/// cell colours in linear light (one colour twice for the solid modes, so the shader has a single path). The renderer
/// multiplies `checkerSizePt` by the window's backing scale for the cell side in drawable pixels.
public struct TransparencySettings: Equatable, Sendable {
    public var mode: TransparencyMode
    /// `checker-size`: the cell side in points.
    public var checkerSizePt: Int
    /// The top-left cell's colour and the other one, linear light (the `_srgb` drawable encodes them).
    public var colors: (SIMD3<Float>, SIMD3<Float>)

    public init(mode: TransparencyMode = .checker, checkerSizePt: Int = 8, colors: CheckerColors = .light,
                background: BackgroundColor = .default) {
        self.mode = mode
        self.checkerSizePt = checkerSizePt
        switch mode {
        case .checker: self.colors = (Self.linear(colors.first), Self.linear(colors.second))
        case .background: self.colors = (Self.linear(background), Self.linear(background))
        case .black: self.colors = (SIMD3(repeating: 0), SIMD3(repeating: 0))
        case .white: self.colors = (SIMD3(repeating: 1), SIMD3(repeating: 1))
        }
    }

    public init(config: Config) {
        self.init(mode: config.transparency, checkerSizePt: config.checkerSize, colors: config.checkerColors,
                  background: config.background)
    }

    public static func == (a: TransparencySettings, b: TransparencySettings) -> Bool {
        a.mode == b.mode && a.checkerSizePt == b.checkerSizePt && a.colors.0 == b.colors.0 && a.colors.1 == b.colors.1
    }

    private static func linear(_ color: BackgroundColor) -> SIMD3<Float> {
        let c = color.linear
        return SIMD3(Float(c.red), Float(c.green), Float(c.blue))
    }
}
