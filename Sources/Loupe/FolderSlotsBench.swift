import AppKit
import Filmstrip
import QuartzCore
import Slots
import SlotModel
import LoupeCore

/// The actual app views in a real window. Run with a disposable CFFIXED_USER_HOME.
@MainActor enum FolderSlotsBench {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let rows = (0..<1000).map { FolderStripEntry(id: .gallery(String($0)), title: "Folder \($0)") }
        let source = FolderStripGallerySource(rows: { _ in rows }, target: { _ in nil })
        let store = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0,
                                   locate: { _ in nil }, shareLocate: { _ in nil })
        print("round\taction\tmain-thread-ms")
        for round in 1...5 {
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1200, height: 800),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.autorecalculatesKeyViewLoop = true
            let content = window.contentView!, photo = NSView(frame: content.bounds)
            photo.wantsLayer = true; photo.layer?.backgroundColor = NSColor.white.cgColor
            content.addSubview(photo)
            let host = SlotsController(container: content, above: photo)
            let folders = FolderStripController(source: source, store: store)
            folders.synchronize(opened: .gallery("500"))
            let id = SlotTabID(rawValue: "folders"), other = SlotTabID(rawValue: "other")
            host.register(SlotTabDescriptor(id: id, title: "Folders") { _ in
                let page = SlotPage(view: folders.view, visibilityChanged: { folders.setVisible($0) })
                page.cancelInteraction = { folders.cancelInteraction() }
                return page
            })
            host.register(SlotTabDescriptor(id: other, title: "Other") { _ in SlotPage(view: NSView()) })
            host.configure(SlotConfiguration(tabs: [id, other]), edge: .right)
            host.start(); window.orderFront(nil)
            measure(round, "first-show") { host.show(.right); content.layoutSubtreeIfNeeded(); CATransaction.flush() }
            measure(round, "populate-1000-rows") { spin(0.1); content.layoutSubtreeIfNeeded(); CATransaction.flush() }
            if round == 1 { snapshot(content) }
            for _ in 0..<10 {
                measure(round, "tab-return") { host.select(other, edge: .right); host.select(id, edge: .right); content.layoutSubtreeIfNeeded(); CATransaction.flush() }
            }
            measure(round, "resize") { window.setContentSize(CGSize(width: 1000, height: 700)); host.refreshLayout(); content.layoutSubtreeIfNeeded(); CATransaction.flush() }
            measure(round, "hide") { host.hide(.right); content.layoutSubtreeIfNeeded(); CATransaction.flush() }
            spin(0.3)
            folders.setVisible(false); host.cancelInteraction(); window.close()
        }
        staleReplyCheck(store: store)
        branchCheck(store: store)
        print("folder-slots: finished; Intel timing requires a separate Intel run")
        exit(0)
    }
    private static func measure(_ round: Int, _ action: String, _ body: () -> Void) {
        let start = cpu(); body(); let elapsed = (cpu() - start) * 1000
        print("\(round)\t\(action)\t\(String(format: "%.3f", elapsed))")
    }
    private static func cpu() -> Double {
        var time = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
    private static func spin(_ seconds: Double) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }
    private static func snapshot(_ view: NSView) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/private/tmp/loupe-folder-slots/folder-slots.png"))
        }
    }
    private static func branchCheck(store: ThumbnailStore) {
        let root = URL(fileURLWithPath: "/fixture-branch", isDirectory: true)
        let a = root.appendingPathComponent("A long folder"), b = root.appendingPathComponent("B")
        let c = a.appendingPathComponent("C"), d = a.appendingPathComponent("D")
        let source = FolderStripListing(list: { url in
            if url == root { return [DirectoryEntry(url: a, isDirectory: true, isPackage: false), DirectoryEntry(url: b, isDirectory: true, isPackage: false)] }
            if url == a { return [DirectoryEntry(url: c, isDirectory: true, isPackage: false), DirectoryEntry(url: d, isDirectory: true, isPackage: false)] }
            if url == c { return [DirectoryEntry(url: c.appendingPathComponent("E"), isDirectory: true, isPackage: false)] }
            return [DirectoryEntry(url: url.appendingPathComponent("photo.jpg"), isDirectory: false, isPackage: false)]
        })
        let folders = FolderStripController(source: source, store: store)
        folders.synchronize(opened: .folder(a)); folders.view.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
        var opened: [String] = []
        folders.onOpen = { [weak folders] target, _, _ in
            opened.append(target.folder.lastPathComponent); folders?.synchronize(opened: .folder(target.folder))
        }
        folders.setVisible(true); spin(0.05)
        for _ in 0..<3 {
            for code: UInt16 in [125, 36] {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
                folders.view.keyDown(with: event)
            }
            spin(0.05)
        }
        precondition(opened == ["E", "D", "B"], "branch navigation lost outer siblings: \(opened)")
        folders.setVisible(false); folders.onOpen = nil
        print("branch-order: PASS")
    }
    private static func staleReplyCheck(store: ThumbnailStore) {
        let rows = ["0", "1", "2"].map { FolderStripEntry(id: .gallery($0), title: $0) }
        let source = FolderStripGallerySource(rows: { _ in rows }, target: { id in
            guard case .gallery(let id) = id else { return nil }
            // Deliberately finish even after cancellation, like a syscall already in the kernel.
            try? await Task.sleep(for: id == "1" ? .milliseconds(150) : .milliseconds(1))
            let folder = URL(fileURLWithPath: "/fixture/\(id)")
            return FolderTarget(folder: folder, images: [folder.appendingPathComponent("photo.jpg")])
        })
        let folders = FolderStripController(source: source, store: store)
        folders.synchronize(opened: .gallery("0"))
        var opened: [String] = []
        folders.onOpen = { target, _, _ in opened.append(target.folder.lastPathComponent) }
        folders.view.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
        folders.setVisible(true); spin(0.05)
        folders.view.frame = CGRect(x: 0, y: 0, width: 1100, height: 240)
        folders.view.needsLayout = true; folders.view.layoutSubtreeIfNeeded()
        let rowsView = folders.view.subviews.first { $0 is FilmstripRowsView } as! FilmstripRowsView
        let rowHeight = rowsView.layout.currentPicture / 1.5 + rowsView.layout.currentCaptionHeight + rowsView.layout.cardHeight
        precondition(rowHeight <= 240, "folder row does not fit a bottom slot: \(rowHeight)")
        folders.view.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
        folders.view.needsLayout = true; folders.view.layoutSubtreeIfNeeded()
        print("bottom-fit: PASS")
        func key(_ code: UInt16) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { fatalError("key fixture") }
            folders.view.keyDown(with: event)
        }
        key(125); spin(0.65)
        precondition(opened.isEmpty, "browsing opened a folder without explicit confirmation")
        print("explicit-selection: PASS")
        key(36); spin(0.01); key(125); key(36); spin(0.25)
        precondition(opened == ["2"], "stale reply committed: \(opened)")
        print("stale-reply: PASS")
        key(126); key(36); folders.setVisible(false); spin(0.2)
        precondition(opened == ["2"], "hidden File View committed a pending folder selection")
        print("file-view-suspends: PASS")
    }
}
