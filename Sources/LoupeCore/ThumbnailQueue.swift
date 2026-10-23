import Foundation

/// What one window needs thumbnails for: its folder, where it is in it and which strip cells are on screen.
public struct ThumbnailRequest: Sendable, Equatable {
    public var files: [URL]
    /// Index of the photo shown in the window. Outside `files.indices` means "no position": only `visible` counts.
    public var current: Int
    /// File indices shown by the visible strip cells, left to right (the strip samples a long folder, so these
    /// are not consecutive). Empty when the strip is hidden. Indices outside `files.indices` are ignored.
    public var visible: [Int]
    public var isKey: Bool
    /// How recently the window was key (`WindowRegistry.activityRank`): larger = more recently, 0 = never.
    public var lastActive: Int

    public init(files: [URL], current: Int, visible: [Int], isKey: Bool, lastActive: Int = 0) {
        self.files = files
        self.current = current
        self.visible = visible
        self.isKey = isKey
        self.lastActive = lastActive
    }

    /// `urls` with those in `inView` first, then the rest (the margin around the view), each in its order: the
    /// request's `visible` for a browser that shows photos in view and keeps a margin of them warm.
    public static func inViewFirst(_ urls: [URL], inView: Set<URL>) -> [URL] {
        urls.filter(inView.contains) + urls.filter { !inView.contains($0) }
    }
}

/// The order in which thumbnails get generated across windows. The user is looking at the key window's strip,
/// so its visible cells come first, then its photos spreading outward from the current one (the user is about to
/// scrub or step there), then the same two stages for the other windows, the one key most recently first; after them
/// all, the subtree walk's window (thumbs-ahead stage 5), which no one is looking at. One pass over the files with a Set
/// for duplicates: folders hold 10 000+ photos and several windows may show the same one.
public enum ThumbnailQueue {
    /// Files to generate, most urgent first. Each file appears once, at its first position; `skip` (thumbnails
    /// that already exist or are being made) never appears. `trailing` (the walk's window) goes after every request,
    /// its visible cells then outward from its current file, as a window's. `visibleOnly` (the user paused the work
    /// ahead): only the requests' visible cells, nothing outward and no `trailing`.
    public static func order(_ requests: [ThumbnailRequest], skip: Set<URL>, trailing: ThumbnailRequest? = nil,
                             visibleOnly: Bool = false) -> [URL] {
        // The key window(s) first, the others by how recently they were key; ties keep the order given (stable).
        let others = requests.enumerated().filter { !$0.element.isKey }
            .sorted { ($0.element.lastActive, $1.offset) > ($1.element.lastActive, $0.offset) }.map(\.element)
        let ranked = requests.filter(\.isKey) + others
        let keyCount = requests.filter(\.isKey).count

        var seen = skip
        var result: [URL] = []

        func add(_ file: URL) {
            if seen.insert(file).inserted { result.append(file) }
        }

        for group in [ranked[..<keyCount], ranked[keyCount...]] {
            for request in group {
                for index in request.visible where request.files.indices.contains(index) {
                    add(request.files[index])
                }
            }
            for request in group where !visibleOnly {
                outward(request, add)
            }
        }
        if let trailing, !visibleOnly {
            for index in trailing.visible where trailing.files.indices.contains(index) { add(trailing.files[index]) }
            outward(trailing, add)
        }
        return result
    }

    /// `current`, `current + 1`, `current - 1`, `current + 2`, … until both ends are passed.
    private static func outward(_ request: ThumbnailRequest, _ add: (URL) -> Void) {
        let files = request.files, current = request.current
        guard files.indices.contains(current) else { return }
        add(files[current])
        var distance = 1
        while current + distance < files.count || current - distance >= 0 {
            if current + distance < files.count { add(files[current + distance]) }
            if current - distance >= 0 { add(files[current - distance]) }
            distance += 1
        }
    }
}
