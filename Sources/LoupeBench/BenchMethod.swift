import Foundation
import LoupeCore

/// Table-row naming for the bench, on top of LoupeCore's format detection.
extension ImageFormat {
    /// Short name for table row labels; nil for JPEG, the default case, whose rows stay unsuffixed.
    /// A JXL that carries a `jbrd` box is a lossless JPEG transcode, which decodes very differently
    /// from a native VarDCT file, so it gets its own variant (the box sits before the codestream).
    static func variantName(_ data: Data) -> String? {
        guard let format = detect(data) else { return nil }
        switch format {
        case .jpeg: return nil
        case .png: return "png"
        case .webp: return "webp"
        case .heic: return "heic"
        case .avif: return "avif"
        case .jxl:
            let isTranscode = data.prefix(1 << 16).range(of: Data("jbrd".utf8)) != nil
            return isTranscode ? "jxl jpeg-transcode" : "jxl"
        }
    }

    /// `name` with the format variant appended, e.g. `imageio-full (avif)`; JPEG stays plain.
    static func rowLabel(_ name: String, for data: Data) -> String {
        variantName(data).map { "\(name) (\($0))" } ?? name
    }
}

/// One decode method under test: which formats it accepts, how to run it, and how its table row
/// is labelled for a given file (so e.g. progressive and baseline JPEGs are not averaged together).
struct BenchMethod {
    /// Formats this method can decode; the harness skips other files without counting a failure.
    var formats: Set<ImageFormat>
    var decode: (Data) throws -> PixelSize
    /// Row label for `name` on this file. Runs outside the timed region.
    var label: (_ name: String, _ data: Data) -> String = { name, _ in name }

    /// Finer filter than `formats` (e.g. progressive JPEGs only); false skips the file without a failure.
    var isApplicable: (Data) -> Bool = { _ in true }

    /// True when the harness should run this method on `data`.
    func accepts(_ data: Data) -> Bool {
        (ImageFormat.detect(data).map(formats.contains) ?? false) && isApplicable(data)
    }
}
