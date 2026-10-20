import CoreGraphics
import LoupeCore

extension BackgroundColor {
    /// The colour in sRGB, for windows and layers.
    var cgColor: CGColor {
        let e = encoded
        return CGColor(srgbRed: e.red, green: e.green, blue: e.blue, alpha: 1)
    }
}
