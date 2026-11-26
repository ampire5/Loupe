#if DEBUG
import AppKit
import HomeScreenKit
import LoupeCore
import LoupeRender

/// Opens the production comparison tab from two loaded source tabs and exercises its controls.
@MainActor enum PhotoComparisonBench {
    static func run(first: URL, second: URL) async -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader)
        let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let settings = FolderSettings(database: nil)
        let registry = WindowRegistry()
        registry.makeController = { [unowned registry] in
            let controller = ViewerWindowController(cache: cache, thumbnails: thumbs, thumbnailsReady: nil,
                positions: FolderPositions(database: nil), folderSettings: settings, recent: nil)
            registry.add(controller)
            return controller
        }

        let a = registry.makeController!()
        a.window?.setContentSize(CGSize(width: 1000, height: 700))
        a.showWindow(nil)
        a.bringToFront()
        a.open(first)
        await wait("first source") { a.session.image != nil }
        registry.open(.file(second), force: .tab, from: a)
        guard let b = registry.controllers.last, b !== a else { fail("second source tab") }
        await wait("second source") { b.session.image != nil }
        a.selectForComparison(nil)
        a.session.transform = a.session.transform.withMode(.actual(0.9)).panned(by: CGVector(dx: 100, dy: -50))
        b.session.transform = b.session.transform.withMode(.actual(1.2)).panned(by: CGVector(dx: -100, dy: 50))
        let originalA = SavedView(a.session.transform), originalB = SavedView(b.session.transform)

        print("round\taction\tmain-thread-ms")
        for round in 1...5 {
            measure(round, "open-tab") { b.compareWithSelectedPhoto(nil) }
            guard let comparison = registry.controllers.last, comparison.isShowingComparison,
                  let window = comparison.window, let content = window.contentView,
                  let view = content.subviews.compactMap({ $0 as? PhotoComparisonView }).first
            else { fail("comparison tab") }
            let buttons = descendants(of: view).compactMap { $0 as? NSButton }
            guard let link = buttons.first(where: { $0.title == "Link Pan & Zoom" }),
                  let match = buttons.first(where: { $0.title == "Match Visual Scale" })
            else { fail("comparison controls") }
            await wait("pair to load with matching proportions") { link.state == .on && match.isEnabled }
            guard let canvas = window.firstResponder as? NSView, canvas.isDescendant(of: view) else {
                fail("focused comparison canvas")
            }
            let zoom = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "=", charactersIgnoringModifiers: "=",
                isARepeat: false, keyCode: 24)!
            let before = canvas.accessibilityValue() as? String
            measure(round, "linked-zoom") { canvas.keyDown(with: zoom) }
            guard before != (canvas.accessibilityValue() as? String) else { fail("linked zoom changed scale") }
            measure(round, "unlink") {
                link.state = .off
                link.sendAction(link.action, to: link.target)
            }
            guard link.state == .off else { fail("unlink") }
            measure(round, "match") { match.sendAction(match.action, to: match.target) }
            guard link.state == .on else { fail("match relinks") }

            b.bringToFront()
            measure(round, "return-tab") { comparison.bringToFront() }
            guard registry.snapshot().windows.flatMap(\.tabs).count == 2 else { fail("transient tab leaked into session") }
            window.close()
            await wait("comparison close") { registry.controllers.count == 2 }
            guard SavedView(a.session.transform) == originalA, SavedView(b.session.transform) == originalB else {
                print("source A: \(originalA.text) -> \(SavedView(a.session.transform).text)")
                print("source B: \(originalB.text) -> \(SavedView(b.session.transform).text)")
                fail("source view changed")
            }
        }
        if first.deletingLastPathComponent() == second.deletingLastPathComponent() {
            a.bringToFront()
            a.browseFolder(nil)
            guard let content = a.window?.contentView,
                  let browser = descendants(of: content).compactMap({ $0 as? HomeBrowserView }).first
            else { fail("File View") }
            await wait("File View source selected") { browser.selectedEntry?.url == first }
            for code: UInt16 in [124, 125, 123, 126] where browser.selectedEntries.count < 2 {
                let shiftArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                    windowNumber: a.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: code)!
                browser.keyDown(with: shiftArrow)
            }
            guard Set(browser.selectedEntries.map(\.url)) == Set([first, second]) else { fail("File View multi-selection") }
            measure(1, "open-selection") { a.compareSelectedPhotos(nil) }
            guard registry.controllers.last?.isShowingComparison == true else { fail("File View comparison") }
        }
        print("photo comparison: PASS")
        exit(0)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func wait(_ description: String, until ready: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready() {
            guard ContinuousClock.now < deadline else { fail(description) }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func measure(_ round: Int, _ action: String, _ body: () -> Void) {
        let before = cpu()
        body()
        print("\(round)\t\(action)\t\(String(format: "%.3f", (cpu() - before) * 1000))")
    }

    private static func cpu() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }

    private static func fail(_ description: String) -> Never {
        print("photo comparison: FAIL (\(description))")
        exit(1)
    }
}
#endif
