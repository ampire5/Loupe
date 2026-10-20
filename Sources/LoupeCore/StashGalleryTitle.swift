import Foundation

/// What Loupe calls a Stash gallery (`stash-title`): its own title; one with none is named after its file or folder
/// (StashKit's fallback), which `tidy` shows without the archive extension and with spaces for underscores.
public enum StashGalleryTitle {
    public static func display(title: String, path: String?, tidy: Bool) -> String {
        guard tidy, let path, let last = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last,
              title == String(last) else { return title }
        var name = title
        if (name as NSString).pathExtension.lowercased() == "zip" { name = (name as NSString).deletingPathExtension }
        name = name.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return name.isEmpty ? title : name
    }
}
