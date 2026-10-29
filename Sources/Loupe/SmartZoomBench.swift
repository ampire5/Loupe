import AppKit
import QuartzCore
import Slots
import SlotModel
import LoupeCore

/// Actual Slot host and production controls; use a disposable config directory.
@MainActor enum SmartZoomBench {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        print("round\taction\tmain-thread-ms")
        for round in 1...5 {
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1100, height: 850),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.autorecalculatesKeyViewLoop = true
            let content = window.contentView!, photo = NSView(frame: content.bounds)
            content.addSubview(photo)
            let host = SlotsController(container: content, above: photo)
            var panel: SmartZoomPanel?
            let kinds = ["face", "person", "object", "saliency", "portrait-face", "cup", "apple", "cat", "dog", "book", "plant"].compactMap(SubjectKind.init(rawValue:))
            let custom = kinds.filter(\.isCustom)
            var groups = custom
            for i in custom.indices { for j in custom.indices where j > i {
                if groups.count < 20, let pair = SubjectKind(rawValue: custom[i].rawValue + "+" + custom[j].rawValue) { groups.append(pair) }
            } }
            groups += SubjectKind.vision
            var state = SmartZoomPanel.Snapshot(mode: .pan, profile: "balanced", profiles: ["balanced", "portrait", "scene"],
                groups: groups, selected: groups.first, kinds: kinds, options: .init(), size: 0.85,
                note: "Group: Face · All selected objects retained", showsBoxes: false)
            host.register(SlotTabDescriptor(id: FolderSlotSettings.smartzoom, title: "SmartZoom", singleton: true) { _ in
                let page = panel ?? SmartZoomPanel(); panel = page
                page.source = { state }
                page.chooseMode = { state.mode = $0; page.refresh() }
                page.edit = { key, value in _ = state.options.set(key, value); page.refresh() }
                return SlotPage(view: page.view, visibilityChanged: { page.setVisible($0) })
            })
            let other = SlotTabID(rawValue: "other")
            host.register(SlotTabDescriptor(id: other, title: "Other") { _ in SlotPage(view: NSView()) })
            host.configure(.init(tabs: [FolderSlotSettings.smartzoom, other], size: 440), edge: .right)
            host.start(); window.orderFront(nil)
            func flush() { content.layoutSubtreeIfNeeded(); CATransaction.flush() }
            measure(round, "first-show") { host.show(.right); flush() }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            for _ in 0..<5 {
                measure(round, "return") { host.select(other, edge: .right); host.select(FolderSlotSettings.smartzoom, edge: .right); flush() }
                measure(round, "profile") { state.profile = state.profile == "balanced" ? "portrait" : "balanced"; panel?.refresh(); flush() }
                measure(round, "group") { state.selected = kinds.randomElement(); panel?.refresh(); flush() }
                measure(round, "weight") { state.options.weights[kinds[0]] = state.options.weights[kinds[0]] == 1.25 ? 1 : 1.25; panel?.refresh(); flush() }
            }
            if round == 1, let panel {
                let buttons = descendants(panel.view).compactMap { $0 as? NSButton }
                buttons.first { $0.title == "Type weights ▸" }?.performClick(nil)
                flush()
                let sliders = descendants(panel.view).compactMap { $0 as? NSSlider }
                if let slider = sliders.last {
                    measure(round, "control-action") { slider.doubleValue = 1.25; slider.sendAction(slider.action, to: slider.target); flush() }
                }
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/loupe-smartzoom-panel.png"))
                }
            }
            host.cancelInteraction(); host.hide(.right)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)); window.close()
        }
        print("Intel performance requires a separate Intel run.")
        exit(0)
    }
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private static func measure(_ round: Int, _ action: String, _ body: () -> Void) {
        func cpu() -> Double {
            var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
            return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
        }
        let start = cpu(); body()
        print("\(round)\t\(action)\t\(String(format: "%.3f", (cpu() - start) * 1000))")
    }
}
