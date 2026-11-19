import AppKit
@testable import HomeScreenKit
import LoupeCore
import LoupeRender
import Testing
@testable import Loupe

@MainActor @Suite(.serialized) struct RecursiveViewerTests {
    @Test func openingFromFileViewStepsAcrossSubfoldersInGridOrder() async throws {
        let app = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = root.appendingPathComponent("A/02.png")
        let next = root.appendingPathComponent("B/01.png")
        let excluded = root.appendingPathComponent("B/extra.png")
        defer { try? FileManager.default.removeItem(at: root) }
        let pixel = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        for file in [first, next, excluded] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pixel.write(to: file)
        }

        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let registry = WindowRegistry()
        let controller = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
                                                thumbnailsReady: nil, positions: FolderPositions(database: nil),
                                                folderSettings: FolderSettings(database: nil), recent: nil)
        registry.add(controller)
        defer { controller.window?.close() }
        controller.showHome(tab: .folders)
        let browser = try #require(controller.window?.firstResponder as? HomeBrowserView)
        browser.show(.folder(root), selecting: first.path)
        browser.sortKeyChosen(.name) // Descending: A/02 then B/01.
        let toolbar = browser.nsToolbar
        let recursive = try #require(toolbar.delegate?.toolbar?(
            toolbar, itemForItemIdentifier: NSToolbarItem.Identifier("home.recursive"), willBeInsertedIntoToolbar: false))
        let action = try #require(recursive.action)
        try #require(app.sendAction(action, to: recursive.target, from: recursive))
        try #require(browser.includesSubfolders)
        browser.filterText = "0"
        for _ in 0..<100 where browser.selectedEntry?.url != first {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(browser.selectedEntry?.url == first)

        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        browser.keyDown(with: enter)

        let session = controller.session
        try #require(session.playlist?.recursiveRoot?.path == root.path)
        for _ in 0..<100 where session.playlist?.files != [first, next] {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.playlist?.files == [first, next])
        #expect(session.playlist?.current == first)
        #expect(session.go(by: 1))
        #expect(session.playlist?.current == next)
        #expect(!session.go(by: 1))
        #expect(session.go(by: -1))
        #expect(session.playlist?.current == first)
        #expect(session.go(by: 1))
        controller.browseFolder(nil)
        #expect(browser.location == .folder(root))
        #expect(browser.includesSubfolders)
        #expect(browser.selection == next.path)
    }
}
