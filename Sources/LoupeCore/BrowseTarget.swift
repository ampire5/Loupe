import Foundation
import HomeScreenModel

/// Where Return on a photo takes the folder browser (file browser spec §4.4): the photo's folder (an archive entry's:
/// the archive) with the photo selected.
public enum BrowseTarget {
    public static func location(for photo: URL) -> (location: BrowserLocation, select: String) {
        let photo = photo.standardizedFileURL
        return (.folder(photo.deletingLastPathComponent()), photo.path)
    }
}
