import AppKit
import HomeScreenKit
import LoupeCore
import LoupeRender
import Testing
@testable import Loupe

@Suite(.serialized) @MainActor struct PhotosPresentationTests {
    @Test func sourceOffersNameAndDateSortsAndUsesOriginalFilenames() async throws {
        let sorts = PhotosSortStore()
        let photos = PhotosBrowserSource(library: NamedPhotosFixture(), sorts: sorts)
        let source = PhotosLocation.collection(PhotosLocation.library)
        #expect(photos.info(source).sortKeys == [.name, .date])
        var entries: [BrowserEntry] = []
        for try await listing in photos.list(source) { entries = listing.entries }
        #expect(entries.map(\.name) == ["IMG_10.HEIC", "IMG_2.PNG", "IMG_10.HEIC"])
        #expect(entries.map { $0.url.lastPathComponent } == entries.map(\.name))
        #expect(Set(entries.map(\.id)).count == 3)
        #expect(photos.sort(for: source).order(entries).map(\.name) == ["IMG_2.PNG", "IMG_10.HEIC", "IMG_10.HEIC"])
        photos.setSort(BrowserSort(key: .name, ascending: false), for: source)
        #expect(photos.sort(for: source).order(entries).map(\.name) == ["IMG_10.HEIC", "IMG_10.HEIC", "IMG_2.PNG"])
        photos.stop()
    }

    @Test func viewerUsesTheSameSortAsTheGridAndPreservesTheSelectedPhoto() async {
        _ = NSApplication.shared
        let sorts = PhotosSortStore()
        let source = PhotosLocation.collection(PhotosLocation.library)
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
                                                thumbnailsReady: nil, positions: FolderPositions(database: nil),
                                                folderSettings: FolderSettings(database: nil), recent: nil,
                                                photosLibrary: NamedPhotosFixture(), photosSorts: sorts)
        for (sort, expected) in [(BrowserSort(key: .name, ascending: true), ["b", "a", "c"]),
                                  (BrowserSort(key: .date, ascending: false), ["a", "c", "b"])] {
            sorts.setSort(sort, for: source)
            controller.open(.photos(album: PhotosLocation.library, asset: "c"))
            // Another window changes its choice while this window fetches metadata.
            sorts.setSort(BrowserSort(key: .name, ascending: false), for: source)
            #expect(await waitUntil {
                controller.session.playlist?.files.compactMap(PhotosLocation.asset(in:)) == expected
            })
            #expect(controller.session.playlist.map(\.current).flatMap(PhotosLocation.asset(in:)) == "c")
        }
        controller.window?.close()
    }

    @Test func openingFromEitherGridUsesThatGridsDisplayedSort() async throws {
        let sorts = PhotosSortStore()
        let first = PhotosBrowserSource(library: NamedPhotosFixture(), sorts: sorts)
        let second = PhotosBrowserSource(library: NamedPhotosFixture(), sorts: sorts)
        let source = PhotosLocation.collection(PhotosLocation.library)
        let chronological = first.sort(for: source)
        second.setSort(BrowserSort(key: .name, ascending: false), for: source)
        var entries: [BrowserEntry] = []
        for try await listing in first.list(source) { entries = listing.entries }
        let entry = try #require(entries.first)
        var opened = false
        first.onOpen = { _, _ in
            opened = true
            #expect(sorts.sort(for: source) == chronological)
        }
        first.open(entry, how: .open)
        #expect(opened)
        first.stop()
        second.stop()
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private struct NamedPhotosFixture: PhotosLibraryAccess {
    func authorize() async throws {}
    func collections(in folder: String?) async throws -> [PhotosCollection] { [] }
    func assets(in album: String) async throws -> [PhotosAsset] {
        [("a", "IMG_10.HEIC", 3.0), ("b", "IMG_2.PNG", 1.0), ("c", "IMG_10.HEIC", 2.0)].map { id, name, date in
            PhotosAsset(id: id, modified: .distantPast, created: Date(timeIntervalSinceReferenceDate: date),
                        width: 16, height: 16, filename: name)
        }
    }
    func cover(in album: String) async throws -> URL? { nil }
    func thumbnail(_ url: URL, pixels: Int) async throws -> CGImage? { nil }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) -> any PhotosChangeObservation { NamedObservation() }
}
private final class NamedObservation: PhotosChangeObservation, @unchecked Sendable {}
