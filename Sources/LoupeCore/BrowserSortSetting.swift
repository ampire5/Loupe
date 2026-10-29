import Foundation
import HomeScreenModel

/// `browser-sort` in a folder's settings (file browser spec §4.2): the browser's order for the folder and the ones under
/// it, which the strip and the steps follow too.
extension BrowserSort {
    public static let settingKey = "browser-sort"

    /// The folder's sort, inherited from its ancestors; none set, or text that is not a sort, is by name.
    public static func forFolder(_ folder: URL, settings: FolderSettings?) -> BrowserSort {
        settings?.values(for: folder)[settingKey].flatMap(BrowserSort.init(text:)) ?? .standard
    }
}
