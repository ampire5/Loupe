import Foundation
import HomeScreenKit
import LoupeCore
import Testing
@testable import Loupe

@MainActor struct SidebarPinTests {
    @Test(.timeLimit(.minutes(1))) func folderPinIsSharedBetweenTheTreeAndGrid() async throws {
        let places = BrowserPlaces(database: nil)
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let source = FolderBrowserSource(thumbnails: thumbnails, places: places, settings: nil,
                                         positions: FolderPositions(database: nil), recent: nil, stores: [])
        defer { source.stop() }
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
        source.onPlacesChanged = { changes.continuation.yield(()) }
        var updates = changes.stream.makeAsyncIterator()

        #expect(source.sidebarMenu(for: archiveRow).map(\.id) == ["reveal", "copyPath"])
        try #require(source.sidebarMenu(for: row).contains { $0.id == "pin" })
        source.performSidebar("pin", on: row)
        _ = await updates.next()
        #expect(source.menu(for: entry, in: .places).contains { $0.id == "unpin" })
        #expect(source.sidebarMenu(for: row).contains { $0.id == "unpin" })
        #expect(source.sidebarMenu(for: pinnedRow).contains { $0.id == "unpin" })

        source.performSidebar("unpin", on: pinnedRow)
        _ = await updates.next()
        #expect(!places.isPinned(folder))
        #expect(source.menu(for: entry, in: .places).contains { $0.id == "pin" })
    }
}
