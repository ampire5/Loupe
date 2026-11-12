import Foundation
import HomeScreenKit
import LoupeCore
import Testing
@testable import Loupe

@MainActor struct SidebarFavoritesTests {
    @Test(.timeLimit(.minutes(1))) func favoriteCommandsRefreshBothHomeSources() async throws {
        let places = BrowserPlaces(database: nil)
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let source = FolderBrowserSource(thumbnails: thumbnails, places: places, settings: nil,
                                         positions: FolderPositions(database: nil), recent: nil, stores: [])
        let other = FolderBrowserSource(thumbnails: thumbnails, places: places, settings: nil,
                                        positions: FolderPositions(database: nil), recent: nil, stores: [])
        defer { source.stop(); other.stop() }
        let folder = URL(fileURLWithPath: "/sample/folder", isDirectory: true)
        let row = HomeSidebarRow(id: folder.path, title: "folder", symbol: "folder",
                                 location: .folder(folder), expandable: true)
        let pinnedRow = HomeSidebarRow(id: folder.path, title: "folder", symbol: "pin",
                                       location: .folder(folder), isDimmed: true)
        let archive = URL(fileURLWithPath: "/sample/album.zip", isDirectory: false)
        let archiveRow = HomeSidebarRow(id: archive.path, title: "album.zip", symbol: "doc.zipper",
                                        location: .folder(archive))
        let entry = BrowserEntry(url: folder, name: "folder", kind: .folder)
        let changes = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let otherChanges = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        source.onPlacesChanged = { changes.continuation.yield(()) }
        other.onPlacesChanged = { otherChanges.continuation.yield(()) }
        var updates = changes.stream.makeAsyncIterator()
        var otherUpdates = otherChanges.stream.makeAsyncIterator()

        #expect(source.sidebarMenu(for: archiveRow).map(\.id) == ["reveal", "copyPath"])
        try #require(source.sidebarMenu(for: row).contains { $0.title == "Add to Favorites" })
        source.performSidebar("add-favorite", on: row)
        _ = await updates.next()
        _ = await otherUpdates.next()
        #expect(other.menu(for: entry, in: .places).contains { $0.title == "Remove from Favorites" })
        #expect(source.sidebarMenu(for: row).contains { $0.id == "remove-favorite" })
        #expect(source.sidebarMenu(for: pinnedRow).contains { $0.id == "remove-favorite" })

        source.performSidebar("remove-favorite", on: pinnedRow)
        _ = await updates.next()
        _ = await otherUpdates.next()
        #expect(!places.isPinned(folder))
        source.perform("add-favorite", on: entry, in: .places)
        _ = await otherUpdates.next()
        #expect(other.sidebarMenu(for: row).contains { $0.id == "remove-favorite" })
    }

    @Test(.timeLimit(.minutes(1))) func unavailableFavoriteRemainsInOrderAndRecoversOnReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-favorites-\(UUID())", isDirectory: true)
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let places = BrowserPlaces(database: nil)
        places.pin(missing)
        places.pin(directory)
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let folders = FolderBrowserSource(thumbnails: thumbnails, places: places, settings: nil,
                                          positions: FolderPositions(database: nil), recent: nil, stores: [])
        defer { folders.stop() }
        let collections = CollectionSource(thumbnails: thumbnails, recent: { [] }, sessions: { [] }, stashPage: { nil })
        let source = LoupeHomeSource(folders: folders, collections: collections, hasStash: { false })
        let changes = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        folders.onSidebarAvailabilityChanged = { changes.continuation.yield(()) }
        var updates = changes.stream.makeAsyncIterator()
        _ = await source.sidebar()
        _ = await updates.next()
        let sections = await source.sidebar()
        #expect(sections.map(\.id) == ["library", "favorites", "places"])
        let favorites = try #require(sections.first { $0.id == "favorites" })
        #expect(favorites.rows.map(\.id) == [missing.path, directory.path])
        #expect(favorites.rows.map(\.isDimmed) == [true, false])
        #expect(favorites.rows.map(\.expandable) == [false, true])
        #expect(sections.first { $0.id == "places" }?.rows.contains { $0.id == missing.path } == false)
        #expect(await source.places().suffix(2).map { $0.url.path } == [missing.path, directory.path])

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        _ = await source.sidebar()
        _ = await updates.next()
        let reloaded = try #require(await source.sidebar().first { $0.id == "favorites" })
        #expect(reloaded.rows.map(\.id) == [missing.path, directory.path])
        #expect(reloaded.rows.map(\.isDimmed) == [false, false])
    }

    @Test(.timeLimit(.minutes(1))) func reorderReturnsBeforeRefreshingCachedAvailability() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-favorite-reorder-\(UUID())", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let places = BrowserPlaces(database: nil)
        places.pin(root)
        places.pin(child)
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let folders = FolderBrowserSource(thumbnails: thumbnails, places: places, settings: nil,
                                          positions: FolderPositions(database: nil), recent: nil, stores: [])
        defer { folders.stop() }
        let collections = CollectionSource(thumbnails: thumbnails, recent: { [] }, sessions: { [] }, stashPage: { nil })
        let source = LoupeHomeSource(folders: folders, collections: collections, hasStash: { false })
        let changes = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        folders.onSidebarAvailabilityChanged = { changes.continuation.yield(()) }
        var updates = changes.stream.makeAsyncIterator()
        _ = await source.sidebar()
        _ = await updates.next()
        let initial = try #require(await source.sidebar().first { $0.id == "favorites" })
        #expect(initial.rows.map(\.isDimmed) == [false, true])

        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        places.movePin(child, before: root)
        let reordered = try #require(await source.sidebar().first { $0.id == "favorites" })
        #expect(reordered.rows.map(\.id) == [child.path, root.path])
        #expect(reordered.rows.map(\.isDimmed) == [true, false])
        _ = await updates.next()
        let refreshed = try #require(await source.sidebar().first { $0.id == "favorites" })
        #expect(refreshed.rows.map(\.id) == [child.path, root.path])
        #expect(refreshed.rows.map(\.isDimmed) == [false, false])
    }

    @Test(.timeLimit(.minutes(1))) func recentMenusOfferFavoritesOnlyForFolders() async throws {
        let places = BrowserPlaces(database: nil)
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let folders = FolderBrowserSource(thumbnails: thumbnails, places: places, settings: nil,
                                          positions: FolderPositions(database: nil), recent: nil, stores: [])
        defer { folders.stop() }
        let recent = RecentStore(database: nil)
        let folder = URL(fileURLWithPath: "/sample/folder", isDirectory: true)
        recent.entered(folder, kind: .folder, gallery: nil, title: nil, clearsGallery: true)
        recent.entered(URL(fileURLWithPath: "/sample/archive.zip", isDirectory: false),
                       kind: .archive, gallery: nil, title: nil, clearsGallery: true)
        recent.entered(URL(fileURLWithPath: "/sample/gallery", isDirectory: true),
                       kind: .folder, gallery: RecentGallery(id: "1", list: nil), title: nil, clearsGallery: false)
        let collections = CollectionSource(thumbnails: thumbnails, recent: { recent.shown(limit: 10) },
                                           sessions: { [] }, stashPage: { nil })
        let source = LoupeHomeSource(folders: folders, collections: collections, hasStash: { false })
        let location = BrowserLocation.source(HomeCollections.recent)
        var listings = source.list(location).makeAsyncIterator()
        let entries = try #require(try await listings.next()).entries

        let eligible = entries.filter { entry in
            source.menu(for: entry, in: location).contains { $0.id == "add-favorite" }
        }
        #expect(eligible.map { $0.url.path } == [folder.path])
        let entry = try #require(eligible.first)
        let changed = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        folders.onPlacesChanged = { changed.continuation.yield(()) }
        var updates = changed.stream.makeAsyncIterator()
        source.perform("add-favorite", on: entry, in: location)
        _ = await updates.next()
        #expect(places.pins() == [folder])
        #expect(source.menu(for: entry, in: location).contains { $0.id == "remove-favorite" })
    }
}
