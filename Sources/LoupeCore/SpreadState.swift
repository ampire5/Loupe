import CoreGraphics
import Foundation

/// A viewer's two-page state (spread spec 2026-10-23): the current folder's rules, the page sizes it knows, the plan
/// and the current photo's companion. Pure: `ViewerSession` feeds it the playlist, the store's aspects, the headers it
/// reads and the view's size, and makes the cache calls and the layout itself. The plan is rebuilt (O(n)) only when one
/// of its inputs changes: the playlist, the rules, a page size that pairs otherwise; never per frame or event.
public struct SpreadState: Sendable {
    /// The rules of `folder`, the current photo's folder when they were last asked.
    public private(set) var rules = SpreadRules.off
    public private(set) var folder: URL?
    /// How steps go and which page pairs with the current one.
    public private(set) var navigation = SpreadNavigation(plan: nil, showsTwo: false)
    /// The view is wide enough for two pages (`SpreadLayout.showsTwo`), as of the last view size.
    public private(set) var showsTwo = false
    /// The other page of the current photo's pair (playlist index and file), nil for one page.
    public private(set) var companionIndex: Int?
    public private(set) var companionURL: URL?
    /// The playlist the plan was built for ([] while the folder shows one page).
    private var planFiles: [URL] = []
    /// The headers' sizes (as shown) of the pages read in this folder, two pages on or off: the photo on screen when
    /// `D` turns them on is planned at its real size, not taken for portrait while the store has no aspect for it.
    private var headers: [URL: PixelSize] = [:]

    public init() {}

    /// The current folder's rules asked again (`D`, `⌥D`, a reload). True when they changed: the plan is rebuilt.
    public mutating func setRules(_ rules: SpreadRules, folder: URL) -> Bool {
        self.folder = folder
        guard rules != self.rules else { return false }
        self.rules = rules
        return true
    }

    /// Brings the state up to the playlist (`files`, the current photo at `index`), the known sizes and the view: the
    /// folder's rules (`rules`) when the current folder changed, the plan when one of its inputs changed or `rebuild`
    /// (`aspects`: the store's, parallel to the files), then the companion. True when the companion changed.
    @discardableResult
    public mutating func update(files: [URL], index: Int?, rebuild: Bool = false, rules: (URL) -> SpreadRules,
                                aspects: ([URL]) -> [Double?]) -> Bool {
        var rebuild = rebuild
        if let index, files.indices.contains(index), files[index].deletingLastPathComponent() != folder {
            folder = files[index].deletingLastPathComponent()
            headers = [:]
            let rules = rules(files[index])
            rebuild = rebuild || rules != self.rules
            self.rules = rules
        }
        let files = self.rules.on ? files : []
        var plan = navigation.plan
        if rebuild || files != planFiles {   // the same list compares in O(1) (one storage)
            planFiles = files
            plan = files.isEmpty ? nil
                : SpreadPlan(sizes: SpreadSizes.sizes(files: files, aspects: aspects(files), headers: headers),
                             options: self.rules.options)
        }
        navigation = SpreadNavigation(plan: plan, showsTwo: showsTwo)
        let companion = index.flatMap { navigation.companion(of: $0) }
        let url = companion.flatMap { files.indices.contains($0) ? files[$0] : nil }
        let changed = companion != companionIndex || url != companionURL
        companionIndex = companion
        companionURL = url
        return changed
    }

    /// A page's header is in (`size` as shown; `index` its place in the playlist, `aspects` the store's): its size
    /// joins the known ones. True when two pages are on and it pairs the page otherwise than the plan did (a page taken
    /// for portrait is landscape): the plan is to be rebuilt.
    public mutating func note(_ url: URL, size: PixelSize, at index: Int?, aspects: [Double?]) -> Bool {
        let old = headers[url]
        guard old != size else { return false }
        headers[url] = size
        guard rules.on, rules.options.landscapeAlone, let index, planFiles.indices.contains(index),
              planFiles[index] == url else { return false }
        let aspect = index < aspects.count ? aspects[index] : nil
        return SpreadSizes.changesPairing(from: old ?? aspect.flatMap(SpreadSizes.size(aspect:)), to: size,
                                          ratio: rules.options.wideRatio)
    }

    /// The view's size: true when it crossed `SpreadLayout.showsTwo` while two pages are on, so the pair follows.
    public mutating func setViewSize(_ size: CGSize) -> Bool {
        let two = SpreadLayout.showsTwo(viewSize: size)
        guard two != showsTwo else { return false }
        showsTwo = two
        return rules.on
    }

    /// `exif-orientation` changed: the sizes read at the old orientation are measured anew.
    public mutating func forgetSizes() {
        headers = [:]
    }
}
