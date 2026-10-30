import AppKit
import Foundation
@testable import HomeScreenKit
import LoupeCore
import LoupeRender
import Testing
@testable import Loupe

@Suite(.serialized) @MainActor struct PhotosBrowserTests {
    @Test func browseBackAndHomeReturnToTheSamePhotosViewAndSelection() async {
        _ = NSApplication.shared
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
                                                thumbnailsReady: nil, positions: FolderPositions(database: nil),
                                                folderSettings: FolderSettings(database: nil), recent: nil,
                                                photosLibrary: AlbumsFixture())
        for action in [controller.browseFolder, controller.goBack, { _ in controller.showHome() }] {
            controller.open(.photos(album: "album-a", asset: "b"))
            #expect(await waitUntil { !controller.isShowingHome && controller.session.playlist?.current.flatMapAlbum == "album-a" })
            let selection = controller.session.playlist?.current.absoluteString
            action(nil)
            let browser = browser(in: controller.window?.contentView)
            #expect(browser?.location == .source(PhotosLocation.collection("album-a")))
            #expect(browser?.selection == selection)
        }
        controller.window?.close()
    }

    private func browser(in view: NSView?) -> HomeBrowserView? {
        guard let view else { return nil }
        if let home = view as? HomeView { return home.browser }
        return view.subviews.lazy.compactMap { browser(in: $0) }.first
    }
    @Test func libraryIsAvailableWithoutUserAlbumsAndIncludesUnfiledPhotos() async throws {
        let source = PhotosBrowserSource(library: LibraryFixture())
        var root: [BrowserEntry] = []
        for try await listing in source.list(PhotosLocation.root) { root = listing.entries }
        #expect(root.first?.id == "photos-collection:@library")
        #expect(root.first?.name == "Library")
        #expect(root.first?.leads == true)
        var photos: [BrowserEntry] = []
        for try await listing in source.list(PhotosLocation.collection("@library")) { photos = listing.entries }
        #expect(photos.map { PhotosLocation.asset(in: $0.url) } == ["album-photo", "unfiled-photo"])
        #expect(source.info(PhotosLocation.collection("@library")).title == "Library")
        var opened: OpenTarget?
        source.onOpen = { target, _ in opened = target }
        if let unfiled = photos.last { source.open(unfiled, how: .open) }
        #expect(opened == .photos(album: "@library", asset: "unfiled-photo"))
        source.stop()
    }
    @Test func permissionFailureIsExposedBeforeAnyAlbumRead() async {
        let fixture = AlbumsFixture(denied: true)
        let source = PhotosBrowserSource(library: fixture)
        do {
            for try await _ in source.list(PhotosLocation.root) {}
            Issue.record("A denied Photos source completed as an empty library")
        } catch PhotosLibraryError.permission {} catch { Issue.record("Unexpected permission error: \(error)") }
        #expect(fixture.collectionReads == 0)
        source.stop()
    }
    @Test func movingFromAlbumsToAnAlbumDoesNotCancelTheNewListing() async throws {
        let photos = PhotosBrowserSource(library: AlbumsFixture())
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let folders = FolderBrowserSource(thumbnails: thumbnails, places: BrowserPlaces(database: nil), settings: nil,
                                          positions: FolderPositions(database: nil), recent: nil, stores: [])
        let collections = CollectionSource(thumbnails: thumbnails, recent: { [] }, sessions: { [] }, stashPage: { nil })
        let home = LoupeHomeSource(folders: folders, collections: collections, hasStash: { false }, photos: photos)
        let root = BrowserLocation.source(PhotosLocation.root)
        for try await _ in home.list(root) {}
        let album = BrowserLocation.source(PhotosLocation.collection("album-a"))
        // HomeBrowserView subscribes to the new location before notifying its source of the move.
        let destination = home.list(album)
        home.moved(from: root, to: album)
        var count = 0
        for try await listing in destination { count += listing.entries.count }
        #expect(count == 2)
        photos.stop()
        folders.stop()
    }

    @Test func libraryChangesFollowTheSecondAlbumOpenedInTheSameViewer() async throws {
        _ = NSApplication.shared
        let library = AlbumsFixture()
        let cache = ImageCache(loader: MetalPyramidLoader())
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: cache, thumbnails: thumbnails, thumbnailsReady: nil,
                                                positions: FolderPositions(database: nil),
                                                folderSettings: FolderSettings(database: nil), recent: nil,
                                                photosLibrary: library)
        controller.open(.photos(album: "album-a", asset: "a"))
        #expect(await waitUntil { controller.session.playlist?.current.flatMapAlbum == "album-a" })
        controller.open(.photos(album: "album-b", asset: "a"))
        #expect(await waitUntil { controller.session.playlist?.current.flatMapAlbum == "album-b" })
        let before = controller.session.playlist?.current
        library.emitChange()
        #expect(await waitUntil { controller.session.playlist?.current != before })
        #expect(controller.session.playlist?.current.flatMapAlbum == "album-b")
        controller.window?.close()
    }

    @Test func leavingPhotosViewerCancelsItsCurrentRead() async {
        _ = NSApplication.shared
        let priority = PriorityCaptureReader()
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: priority)
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: cache, thumbnails: thumbnails, thumbnailsReady: nil,
                                                positions: FolderPositions(database: nil),
                                                folderSettings: FolderSettings(database: nil), recent: nil,
                                                photosLibrary: AlbumsFixture())
        let session = controller.session
        session.setActivity(active: true, visible: true, lastActive: 1)
        let url = PhotosLocation.assetURL(album: "album-a", asset: "a", revision: "1")
        session.openPhotos([url], current: url)
        #expect(await waitUntil { priority.latest?.isCurrent == true })
        controller.showHome(tab: .recent)
        #expect(await waitUntil { priority.wasCancelled || priority.latest?.isCurrent == false })
        controller.window?.close()
    }

    @Test func resumingAnInterruptedAlbumOpenKeepsTheRequestedAsset() async {
        _ = NSApplication.shared
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
                                                thumbnailsReady: nil, positions: FolderPositions(database: nil),
                                                folderSettings: FolderSettings(database: nil), recent: nil,
                                                photosLibrary: AlbumsFixture())
        controller.open(.photos(album: "album-a", asset: "a"))
        #expect(await waitUntil { controller.session.playlist?.current.flatMapAlbum == "album-a" })
        controller.open(.photos(album: "album-b", asset: "b"))
        controller.photosVisibilityChanged(false)
        controller.photosVisibilityChanged(true)
        #expect(await waitUntil { controller.session.playlist?.current.flatMapAlbum == "album-b" })
        #expect(controller.session.playlist.map(\.current).flatMap(PhotosLocation.asset(in:)) == "b")
        controller.window?.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_PHOTOS_UI_BENCH"] == "1"))
    func realBrowserRoundTripsAlbumsWithoutLosingOrder() async throws {
        let app = NSApplication.shared
        app.finishLaunching()
        let photos = PhotosBrowserSource(library: AlbumsFixture(count: 10_000))
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let folders = FolderBrowserSource(thumbnails: thumbnails, places: BrowserPlaces(database: nil), settings: nil,
                                          positions: FolderPositions(database: nil), recent: nil, stores: [])
        let collections = CollectionSource(thumbnails: thumbnails, recent: { [] }, sessions: { [] }, stashPage: { nil })
        let source = LoupeHomeSource(folders: folders, collections: collections, hasStash: { false }, photos: photos)
        let view = HomeView(source: source)
        source.view = view.browser
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 1100, height: 750),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        var received: BrowserLocation?
        var shown: [BrowserEntry] = []
        view.browser.onListingComplete = { location, entries in received = location; shown = entries }
        let root = BrowserLocation.source(PhotosLocation.root)
        let album = BrowserLocation.source(PhotosLocation.collection("album-a"))
        for round in 1...4 {
            for location in [root, album] {
                received = nil
                let start = ThreadCPU.milliseconds()
                view.browser.show(location, selecting: nil)
                #expect(await waitUntil { received == location })
                try await Task.sleep(for: .milliseconds(300))
                window.contentView?.layoutSubtreeIfNeeded()
                let ms = ThreadCPU.milliseconds() - start
                let label = location == root ? "albums" : "album-10000"
                print(String(format: "PHOTOS_UI round=%d page=%@ mainCPUms=%.3f", round, label, ms))
                #expect(shown.count == (location == root ? 2 : 10_000))
            }
        }
        view.browser.stop()
        photos.stop()
        folders.stop()
        window.close()
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_PHOTOS_UI_BENCH"] == "1"))
    func realViewerReturnsToPhotosLibraryWithTenThousandNamedImages() async throws {
        let app = NSApplication.shared
        app.finishLaunching()
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
                                                thumbnailsReady: nil, positions: FolderPositions(database: nil),
                                                folderSettings: FolderSettings(database: nil), recent: nil,
                                                photosLibrary: AlbumsFixture(count: 10_000), photosSorts: PhotosSortStore())
        controller.window?.makeKeyAndOrderFront(nil)
        controller.showHome(tab: .recent)
        let view = try #require(browser(in: controller.window?.contentView))
        view.show(.source(PhotosLocation.collection(PhotosLocation.library)), selecting: nil)
        try await Task.sleep(for: .milliseconds(300))
        for round in 1...4 {
            let openStart = ThreadCPU.milliseconds()
            controller.open(.photos(album: PhotosLocation.library, asset: "asset-9999"))
            #expect(await waitUntil {
                !controller.isShowingHome && controller.session.playlist.map(\.current).flatMap(PhotosLocation.asset(in:)) == "asset-9999"
            })
            try await Task.sleep(for: .milliseconds(300))
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let openCPU = ThreadCPU.milliseconds() - openStart
            let backStart = ThreadCPU.milliseconds()
            controller.browseFolder(nil)
            try await Task.sleep(for: .milliseconds(300))
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let backCPU = ThreadCPU.milliseconds() - backStart
            #expect(view.location == .source(PhotosLocation.collection(PhotosLocation.library)))
            #expect(view.selection == controller.session.playlist?.current.absoluteString)
            print(String(format: "PHOTOS_VIEWER round=%d open-mainCPUms=%.3f return-mainCPUms=%.3f", round, openCPU, backCPU))
        }
        controller.window?.close()
    }
}

private extension URL {
    var flatMapAlbum: String? { PhotosLocation.album(in: self) }
}

private final class AlbumsFixture: PhotosLibraryAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var version = 0
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    private let count: Int
    private let denied: Bool
    private var reads = 0
    var collectionReads: Int { lock.withLock { reads } }
    init(count: Int = 2, denied: Bool = false) { self.count = count; self.denied = denied }
    func authorize() async throws { if denied { throw PhotosLibraryError.permission } }
    func collections(in folder: String?) async throws -> [PhotosCollection] {
        lock.withLock { reads += 1 }
        return [PhotosCollection(id: "album-a", title: "Album", isFolder: false)]
    }
    func assets(in album: String) async throws -> [PhotosAsset] {
        let revision = lock.withLock { version }
        let modified = Date(timeIntervalSinceReferenceDate: Double(revision))
        return (0..<count).map { (index: Int) -> PhotosAsset in
            let id: String
            if index == 0 { id = "a" }
            else if index == 1 { id = "b" }
            else { id = "asset-\(index)" }
            let created = Date(timeIntervalSinceReferenceDate: Double(index))
            let filename = "Image-\(index).HEIC"
            return PhotosAsset(id: id, modified: modified, created: created, width: 2, height: 2, filename: filename)
        }
    }
    func cover(in album: String) async throws -> URL? { nil }
    func thumbnail(_ url: URL, pixels: Int) async throws -> CGImage? { nil }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) -> any PhotosChangeObservation {
        let id = UUID()
        lock.withLock { handlers[id] = changed }
        return FixtureObservation { [weak self] in self?.lock.withLock { self?.handlers[id] = nil } }
    }
    func emitChange() {
        let callbacks = lock.withLock { version += 1; return Array(handlers.values) }
        callbacks.forEach { $0() }
    }
}
private final class FixtureObservation: PhotosChangeObservation, @unchecked Sendable {
    let cancel: @Sendable () -> Void
    init(_ cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}

private struct LibraryFixture: PhotosLibraryAccess {
    func authorize() async throws {}
    func collections(in folder: String?) async throws -> [PhotosCollection] { [] }
    func assets(in album: String) async throws -> [PhotosAsset] {
        let ids = album == "@library" ? ["album-photo", "unfiled-photo"] : ["album-photo"]
        return ids.map { PhotosAsset(id: $0, modified: .distantPast, created: nil, width: 2, height: 2) }
    }
    func cover(in album: String) async throws -> URL? { nil }
    func thumbnail(_ url: URL, pixels: Int) async throws -> CGImage? { nil }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) -> any PhotosChangeObservation { FixtureObservation {} }
}

private final class PriorityCaptureReader: FileReading, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: ReadPriority?
    private var cancelled = false
    var latest: ReadPriority? { lock.withLock { captured } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
    func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes {
        lock.withLock { captured = priority }
        do { try await Task.sleep(for: .seconds(30)) }
        catch { lock.withLock { cancelled = true }; throw error }
        throw CancellationError()
    }
    func stamp(_ url: URL, priority: Int) async throws -> FileStamp { FileStamp(modified: .distantPast, size: 0) }
}
