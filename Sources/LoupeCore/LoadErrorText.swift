import Foundation

/// The one-line message the stats bar shows when a file cannot be displayed. The file name appears exactly
/// once: system errors already say "The file “x.jpg” couldn’t be opened", so only their *reason* is used.
public enum LoadErrorText {
    /// `name: reason`. `size` (from the header, when it was read) is quoted for `.tooLarge`.
    public static func message(name: String, error: Error, size: PixelSize?) -> String {
        "\(name): \(reason(for: error, size: size))"
    }

    static func reason(for error: Error, size: PixelSize?) -> String {
        switch error {
        case DecodeError.unreadable: return "unreadable or unsupported image"
        case DecodeError.outOfMemory: return "not enough memory"
        case DecodeError.tooLarge:
            return size.map { "too large to display (\($0.width)×\($0.height))" } ?? "too large to display"
        case let cocoa as CocoaError:
            // "The file doesn’t exist." / "You don’t have permission to view it." — no file name inside.
            let text = (cocoa as NSError).localizedFailureReason ?? ""
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return trimmed.isEmpty ? "can’t read the file" : trimmed.prefix(1).lowercased() + trimmed.dropFirst()
        default: return "can’t be displayed"
        }
    }
}
