import AppKit
@testable import HomeScreenKit
import LoupeCore
import LoupeRender
import Testing
@testable import Loupe

@MainActor @Suite(.serialized) struct SessionWindowTests {
    @Test func deletingInAnotherWindowWhileRenameIsOpenRefreshesBothSessionLists() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(database: try StateDatabase(directory: directory))
        let snapshot = SessionSnapshot(windows: [.init(frame: .zero, screen: nil, fullScreen: false, selected: 0,
                                                        tabs: [.home(.recent)])])
        #expect(await store.save(snapshot, name: "Shared session") == .saved)
        let saved = try #require(await store.all().first)
        let entry = try #require(HomeCollections.sessionEntries([saved]).first)

        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let cache = ImageCache(loader: MetalPyramidLoader())
        let registry = WindowRegistry()
        registry.sessions = store
        func makeViewer(column: Int) -> ViewerWindowController {
            let viewer = ViewerWindowController(cache: cache, thumbnails: thumbnails, thumbnailsReady: nil,
                                                positions: FolderPositions(database: nil),
                                                folderSettings: FolderSettings(database: nil), recent: nil)
            registry.add(viewer)
            if let window = viewer.window, let screen = NSScreen.main?.visibleFrame {
                window.tabbingMode = .disallowed
                let width = min(screen.width / 2, 650)
                window.setFrame(NSRect(x: screen.minX + CGFloat(column) * width, y: screen.minY,
                                       width: width, height: min(screen.height, 620)), display: false)
            }
            viewer.showHome(tab: .sessions)
            viewer.showWindow(nil)
            return viewer
        }
        let first = makeViewer(column: 0), second = makeViewer(column: 1)
        defer {
            registry.isQuitting = true
            second.window?.close()
            first.window?.close()
        }
        let firstWindow = try #require(first.window)
        let secondWindow = try #require(second.window)
        let firstList = try #require(first.browserView)
        let secondList = try #require(second.browserView)
        try await waitUntil("both Sessions lists contain the original card") {
            firstList.completeEntries.contains { $0.id == entry.id }
                && secondList.completeEntries.contains { $0.id == entry.id }
        }

        firstList.source?.perform("rename", on: entry, in: firstList.location)
        try await waitUntil("the Rename sheet opens") { firstWindow.attachedSheet != nil }
        let firstSheet = try #require(firstWindow.attachedSheet)
        let renameText = try #require(views(in: firstSheet.contentView).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        renameText.stringValue = "Renamed"

        secondList.source?.perform("delete", on: entry, in: secondList.location)
        try await waitUntil("the Delete sheet opens") { secondWindow.attachedSheet != nil }
        try confirm("Delete", in: secondWindow)

        try await waitUntil("the deleted card disappears") { !secondList.completeEntries.contains { $0.id == entry.id } }
        #expect(firstWindow.attachedSheet === firstSheet)
        try confirm("OK", in: firstWindow)
        try await waitUntil("the missing session alert appears") {
            views(in: firstWindow.attachedSheet?.contentView).contains {
                ($0 as? NSTextField)?.stringValue == "This session no longer exists."
            }
        }
        try confirm("OK", in: firstWindow)
        try await waitUntil("both lists are empty after the alert closes") {
            firstWindow.attachedSheet == nil
                && firstList.hasCompleteListing && firstList.completeEntries.isEmpty
                && secondList.hasCompleteListing && secondList.completeEntries.isEmpty
        }
        first.hideHome()
        first.showHome(tab: .sessions)
        try await waitUntil("reopening Sessions leaves it empty") {
            first.browserView?.hasCompleteListing == true && first.browserView?.completeEntries.isEmpty == true
        }
        #expect(await store.all().isEmpty)
    }

    private func confirm(_ title: String, in window: NSWindow) throws {
        let button = try #require(views(in: window.attachedSheet?.contentView).compactMap { $0 as? NSButton }
            .first { $0.title == title })
        button.performClick(nil)
    }

    private func views(in root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { views(in: $0) }
    }

    private func waitUntil(_ phase: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "\(phase)")
    }
}
