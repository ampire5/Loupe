import AppKit
import Testing
import LoupeCore
import LoupeRender
@testable import Loupe

@Suite(.serialized) @MainActor struct SlotStatsLayoutTests {
    @Test func slotsStayBelowVisibleStatsAndReclaimTheTopWhenHidden() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["viewerToolbar", "statsMode", "fullScreenStatus", "fullScreen"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "viewerToolbar")
        defaults.set("compact", forKey: "statsMode")
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
            thumbnailsReady: nil, positions: FolderPositions(database: nil), folderSettings: FolderSettings(database: nil), recent: nil)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let bar = try #require(root.subviews.compactMap { $0 as? StatsBar }.first)
        let area = try #require(root.subviews.compactMap { $0 as? SlotOverlayArea }.first)
        let photo = try #require(root.subviews.compactMap { $0 as? ViewerView }.first)
        for fullScreen in [false, true] {
            if fullScreen {
                defaults.set(true, forKey: "fullScreenStatus")
                NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
            }
            for rows in [1, 2] {
                var config = Config(); #expect(config.set("stats-bar-rows", String(rows)) == .ok)
                bar.apply(config)
                root.needsLayout = true; root.layoutSubtreeIfNeeded()
                #expect(!bar.isHidden)
                #expect(area.frame.maxY <= bar.frame.minY + 0.5)
                #expect(abs(area.frame.maxY - bar.frame.minY) < 0.5)
                #expect(photo.frame.maxY > bar.frame.minY) // Only panels move below floating stats.
            }
            controller.toggleStatsBar(nil)
            root.layoutSubtreeIfNeeded()
            #expect(bar.isHidden)
            #expect(abs(area.frame.maxY - photo.frame.maxY) < 0.5)
            controller.toggleStatsBar(nil)
            root.layoutSubtreeIfNeeded()
            #expect(!bar.isHidden)
            #expect(abs(area.frame.maxY - bar.frame.minY) < 0.5)
        }
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
    }
}
