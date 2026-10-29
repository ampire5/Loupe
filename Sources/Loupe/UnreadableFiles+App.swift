import Foundation
import HomeScreenModel
import LoupeCore

extension UnreadableFiles {
    /// Loupe's one: Home's grid in every window, the strip and the viewer read and mark the same files.
    static let app = UnreadableFiles()

    /// Marks `url` as it was listed (`stamp`), or by its URL alone when its stamp is not known yet.
    func mark(_ url: URL, stamp: FileStamp?) {
        mark(url, date: stamp?.modified, size: stamp.map { Int64($0.size) })
    }

    func contains(_ url: URL, stamp: FileStamp?) -> Bool {
        contains(url, date: stamp?.modified, size: stamp.map { Int64($0.size) })
    }
}
