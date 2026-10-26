import Foundation
import LoupeCore

extension ViewerSession {
    /// What the session says about the photo it is on, for the toolbar's status and the stats bar alike. A step never
    /// takes the words away: the name and the place are the new photo's at once, and while it loads the facts of the photo
    /// still on screen stay, grey (`entry` is that photo until the new one qualifies), so the bar changes its text and
    /// nothing in it appears or goes. A news item about the folder stands in the place of the folder's name; the failure
    /// of the photo in the place of its own.
    var imageStatus: ImageStatus {
        var status = ImageStatus()
        let list = playlist
        status.folder = list?.current.deletingLastPathComponent()
        if let folderMessage {
            status.note = folderMessage
            status.noteTone = folderMessage == FolderRequest.loadingText ? .quiet : .caution
        }
        guard let list else { return status }
        let pages = currentPages
        // The position the facts and the progress fill give: the current photo's, a pair's range and last page.
        let index = pages?.first ?? list.index
        let fillIndex = pages?.second ?? index
        status.title = ArchivePath.shortName(list.files[index])
        if let second = pages?.second { status.title += " · " + ArchivePath.shortName(list.files[second]) }
        let position = ImageStatus.Fact(.position, StatsLine.position(index: index, companion: pages?.second,
                                                                      count: list.files.count, counted: folderCounted))
        status.facts = [position]
        if let error {
            status.title = error
            status.titleTone = .warning
        } else if let entry, let info = entry.info, entry.failure == nil {
            // The photo on screen: the current one once it qualified, the previous one until then.
            let current = entry.url == list.current && loadingName == nil
            var shown = (info: info, timings: entry.timings)
            if current, shownLayout != nil, pages?.second != nil,
               let other = shownCompanion, let otherInfo = other.info,
               StatsLine.factsOfCompanion(current: list.index, first: index, companionRead: other.failure == nil) {
                // The first page's facts in reading order, whichever page is current.
                shown = (otherInfo, other.timings)
            }
            let facts = ImageStatus.facts(index: index, companion: pages?.second, count: list.files.count,
                                          counted: folderCounted, info: shown.info, applyingOrientation: appliesOrientation,
                                          transform: zoomTarget ?? transform)   // a zoom animation's target
            // The facts of the photo before are grey while the new one loads; the zoom is the viewer's own.
            status.facts = facts.map { current || $0.kind == .position || $0.kind == .zoom ? $0 : ImageStatus.Fact($0.kind, $0.value, tone: .quiet) }
            if current { status.decodeMilliseconds = (shown.timings.fullMs ?? shown.timings.previewMs).map { Int($0.rounded()) } }
        }
        status.photo = list.files[index]
        // An uncounted folder's interim `1 / 1` would fill the whole bar.
        status.progress = folderCounted ? StatsLine.progress(index: fillIndex, count: list.files.count) : 0
        if list.files.indices.contains(index) {
            let folder = list.current.deletingLastPathComponent().standardizedFileURL.path
            status.navigationKey = "\(folder)|\(index)|\(pages?.second ?? -1)"
        }
        return status
    }
}

/// The name a folder goes by in the status and the key toast.
enum FolderLabel {
    static func name(of folder: URL) -> String {
        StatsLine.folderName(of: folder, volumeName: volumeName(ofRoot: folder))
    }

    /// The startup volume's name for "/", which has no name of its own. Nothing is looked up elsewhere: a share's
    /// mount point under /Volumes already carries the share's name, and asking a server that stopped answering
    /// would block the main thread.
    private static func volumeName(ofRoot folder: URL) -> String? {
        guard folder.standardizedFileURL.path == "/" else { return nil }
        return startupVolumeName
    }

    private static let startupVolumeName: String? =
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
}
