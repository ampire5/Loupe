import AppKit
import Darwin
import HomeScreenKit
import HomeScreenModel
import LoupeCore
import LoupeInspector

/// Real native Home window + inspector. Synthetic metadata isolates UI cost from filesystem latency.
enum InspectorBench {
    static func main(_ arguments: [String]) -> Never {
        if arguments.contains("--startup") {
            MainActor.assumeIsolated { hiddenStartup(eager: arguments.contains("--eager")) }
        } else {
            let shots = arguments.first
            MainActor.assumeIsolated { run(shots: shots) }
        }
        exit(0)
    }

    @MainActor private static func run(shots: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let source = InspectorBenchSource()
        let defaults = UserDefaults(suiteName: "local.loupe.inspector-bench.\(getpid())")!
        let loader = BrowserInspectorLoader(settleDelay: .zero, reader: { entry in
            var m = PhotoMetadata(properties: [:], pngText: [:], created: Date(timeIntervalSince1970: 1700000000), modified: entry.date)
            m.header = ImageInfo(pixelSize: PixelSize(width: 6000, height: 4000), typeIdentifier: "public.jpeg",
                                 isProgressive: false, fileSize: 8400000, colorSpaceName: "Display P3")
            m.camera = "Example Camera"; m.lens = "24–70 mm f/4"; m.focalLength = "35 mm"
            m.aperture = "f/5.6"; m.exposure = "1/250 s"; m.iso = "ISO 100"; m.bitDepth = 8
            if entry.name.contains("2") { m.generation = String(repeating: "A cat beside a window. ", count: 1000) }
            return BrowserInspectorResult(metadata: m)
        })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1160, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.title = "Loupe — Inspector benchmark"
        window.titlebarAppearsTransparent = true
        let home = HomeView(source: source)
        home.browser.selectsOnHover = false
        home.frame = window.contentView!.bounds
        home.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(home)
        home.isSidebarVisible = false
        home.browser.names = .below
        home.browser.onSelectionChange = { loader.select($0) }
        window.toolbar = home.browser.nsToolbar
        home.browser.show(.folder(source.folder), selecting: nil)
        window.center(); window.makeKeyAndOrderFront(nil)
        spin(0.3)
        let start = cpu()
        home.configureInspector { BrowserInspectorController(defaults: defaults, loader: loader) }
        let initialized = cpu()
        home.isInspectorVisible = true
        let installed = cpu()
        loader.isActive = true
        loader.select(home.browser.selectedEntry)
        home.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let laidOut = cpu()
        spin(0.15)
        print(String(format: "first-open CPU ms\t%.3f\tregistration %.3f materialize %.3f layout %.3f settle %.3f",
                     cpu() - start, initialized - start, installed - initialized, laidOut - installed, cpu() - laidOut))
        for round in 1...3 {
            var selection: [Double] = [], reopen: [Double] = []
            for _ in 0..<20 {
                let start = cpu()
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
                home.browser.keyDown(with: event)
                spin(0.03)
                home.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                selection.append(cpu() - start)
            }
            for _ in 0..<5 {
                home.isInspectorVisible = false
                home.layoutSubtreeIfNeeded(); spin(0.03)
                let start = cpu()
                home.isInspectorVisible = true
                home.layoutSubtreeIfNeeded(); spin(0.03)
                reopen.append(cpu() - start)
            }
            print(String(format: "round %d\tselection median %.3f max %.3f\treopen median %.3f max %.3f",
                         round, median(selection), selection.max()!, median(reopen), reopen.max()!))
        }
        if let shots {
            home.layoutSubtreeIfNeeded()
            if let image = home.bitmapImageRepForCachingDisplay(in: home.bounds) {
                home.cacheDisplay(in: home.bounds, to: image)
                try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shots))
            }
        }
        loader.isActive = false
        window.close()
        defaults.removePersistentDomain(forName: "local.loupe.inspector-bench.\(getpid())")
    }
    /// A/B: the old eager path and the deferred path in the same real Home window, in separate processes.
    /// Does not enable metadata reads; the regular benchmark above measures populated inspector interactions.
    @MainActor private static func hiddenStartup(eager: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let defaults = UserDefaults(suiteName: "local.loupe.inspector-startup.\(getpid())")!
        print("mode\tround\thome CPU ms\tregistration CPU ms\tcontrollers before show\tview loaded before show\tfirst show CPU ms\tcontrollers after reopen")
        for round in 1...3 {
            let source = InspectorBenchSource()
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1160, height: 820),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.autorecalculatesKeyViewLoop = true
            let start = cpu()
            let home = HomeView(source: source)
            home.browser.selectsOnHover = false
            home.frame = window.contentView!.bounds
            home.autoresizingMask = [.width, .height]
            home.isSidebarVisible = false
            var created = 0
            var inspector: BrowserInspectorController?
            func makeInspector() -> NSViewController {
                created += 1
                let controller = BrowserInspectorController(defaults: defaults)
                inspector = controller
                return controller
            }
            let registration = cpu()
            if eager { home.installInspector(makeInspector()) }
            else { home.configureInspector(make: makeInspector) }
            let registrationCPU = cpu() - registration
            window.contentView?.addSubview(home)
            window.toolbar = home.browser.nsToolbar
            home.browser.show(.folder(source.folder), selecting: nil)
            window.center(); window.makeKeyAndOrderFront(nil)
            home.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            spin(0.15)
            let homeCPU = cpu() - start
            let before = created
            let loaded = inspector?.isViewLoaded == true
            let first = cpu()
            home.isInspectorVisible = true
            home.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            spin(0.08)
            let firstCPU = cpu() - first
            home.isInspectorVisible = false
            home.isInspectorVisible = true
            home.layoutSubtreeIfNeeded(); spin(0.03)
            print(String(format: "%@\t%d\t%.3f\t%.3f\t%d\t%@\t%.3f\t%d",
                         eager ? "eager" : "lazy", round, homeCPU, registrationCPU, before,
                         loaded ? "yes" : "no", firstCPU, created))
            window.close()
            spin(0.02)
        }
        defaults.removePersistentDomain(forName: "local.loupe.inspector-startup.\(getpid())")
    }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    private static func cpu() -> Double {
        var value = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value)
        return Double(value.tv_sec) * 1000 + Double(value.tv_nsec) / 1_000_000
    }
    @MainActor private static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.005))) }
    }
}

@MainActor private final class InspectorBenchSource: HomeSource {
    let folder = URL(fileURLWithPath: "/Examples")
    func places() async -> [BrowserEntry] { [] }
    func list(_ location: BrowserLocation) -> AsyncThrowingStream<BrowserListing, Error> {
        let files = (0..<1000).map { BrowserEntry(url: folder.appendingPathComponent("Photo-\($0).jpg"),
                                                name: "Photo-\($0).jpg", kind: .file, date: Date(timeIntervalSince1970: 1700000000), size: 8400000) }
        return AsyncThrowingStream { $0.yield(BrowserListing(entries: files, complete: true)); $0.finish() }
    }
    func folders(in folder: URL) async throws -> [BrowserEntry] { [] }
    func parent(of folder: URL) -> BrowserLocation { .places }
    func symbol(for entry: BrowserEntry) -> String { "photo" }
    func wantImages(_ ids: [String], width: CGFloat) {}
    func menu(for entry: BrowserEntry, in location: BrowserLocation) -> [HomeMenuItem] { [] }
    func perform(_ item: String, on entry: BrowserEntry, in location: BrowserLocation) {}
    func open(_ entry: BrowserEntry, in location: BrowserLocation, sort: BrowserSort, how: HomeClick) {}
    func rename(_ entry: BrowserEntry, to name: String) async throws -> BrowserEntry { entry }
    func trash(_ entry: BrowserEntry) async throws {}
    func sort(for location: BrowserLocation) -> BrowserSort { .standard }
    func setSort(_ sort: BrowserSort, for location: BrowserLocation) {}
    func info(for source: String) -> HomeSourceInfo { HomeSourceInfo(title: source) }
    func sidebar() async -> [HomeSidebarSection] { [] }
    func pageFilterChosen(_ index: Int, in source: String) {}
}
