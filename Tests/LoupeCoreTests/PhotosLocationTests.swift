import Foundation
import Testing
import HomeScreenModel
@testable import LoupeCore

@Suite struct PhotosLocationTests {
    @Test func identifiersAreNotFilesystemPaths() {
        let url = PhotosLocation.assetURL(album: "album/a +?#", asset: "asset/b +?#", revision: "edited")
        #expect(!url.isFileURL)
        #expect(PhotosLocation.album(in: url) == "album/a +?#")
        #expect(PhotosLocation.asset(in: url) == "asset/b +?#")
        #expect(PhotosLocation.asset(in: URL(fileURLWithPath: "/a/photo.jpg")) == nil)
        #expect(url != PhotosLocation.assetURL(album: "album/a +?#", asset: "asset/b +?#", revision: "original"))
        #expect(url.path != PhotosLocation.assetURL(album: "other", asset: "asset/b +?#", revision: "edited").path)
        #expect(url.path != PhotosLocation.assetURL(album: "album/a +?#", asset: "other", revision: "edited").path)
    }

    @Test func albumOrderSurvivesPagingAndResorting() {
        let files = ["z", "a", "m"].map { PhotosLocation.assetURL(album: "album", asset: $0, revision: "1") }
        var list = Playlist(ordered: files, current: files[1])!
        #expect(list.files == files)
        #expect(list.index == 1)
        let moved = list.move(by: 1)
        #expect(moved)
        #expect(list.current == files[2])
        let pastEnd = list.move(by: 1)
        #expect(!pastEnd)
        #expect(list.sorted(.standard).files == files)
        list.moveToFirst()
        #expect(list.current == files[0])
        let beforeStart = list.move(by: -1)
        #expect(!beforeStart)
        #expect(Playlist(ordered: [], current: files[0]) == nil)
    }

    @Test func revisionChangesPreserveSelectionAndDeletionClamps() {
        let before = ["a", "b", "c"].map { PhotosLocation.assetURL(album: "album", asset: $0, revision: "1") }
        let revised = ["a", "b", "c"].map { PhotosLocation.assetURL(album: "album", asset: $0, revision: "2") }
        let old = Playlist(ordered: before, current: before[1])!
        let replacement = Playlist(ordered: revised, current: revised[0])!
        #expect(old.replacing(with: replacement).current == revised[1])
        let deleted = Playlist(ordered: [revised[0]], current: revised[0])!
        #expect(old.replacing(with: deleted).current == revised[0])
    }

    @Test func photosRouteMatchesAlbumWithoutConfusingFileFolders() {
        let current = PhotosLocation.assetURL(album: "album", asset: "a", revision: "1")
        let tabs = [TabFacts(tab: 7, window: 1, current: current, folder: nil, stashGallery: nil, lastActive: 1)]
        let target = OpenTarget.photos(album: "album", asset: "b")
        let expected = PhotosLocation.assetURL(album: "album", asset: "b", revision: "")
        #expect(OpenRouter.route(target, tabs: tabs, front: 7, openIn: .tab) == .focus(tab: 7, open: expected))
        #expect(OpenRouter.route(target, tabs: tabs, front: 7, openIn: .tab, force: .tab) == .newTab(besideTab: 7))
        #expect(OpenRouter.route(.photos(album: "other", asset: "a"), tabs: tabs, front: 7, openIn: .tab) == .newTab(besideTab: 7))
    }

    @Test func reopeningTheSamePhotosAssetRefreshesItsCollectionOrder() {
        let current = PhotosLocation.assetURL(album: "album", asset: "a", revision: "1")
        let tabs = [TabFacts(tab: 7, window: 1, current: current, folder: nil, stashGallery: nil, lastActive: 1)]
        // Another Photos grid may have changed its shared sort while this viewer remained open.
        let open = PhotosLocation.assetURL(album: "album", asset: "a", revision: "")
        #expect(OpenRouter.route(.photos(album: "album", asset: "a"), tabs: tabs, front: 7, openIn: .tab)
                == .focus(tab: 7, open: open))
    }

    @Test func gridRetainsNamesDatesAndUniqueIdentitiesForSorting() {
        let assets = (0..<12).map { i in
            PhotosAsset(id: "asset-\(12 - i)", modified: .distantPast, created: Date(timeIntervalSince1970: Double(12 - i)),
                        width: 1200, height: 800, filename: "IMG_\(12 - i).HEIC")
        }
        let entries = PhotosAlbumListing.entries(assets, album: "album")
        #expect(BrowserSort.standard.order(entries).first?.name == "IMG_1.HEIC")
        #expect(BrowserSort(key: .date, ascending: false).order(entries).first?.name == "IMG_12.HEIC")
        #expect(entries.map(\.name) == assets.map(\.filename))
        #expect(entries.allSatisfy { !$0.canTrash && !$0.canRename })
        #expect(Set(entries.map(\.id)).count == 12)
    }
}
