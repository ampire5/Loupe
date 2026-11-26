import AppKit
@testable import HomeScreenKit
import ImageIO
import LoupeCore
import LoupeRender
import Testing
import UniformTypeIdentifiers
@testable import Loupe

@MainActor struct FileViewWindowTests {
    @Test func fileClipboardPreservesTheOrderedSelection() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/a/file 2.png"), URL(fileURLWithPath: "/a/folder", isDirectory: true)]
        FileViewCommands.copy(urls, to: board)
        #expect(board.pasteboardItems?.allSatisfy { $0.types.contains(.fileURL) } == true)
        #expect(FileViewCommands.clipboardFiles(from: board).map(\.path) == urls.map(\.path))
    }

    @Test func rangeSelectionUsesGroupCommandsAndRightClickOutsideUsesTheClickedItem() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let subfolder = folder.appendingPathComponent("subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
        let first = folder.appendingPathComponent("a.png")
        let last = folder.appendingPathComponent("b.png")
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let picture = try #require(context.makeImage())
        for photo in [first, last] {
            let destination = try #require(CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, picture, nil)
            try #require(CGImageDestinationFinalize(destination))
        }

        let reader = FileReader(threads: 1)
        let thumbnails = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let viewer = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader(), reader: reader),
                                            thumbnails: thumbnails, thumbnailsReady: nil,
                                            positions: FolderPositions(database: nil),
                                            folderSettings: FolderSettings(database: nil), recent: nil)
        let window = try #require(viewer.window)
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 700, height: 600))
        viewer.showHome(tab: .folders)
        viewer.showWindow(nil)
        defer { window.close() }

        let browser = try #require(viewer.browserView)
        browser.show(.folder(folder), selecting: subfolder.path)
        let deadline = ContinuousClock.now + .seconds(3)
        while !browser.hasCompleteListing, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(browser.hasCompleteListing)
        browser.chooseCardStyle(.list)
        browser.layoutSubtreeIfNeeded()
        browser.takeFocus()
        try #require(browser.selectedEntry?.name == subfolder.lastPathComponent)
        let extend = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                                   isARepeat: false, keyCode: 125))
        #expect(browser.handleKey(extend))
        let selection = browser.selectedEntries
        try #require(selection.map(\.name) == [subfolder.lastPathComponent, first.lastPathComponent])
        #expect(FileViewCommands.images(selection).map(\.lastPathComponent) == [first.lastPathComponent])
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        #expect(viewer.validateMenuItem(copy))
        #expect(window.firstResponder === browser)

        let source = try #require(browser.source)
        let group = source.menu(for: selection[1], in: browser.location).map(\.id)
        #expect(group.contains("copy-files"))
        #expect(group.contains("trash"))
        #expect(group.contains("batch-upscale"))
        #expect(!group.contains("rename"))
        let outside = try #require(browser.completeEntries.first { $0.name == last.lastPathComponent })
        let single = source.menu(for: outside, in: browser.location).map(\.id)
        #expect(single.contains("rename"))
        #expect(single.contains("batch-upscale"))
    }
}
