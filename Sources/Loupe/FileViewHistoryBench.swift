#if DEBUG
import AppKit
import ImageIO
import QuartzCore
import LoupeCore
import LoupeRender

/// Real CAMetalDrawable presentation verification under NSApplication.run, with generated temporary images only.
@MainActor enum FileViewHistoryBench {
    private enum Failure: Error { case missingValue, failedCheck }
    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure.missingValue }; return value
    }
    private static func check(_ value: Bool) throws { if !value { throw Failure.failedCheck } }
    static func run() async -> Never {
        do { try await checks(); print("HISTORY PRESENT BENCH PASS"); exit(0) }
        catch { fputs("HISTORY PRESENT BENCH FAIL: \(error)\n", stderr); exit(1) }
    }
    private static func checks() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("cat.png"), b = dir.appendingPathComponent("dog.png")
        let context = try require(CGContext(data: nil, width: 256, height: 192, bitsPerComponent: 8, bytesPerRow: 1024,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 256, height: 192))
        let image = try require(context.makeImage())
        for url in [a, b] {
            let destination = try require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try check(CGImageDestinationFinalize(destination))
        }
        let positions = FolderPositions(database: try StateDatabase(directory: dir.appendingPathComponent("state")))
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: cache, thumbnails: thumbs, thumbnailsReady: nil,
            positions: positions, folderSettings: FolderSettings(database: nil), recent: nil)
        let session = controller.session
        let window = try require(controller.window)
        func findView(_ root: NSView) -> ViewerView? {
            if let view = root as? ViewerView { return view }
            for child in root.subviews { if let found = findView(child) { return found } }
            return nil
        }
        let view = try require(window.contentView.flatMap(findView))
        defer { session.close(); view.teardown(); window.close() }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
        CATransaction.flush()
        session.setActivity(active: true, visible: true, lastActive: 1)
        session.open(a)
        let deadline = ContinuousClock.now + .seconds(8)
        var first: Date?
        while first == nil, ContinuousClock.now < deadline {
            first = await positions.fileViews.lastViewed([a])[a]
            try? await Task.sleep(for: .milliseconds(10))
        }
        if first == nil { print("HISTORY DIAGNOSTIC visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) hidden=\(view.isHiddenOrHasHiddenAncestor) entry=\(String(describing: session.entry?.url)) image=\(session.image != nil) transform=\(session.transform)") }
        try check(first != nil)
        try check(await positions.fileViews.lastViewed([b])[b] == nil)
        for _ in 0..<3 { view.sessionDidChange() }
        try check(await positions.fileViews.lastViewed([a])[a] == first)
        view.isHidden = true
        session.open(b)
        let hiddenDeadline = ContinuousClock.now + .seconds(3)
        while session.entry?.url != b, ContinuousClock.now < hiddenDeadline { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(100))
        try check(await positions.fileViews.lastViewed([b])[b] == nil)
        view.isHidden = false
        let revealDeadline = ContinuousClock.now + .seconds(5)
        var second: Date?
        while second == nil, ContinuousClock.now < revealDeadline {
            second = await positions.fileViews.lastViewed([b])[b]
            try? await Task.sleep(for: .milliseconds(10))
        }
        try check(second != nil)
        try check(await positions.fileViews.lastViewed([a])[a] == first)
        positions.flush()
        print("HISTORY PRESENT BENCH visible, hidden, refinement and reveal checks completed")
    }
}
#endif
