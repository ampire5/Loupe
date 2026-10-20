import Foundation
import Testing
@testable import LoupeCore

/// Where an open goes (windows-and-tabs spec §2.2): an already-open tab, a new tab, a new window, or the current tab.
@Suite struct OpenRouterTests {
    private func u(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func tab(_ id: Int, window: Int = 1, current: String? = nil, folder: String? = nil,
                     gallery: String? = nil, active: Int = 0) -> TabFacts {
        TabFacts(tab: id, window: window, current: current.map(u), folder: folder.map(u),
                 stashGallery: gallery, lastActive: active)
    }

    private func route(_ target: OpenTarget, _ tabs: [TabFacts], front: Int? = 1, openIn: OpenIn = .tab,
                       force: OpenForce? = nil) -> OpenDecision {
        OpenRouter.route(target, tabs: tabs, front: front, openIn: openIn, force: force)
    }

    @Test func sameFileFocuses() {
        let tabs = [tab(1, current: "/a/1.jpg", folder: "/a"), tab(2, current: "/b/2.jpg", folder: "/b")]
        #expect(route(.file(u("/b/2.jpg")), tabs) == .focus(tab: 2, open: nil))
    }

    @Test func sameFolderOpensFile() {
        let tabs = [tab(1, current: "/a/1.jpg", folder: "/a")]
        #expect(route(.file(u("/a/3.jpg")), tabs) == .focus(tab: 1, open: u("/a/3.jpg")))
    }

    @Test func zipEntryMatchesArchiveTab() {
        let tabs = [tab(1, current: "/v/G.zip/01.jpg", folder: "/v/G.zip")]
        let entry = u("/v/G.zip/caps\u{2215}02.jpg")
        #expect(route(.file(entry), tabs) == .focus(tab: 1, open: entry))
        #expect(OpenRouter.folder(of: entry).path == "/v/G.zip")
    }

    @Test func openingZipMatchesItsTab() {
        let tabs = [tab(1, current: "/v/G.zip/01.jpg", folder: "/v/G.zip")]
        #expect(route(.file(u("/v/G.zip")), tabs) == .focus(tab: 1, open: nil))
        #expect(OpenRouter.folder(of: u("/v/G.zip")).path == "/v/G.zip")
    }

    @Test func openingFolderMatchesItsTab() {
        let tabs = [tab(1, current: "/a/b/1.jpg", folder: "/a/b")]
        #expect(route(.folder(u("/a/b")), tabs) == .focus(tab: 1, open: nil))
    }

    @Test func galleryById() {
        let tabs = [tab(1, gallery: "g1"), tab(2, gallery: "g2")]
        #expect(route(.stashGallery(id: "g2"), tabs) == .focus(tab: 2, open: nil))
        #expect(route(.stashGallery(id: "g3"), tabs) == .newTab(besideTab: 1))
    }

    @Test func latestOfSeveral() {
        let tabs = [tab(1, current: "/a/1.jpg", folder: "/a", active: 5),
                    tab(2, current: "/a/2.jpg", folder: "/a", active: 9),
                    tab(3, current: "/a/3.jpg", folder: "/a", active: 7)]
        #expect(route(.file(u("/a/4.jpg")), tabs) == .focus(tab: 2, open: u("/a/4.jpg")))
        // the same file beats a more recent same-folder tab
        #expect(route(.file(u("/a/3.jpg")), tabs) == .focus(tab: 3, open: nil))
    }

    @Test func newTabByDefault() {
        let tabs = [tab(1, window: 4, current: "/a/1.jpg", folder: "/a")]
        #expect(route(.file(u("/z/9.jpg")), tabs, front: 1) == .newTab(besideTab: 1))
    }

    @Test func windowWhenAsked() {
        let tabs = [tab(1, current: "/a/1.jpg", folder: "/a")]
        #expect(route(.file(u("/z/9.jpg")), tabs, openIn: .window) == .newWindow)
    }

    @Test func replaceWhenAsked() {
        let tabs = [tab(1, current: "/a/1.jpg", folder: "/a")]
        #expect(route(.file(u("/z/9.jpg")), tabs, openIn: .replace) == .replace(tab: 1))
    }

    @Test func noWindowMeansNewWindow() {
        for openIn in [OpenIn.tab, .window, .replace] {
            #expect(route(.file(u("/z/9.jpg")), [], front: nil, openIn: openIn) == .newWindow)
        }
    }

    @Test func commandClickSkipsMatch() {
        let tabs = [tab(1, current: "/a/1.jpg", folder: "/a")]
        #expect(route(.file(u("/a/1.jpg")), tabs, force: .tab) == .newTab(besideTab: 1))
    }

    @Test func newTabFlagForcesATab() {
        let tabs = [tab(1, current: "/a/1.jpg", folder: "/a")]
        for openIn in [OpenIn.tab, .window, .replace] {
            #expect(route(.stashGallery(id: "g"), tabs, openIn: openIn, force: .tab) == .newTab(besideTab: 1))
        }
        #expect(route(.stashGallery(id: "g"), [], front: nil, openIn: .window, force: .tab) == .newWindow)
    }

    /// ⇧-click in Stash, File › Open in New Window: a window whatever is open and whatever `open-in` says.
    @Test func windowForceSkipsMatch() {
        let tabs = [tab(1, current: "/a/1.jpg", folder: "/a")]
        for openIn in [OpenIn.tab, .window, .replace] {
            #expect(route(.file(u("/a/1.jpg")), tabs, openIn: openIn, force: .window) == .newWindow)
            #expect(route(.folder(u("/a")), tabs, openIn: openIn, force: .window) == .newWindow)
        }
        #expect(route(.stashGallery(id: "g"), [], front: nil, force: .window) == .newWindow)
    }

    @Test func tabShowingStashIsNotAMatch() {
        let tabs = [tab(1, current: nil, folder: nil, gallery: nil)]
        #expect(route(.file(u("/a/1.jpg")), tabs) == .newTab(besideTab: 1))
    }

    @Test func standardizedPathsMatch() {
        let tabs = [tab(1, current: "/a/1.jpg", folder: "/a")]
        #expect(route(.file(u("/a/x/../1.jpg")), tabs) == .focus(tab: 1, open: nil))
    }

    @Test func folderWithNoTabOpensNew() {
        let tabs = [tab(1, current: "/v/1.jpg", folder: "/v")]
        #expect(route(.folder(u("/v/X")), tabs) == .newTab(besideTab: 1))
        #expect(route(.folder(u("/v/X")), tabs, openIn: .window) == .newWindow)
        #expect(route(.folder(u("/v/X")), tabs, openIn: .replace) == .replace(tab: 1))
    }

    @Test func folderThatIsATabsFolderFocuses() {
        let tabs = [tab(1, current: "/v/X/1.jpg", folder: "/v/X", active: 2), tab(2, current: "/v/2.jpg", folder: "/v")]
        #expect(route(.folder(u("/v/X")), tabs) == .focus(tab: 1, open: nil))
        #expect(route(.folder(u("/v/X")), tabs, force: .tab) == .newTab(besideTab: 1))
    }

    @Test func zipBesideParentTabIsNew() {
        let tabs = [tab(1, current: "/v/1.jpg", folder: "/v")]
        #expect(route(.file(u("/v/G.zip")), tabs) == .newTab(besideTab: 1))
    }

    @Test func tiesGoToTheFirstTab() {
        let tabs = [tab(1, current: "/a/1.jpg", folder: "/a"), tab(2, current: "/a/2.jpg", folder: "/a")]
        #expect(route(.file(u("/a/3.jpg")), tabs) == .focus(tab: 1, open: u("/a/3.jpg")))
    }

    @Test func firstPerFolderKeepsOrder() {
        let targets: [OpenTarget] = [.file(u("/a/1.jpg")), .file(u("/b/1.jpg")), .file(u("/a/2.jpg"))]
        #expect(OpenRouter.firstPerFolder(targets) == [.file(u("/a/1.jpg")), .file(u("/b/1.jpg"))])
        let zipped: [OpenTarget] = [.file(u("/v/G.zip/01.jpg")), .file(u("/v/G.zip/02.jpg")), .file(u("/v/G.zip"))]
        #expect(OpenRouter.firstPerFolder(zipped) == [.file(u("/v/G.zip/01.jpg"))])
    }

    @Test func siblingFoldersBothKept() {
        let targets: [OpenTarget] = [.folder(u("/a/b")), .folder(u("/a/c")), .folder(u("/a/b")), .stashGallery(id: "g")]
        #expect(OpenRouter.firstPerFolder(targets) == [.folder(u("/a/b")), .folder(u("/a/c")), .stashGallery(id: "g")])
    }
}
