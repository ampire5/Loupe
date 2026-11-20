import AppKit
import Foundation
import LoupeRender
import Testing
@testable import LoupeCore
@testable import Loupe

@MainActor @Suite(.serialized) struct WebImageViewerTests {
    @Test func doubleClickReturnsToTheWebImagesSource() async throws {
        _ = NSApplication.shared
        let oldServer = WebImagesPreferences.server
        let server = try #require(URL(string: "http://127.0.0.1:9"))
        WebImagesPreferences.setServer(server)
        defer { WebImagesPreferences.setServer(oldServer) }
        let client = SearXNGClient(baseURL: server) { _ in
            (Data(#"{"results":[{"img_src":"http://127.0.0.1:9/image.jpg"}]}"#.utf8), 200)
        }
        let search = WebImageSearch(client: client, query: "fox", selection: .serverDefaults)
        await search.loadNext()?.value
        let result = try #require(search.results.first)
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
                                                thumbnailsReady: nil, positions: FolderPositions(database: nil),
                                                folderSettings: FolderSettings(database: nil), recent: nil)
        defer { controller.window?.close() }
        controller.showHome(tab: .webImages)
        let browser = try #require(controller.browserView)
        controller.openWebImage(result, in: search)
        try #require(!controller.isShowingHome)

        func event(_ type: NSEvent.EventType, time: TimeInterval, clicks: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 300, y: 250), modifierFlags: [],
                timestamp: time, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0))
        }
        let view = controller.viewerView
        view.mouseDown(with: try event(.leftMouseDown, time: 1, clicks: 1))
        view.mouseUp(with: try event(.leftMouseUp, time: 1.01, clicks: 1))
        #expect(!controller.isShowingHome)
        view.mouseDown(with: try event(.leftMouseDown, time: 1.05, clicks: 2))
        view.mouseUp(with: try event(.leftMouseUp, time: 1.06, clicks: 2))
        #expect(controller.isShowingHome)
        #expect(controller.shownTab == .webImages)
        #expect(controller.browserView === browser)
    }

    @Test func previewWarmsOnlyAdjacentThumbnailsAndCancelsOnPause() async throws {
        let client = SearXNGClient(baseURL: URL(string: "https://search.example")!) { _ in
            let results = ["previous", "current", "next", "far"].map {
                #"{"img_src":"https://images.example/\#($0).jpg","thumbnail_src":"https://images.example/thumb-\#($0).jpg"}"#
            }
            return (Data(#"{"results":[\#(results.joined(separator: ","))]}"#.utf8), 200)
        }
        let search = WebImageSearch(client: client, query: "fox", selection: .serverDefaults)
        await search.loadNext()?.value
        let loader = PreviewLoader()
        let viewer = WebImageViewer(search: search, loadPreview: loader.load)
        defer { viewer.pause() }
        try #require(viewer.files.count == 4)
        viewer.show(viewer.files[1]) {}
        for _ in 0..<100 {
            if await loader.requests.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await loader.requests == ["thumb-current.jpg:foreground", "thumb-next.jpg:background"])
        viewer.pause()
        for _ in 0..<100 {
            if await loader.cancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await loader.cancelled)
        #expect(await loader.requests.count == 2)
    }

    @Test func originalsWaitForReadinessAndStayInFlightWhenSelected() async throws {
        let client = SearXNGClient(baseURL: URL(string: "https://search.example")!) { _ in
            (Data("""
                {"results":[{"img_src":"https://images.example/previous.jpg"},
                {"img_src":"https://images.example/current.jpg"},{"img_src":"https://images.example/next.jpg"},
                {"img_src":"https://images.example/far.jpg"}]}
                """.utf8), 200)
        }
        let search = WebImageSearch(client: client, query: "fox", selection: .serverDefaults)
        await search.loadNext()?.value
        let loader = OriginalLoader()
        let viewer = WebImageViewer(search: search, loadOriginal: loader.load)
        defer { viewer.pause() }
        try #require(viewer.files.count == 4)
        viewer.show(viewer.files[1]) {}
        viewer.updateOriginalPrefetch(enabled: false, currentReady: true)
        viewer.updateOriginalPrefetch(enabled: true, currentReady: false)
        #expect(await loader.urls.isEmpty)

        viewer.updateOriginalPrefetch(enabled: true, currentReady: true)
        for _ in 0..<100 {
            if await !loader.urls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await loader.urls == ["next.jpg"])
        viewer.show(viewer.files[2]) {}
        viewer.updateOriginalPrefetch(enabled: true, currentReady: false)
        #expect(await !loader.cancelled)
        viewer.updateOriginalPrefetch(enabled: false, currentReady: false)
        for _ in 0..<100 {
            if await loader.cancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await loader.cancelled)
        #expect(await loader.urls == ["next.jpg"])
    }

    @Test func originalPrefetchDepthCountsInEachDirectionAndPrioritizesNearest() async throws {
        let client = SearXNGClient(baseURL: URL(string: "https://search.example")!) { _ in
            let results = (0..<7).map { ["img_src": "https://images.example/" + String($0) + ".jpg"] }
            return (try JSONEncoder().encode(["results": results]), 200)
        }
        let search = WebImageSearch(client: client, query: "fox", selection: .serverDefaults)
        await search.loadNext()?.value
        let recorder = OriginalRequests()
        let viewer = WebImageViewer(search: search, loadOriginal: recorder.record)
        defer { viewer.pause() }
        try #require(viewer.files.count == 7)
        viewer.show(viewer.files[3]) {}
        viewer.updateOriginalPrefetch(enabled: true, currentReady: true, depth: 2)
        for _ in 0..<100 {
            if await recorder.names.count >= 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorder.names == ["4.jpg", "2.jpg", "5.jpg", "1.jpg"])
        #expect(await recorder.retainedCounts == [5, 5, 5, 5])
    }

    private actor OriginalRequests {
        var names: [String] = []
        var retainedCounts: [Int] = []

        func record(_ url: URL, retainingCount: Int, _: Int) async {
            names.append(url.lastPathComponent)
            retainedCounts.append(retainingCount)
        }
    }

    @Test func originalPrefetchConcurrencyCapsRunningWorkAndCancelsSurplus() async throws {
        guard WebImagesPreferences.originalPrefetchConcurrencyRange.contains(2) else { return }
        let client = SearXNGClient(baseURL: URL(string: "https://search.example")!) { _ in
            let results = (0..<7).map { ["img_src": "https://images.example/" + String($0) + ".jpg"] }
            return (try JSONEncoder().encode(["results": results]), 200)
        }
        let search = WebImageSearch(client: client, query: "fox", selection: .serverDefaults)
        await search.loadNext()?.value
        let loader = OriginalLoader()
        let viewer = WebImageViewer(search: search, loadOriginal: loader.load)
        defer { viewer.pause() }
        try #require(viewer.files.count == 7)
        viewer.show(viewer.files[3]) {}
        viewer.updateOriginalPrefetch(enabled: true, currentReady: true, depth: 2, concurrency: 2)
        for _ in 0..<100 {
            if await loader.urls.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await Set(loader.urls) == ["4.jpg", "2.jpg"])

        viewer.updateOriginalPrefetch(enabled: true, currentReady: true, depth: 1, concurrency: 1)
        for _ in 0..<100 {
            if await !loader.cancelledURLs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await loader.cancelledURLs == ["2.jpg"])
        #expect(await loader.urls.count == 2)
    }

    private actor OriginalLoader {
        private(set) var urls: [String] = []
        private(set) var cancelledURLs: [String] = []
        var cancelled: Bool { !cancelledURLs.isEmpty }

        func load(_ url: URL, _: Int, _: Int) async {
            let name = url.lastPathComponent
            urls.append(name)
            do { try await Task.sleep(for: .seconds(5)) }
            catch { cancelledURLs.append(name) }
        }
    }

    private actor PreviewLoader {
        private(set) var requests: [String] = []
        private(set) var cancelled = false

        func load(_ url: URL, _ priority: ReadPriority) async throws -> CGImage? {
            requests.append(url.lastPathComponent + (priority.isBackground ? ":background" : ":foreground"))
            if priority.isBackground {
                do { try await Task.sleep(for: .seconds(5)) }
                catch {
                    cancelled = true
                    throw error
                }
            }
            return nil
        }
    }

    @Test func aBoundaryStepAdvancesOnlyFromItsOriginalResult() async throws {
        let (viewer, gate) = try await makeViewer()
        let first = try #require(viewer.files.first)
        viewer.show(first) {}
        let (answers, continuation) = AsyncStream<URL?>.makeStream()
        let accepted = viewer.step(1, atBoundary: true) { url, error in
            #expect(error == nil)
            continuation.yield(url)
            continuation.finish()
        }
        try #require(accepted)
        await gate.finish()
        for await advance in answers { #expect(advance == first) }
        #expect(viewer.files.count == 2)
        #expect(viewer.files.first == first)
    }

    @Test func reversingCancelsTheAdvanceAndKeepsTheAppendedPage() async throws {
        let (viewer, gate) = try await makeViewer()
        let first = try #require(viewer.files.first)
        viewer.show(first) {}
        let (answers, continuation) = AsyncStream<URL?>.makeStream()
        let accepted = viewer.step(1, atBoundary: true) { url, _ in
            continuation.yield(url)
            continuation.finish()
        }
        try #require(accepted)
        #expect(!viewer.step(-1, atBoundary: true) { _, _ in Issue.record("Unexpected page request") })
        await gate.finish()
        for await advance in answers { #expect(advance == nil) }
        #expect(viewer.files.count == 2)
        #expect(viewer.current == first)
    }

    private func makeViewer() async throws -> (WebImageViewer, NextPage) {
        let gate = NextPage()
        let client = SearXNGClient(baseURL: URL(string: "https://search.example")!) { url in
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageno" }?.value
            if page == "1" { return Self.response("one") }
            await gate.wait()
            return Self.response("two")
        }
        let search = WebImageSearch(client: client, query: "fox", selection: .serverDefaults)
        await search.loadNext()?.value
        try #require(search.results.count == 1)
        return (WebImageViewer(search: search), gate)
    }

    private nonisolated static func response(_ name: String) -> (Data, Int) {
        (Data(#"{"results":[{"img_src":"https://images.example/\#(name).jpg"}]}"#.utf8), 200)
    }

    private actor NextPage {
        private var ready = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !ready else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func finish() {
            ready = true
            continuation?.resume()
            continuation = nil
        }
    }
}
