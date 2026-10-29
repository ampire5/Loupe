import Foundation
import LoupeCore

extension ViewerSession {
    /// What the session says about the photo it is on, for the toolbar's status and the stats bar alike. A step never
    /// takes the words away: the name and the place are the new photo's at once, and while it loads the facts and the
    /// decode time of the photo still on screen stay, `stale` (`entry` is that photo until the new one qualifies), so the
    /// bar changes its text and nothing in it appears or goes. A news item about the folder stands in the place of the folder's name; the failure
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
            var shown = (info: info, timings: entry.timings, url: entry.url)
            if current, shownLayout != nil, pages?.second != nil,
               let other = shownCompanion, let otherInfo = other.info,
               StatsLine.factsOfCompanion(current: list.index, first: index, companionRead: other.failure == nil) {
                // The first page's facts in reading order, whichever page is current.
                shown = (otherInfo, other.timings, other.url)
            }
            let facts = ImageStatus.facts(index: index, companion: pages?.second, count: list.files.count,
                                          counted: folderCounted, info: shown.info, applyingOrientation: appliesOrientation,
                                          transform: zoomTarget ?? transform,   // a zoom animation's target
                                          photo: photoFacts[shown.url], carry: zoomRules(list.current).carry,
                                          subject: subjectZoom, framing: browseIndicator(shown.url),
                                          detectorMode: zoomRules(list.current).detector?.name)
            // The facts of the photo before stay while the new one loads (the views grey them when the load is felt).
            let rules = zoomRules(list.current)
            let zoom = StatsLine.modeText(zoomTarget ?? transform, carry: rules.carry)
            let boxes = subjectBoxes(shown.url)
            let group = boxes.flatMap { boxes in
                browse.chain(rules.chain).first { SubjectFraming.composition(boxes, kind: $0, options: rules.composition) != nil }
            }
            let modeText = smartZoom.mode == .off ? "Manual · \(zoom)"
                : "SmartZoom · \(smartZoom.mode == .frame ? "Auto" : "Pan") · \(rules.detector?.name ?? "Vision") · \(group?.title ?? (boxes == nil ? "Looking for subjects…" : "No complete group")) · \(zoom)"
            status.facts = facts.map { $0.kind == .zoom ? ImageStatus.Fact(.zoom, modeText, tone: $0.tone) : $0 }
            status.stale = !current
            // Its EXIF is asked when the step is made (for `status.photo`) and is in a moment after the pixels; the photo
            // before was asked when it was the current one (a fast step leaves it on screen before its EXIF is in).
            if shown.url == list.files[index] || !current, photoFacts[shown.url] == nil { status.pending = [.exposure] }
            status.decodeMilliseconds = (shown.timings.fullMs ?? shown.timings.previewMs).map { Int($0.rounded()) }
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

    /// The share of the window the framed target takes on screen (`⇧M`), nil when nothing is framed.
    func framedSize(_ url: URL) -> Double? { browseIndicator(url)?.size }

    /// Under framing while browsing the zoom is named by what it looks at and how big that is (`BrowseFraming.indicator`).
    private func browseIndicator(_ url: URL) -> (name: String, size: Double)? {
        let rules = zoomRules(url)
        guard !subjectZoom, rules.stepZoom == .subject, let boxes = subjectBoxes(url) else { return nil }
        for kind in browse.chain(rules.chain) {
            if let c = SubjectFraming.composition(boxes, kind: kind, options: rules.composition) {
                return (kind.title, BrowseFraming.size(zoomTarget ?? transform, frame: c.frame))
            }
        }
        return nil
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
