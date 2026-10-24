import AppKit
import Foundation
import LoupeCore
import LoupeSettings
import SettingsKit

/// `LoupeBench settings [--rounds N] [--settle MS] [--icons N]` (docs/bench/2026-10-24-settings-switch.md): the main thread's work
/// per page switch of the settings window — the real window and pages over an empty loupe.conf/input.conf in a temp
/// dir, shown on screen, opened on the first page. A round goes down the sidebar to the last page and back up to the
/// first, one ↓ or ↑ key event at a time sent to the window itself, which need not be key (the search field has focus
/// and selects the adjacent page, as a click selects one), each followed by the run loop alone for --settle ms
/// (default 1500): long enough for SwiftUI's update, layout and the Core Animation commit. Prints the main thread's CPU
/// ms per switch onto each page — the first visit, and the median and max of the later ones — and the total of each
/// round; then the cost of one setting changed by the store, and where ⇥ stops once around the Mouse & Trackpad page
/// (none of the stops may be on a page that is not open). `--icons N` gives the Dock icon row N pictures of the user's
/// own, as a well-stocked ~/.config/loupe/icons has (1024² PNGs of ~1 MB in a temp folder; default 85); 0 leaves
/// the row with none. The window's frame and last page go to LoupeBench's own defaults, not Loupe's.
enum SettingsBench {
    static func main(_ arguments: [String]) -> Never {
        var rounds = 3, settle = 1500, icons = 85
        var args = arguments[...]
        while let arg = args.popFirst() {
            if arg == "--rounds", let n = args.popFirst().flatMap(Int.init), n > 0 { rounds = n; continue }
            if arg == "--settle", let n = args.popFirst().flatMap(Int.init), n > 0 { settle = n; continue }
            if arg == "--icons", let n = args.popFirst().flatMap(Int.init), n >= 0 { icons = n; continue }
            fail("settings: unknown argument \(arg)")
        }
        MainActor.assumeIsolated { run(rounds: rounds, settle: settle, icons: icons) }
        exit(0)
    }

    /// `count` 1024² PNGs of a gradient with grain (~1 MB each, as photos made into icons are) in `folder`.
    private static func makeIcons(_ count: Int, in folder: URL) -> [URL] {
        guard count > 0 else { return [] }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<count).compactMap { n in
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let data = rep.bitmapData else { return nil }
            for y in 0..<1024 {
                for x in 0..<1024 {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let grain = UInt8(truncatingIfNeeded: seed >> 59)
                    let p = data + y * rep.bytesPerRow + x * 4
                    p[0] = UInt8(truncatingIfNeeded: x / 4 + n * 9) &+ grain
                    p[1] = UInt8(truncatingIfNeeded: y / 4) &+ grain
                    p[2] = UInt8(truncatingIfNeeded: (x + y) / 8 + n * 31)
                    p[3] = 255
                }
            }
            let url = folder.appendingPathComponent(String(format: "icon-%03d.png", n))
            guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil
            else { return nil }
            return url
        }
    }

    @MainActor private static func run(rounds: Int, settle: Int, icons: Int) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-bench-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let conf = dir.appendingPathComponent("loupe.conf"), input = dir.appendingPathComponent("input.conf")
        FileManager.default.createFile(atPath: conf.path, contents: Data())
        FileManager.default.createFile(atPath: input.path, contents: Data())

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        var config = Config()
        let store = ConfigSettingsStore(fileURL: conf, current: { config }, reload: {})
        let iconFolder = dir.appendingPathComponent("icons", isDirectory: true)
        let iconFiles = makeIcons(icons, in: iconFolder)
        let context = SettingsPanelContext(configURL: conf, inputURL: input, iconChoices: {
            [IconChoice(word: "owl", section: "Built-in")]
                + iconFiles.map { IconChoice(word: $0.deletingPathExtension().lastPathComponent, file: $0, section: "Yours") }
        }, iconFolder: iconFolder)
        if icons > 0 { print("icons: \(icons) PNGs, \(iconFiles.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } >> 20) MB") }
        let ids = SettingsPanel.pages().map(\.id)
        let titles = Dictionary(uniqueKeysWithValues: SettingsPanel.pages().map { ($0.id, $0.title) })

        let open = threadCPU()
        SettingsPanel.show(store: store, context: context, page: ids[0])
        app.activate()
        spin(settle)
        print(String(format: "open (on %@): %.0f ms", titles[ids[0]]!, threadCPU() - open))
        guard let window = NSApp.windows.first(where: { $0.title == titles[ids[0]] }) else { fail("settings: no window") }

        let byTitle = Dictionary(uniqueKeysWithValues: titles.map { ($1, $0) })
        var first: [String: Double] = [:], later: [String: [Double]] = [:]
        var roundTotals: [Double] = []
        let steps = [UInt16](repeating: 125, count: ids.count - 1) + [UInt16](repeating: 126, count: ids.count - 1)
        for _ in 0..<rounds {
            var total = 0.0
            for code in steps {
                let before = window.title
                let t0 = threadCPU()
                press(code, in: window)
                spin(settle)
                let ms = threadCPU() - t0
                guard window.title != before, let id = byTitle[window.title] else { fail("settings: no page switch") }
                if first[id] == nil { first[id] = ms } else { later[id, default: []].append(ms) }
                total += ms
            }
            roundTotals.append(total)
        }
        print("page                 first ms  median ms   max ms   (main-thread CPU per switch onto the page)")
        for id in ids {
            let sorted = (later[id] ?? []).sorted()
            let firstText = first[id].map { String(format: "%8.0f", $0) } ?? "    open"
            let laterText = sorted.isEmpty ? "" : String(format: " %10.0f %8.0f", sorted[sorted.count / 2], sorted.last!)
            print(titles[id]!.padding(toLength: 20, withPad: " ", startingAt: 0) + " " + firstText + laterText)
        }
        print("round totals: " + roundTotals.map { String(format: "%.0f", $0) }.joined(separator: ", ") + " ms")

        // A setting changed elsewhere (a text editor, a key in the viewer) while the window is open: the store
        // announces one key, as the app's reload does. Every page has been opened by now.
        var edits: [Double] = []
        for value in ["500", "400", "500", "400"] {
            let t0 = threadCPU()
            config = Config.parse("mouse-long-press=\(value)").0
            NotificationCenter.default.post(name: .settingsStoreDidChange, object: store,
                                            userInfo: ["keys": ["mouse-long-press"]])
            spin(settle)
            edits.append(threadCPU() - t0)
        }
        print("one setting changed: " + edits.map { String(format: "%.0f", $0) }.joined(separator: ", ") + " ms")

        // ⇥ from the search field once around the loop: how many stops, and how many of them on a page that is not
        // open (an ancestor hidden or drawn at opacity 0).
        SettingsPanel.show(store: store, context: context, page: "mouse")
        spin(settle)
        var stops = 0, invisible = 0, seen = Set<ObjectIdentifier>()
        func focusedView() -> NSView? {
            let editor = window.firstResponder as? NSText
            return editor?.isFieldEditor == true ? editor?.delegate as? NSView : window.firstResponder as? NSView
        }
        while stops < 300, let from = focusedView() {
            // What ⇥ does: a text field ending its edit with a tab asks the window for the view after the field.
            window.selectKeyView(following: from)
            guard let focused = focusedView(), seen.insert(ObjectIdentifier(focused)).inserted else { break }
            stops += 1
            var ancestor: NSView? = focused, transparent = false
            while let a = ancestor {
                if a.isHidden || a.alphaValue == 0 || (a.layer?.opacity ?? 1) == 0 { transparent = true }
                ancestor = a.superview
            }
            if transparent { invisible += 1 }
        }
        print("⇥ on \(window.title): \(stops) stops, \(invisible) of them on pages that are not open")
        SettingsPanel.close()
    }

    /// A key press (down and up) as the window would get it from the keyboard: ↓ is 125, ↑ 126.
    @MainActor private static func press(_ code: UInt16, in window: NSWindow) {
        let character = String(UnicodeScalar(code == 125 ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: character,
                                               charactersIgnoringModifiers: character, isARepeat: false,
                                               keyCode: code) else { continue }
            window.sendEvent(event)
        }
    }

    /// Runs the main run loop for `ms` milliseconds (the window's updates and display happen in it).
    @MainActor private static func spin(_ ms: Int) {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default,
                                           dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// This thread's CPU time in ms.
    private static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }
}
