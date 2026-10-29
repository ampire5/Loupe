import AppKit
import LoupeCore

/// Private disposable-config regression driver; uses actual panel/sheet actions and independent launch phases.
@MainActor enum SmartZoomProfileBench {
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private static func cpu() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
    static func remember(_ phase: String, controller: ViewerWindowController, folderSettings: FolderSettings, folder: URL) async -> Bool {
        let preferences = Settings.detectorPreferences, session = controller.session
        guard ProcessInfo.processInfo.environment["LOUPE_DETECTOR_PREFERENCES_SUITE"] != nil else { fatalError("Use an isolated preferences suite") }
        if phase.hasPrefix("write") {
            guard let profile = Settings.shared.config.detectorSetup.modes.last else { fatalError("Configure a profile") }
            let item = NSMenuItem(); item.identifier = .init("detector-mode|" + profile.name)
            controller.chooseDetectorMode(item)
            if phase == "write-manual-pan" {
                showPanel(controller)
                guard let root = controller.window?.contentView,
                      let mode = descendants(root).first(where: { $0.identifier?.rawValue == "smartzoom.mode" }) as? NSSegmentedControl else { fatalError("Mode control missing") }
                mode.selectedSegment = 1; mode.sendAction(mode.action, to: mode.target)
                controller.viewerView.debugPerform(.toggleSmartZoom)
            } else { controller.viewerView.debugPerform(.zoomSubject) }
            folderSettings.flush(); preferences.synchronize()
            print("REMEMBER write mode=\(session.smartZoom.mode) last=\(session.smartZoom.lastEnabled)")
            return true
        }
        let manual = phase == "read-manual-pan"
        let expected = preferences.dictionary(forKey: ZoomKeys.lastProfileKey)?["detector-mode"] as? String
        let profileOK = expected != nil && session.zoomRules(session.entry!.url).detector?.name == expected
        let modeOK = session.smartZoom.mode == (manual ? .off : .frame)
            && session.smartZoom.lastEnabled == (manual ? .pan : .frame)
        var resume = true
        if manual {
            controller.viewerView.debugPerform(.toggleSmartZoom); resume = session.smartZoom.mode == .pan
            controller.viewerView.debugPerform(.toggleSmartZoom)
        }
        print("REMEMBER read profileOK=\(profileOK) modeOK=\(modeOK) resumeOK=\(resume)")
        return profileOK && modeOK && resume
    }
    private static func showPanel(_ controller: ViewerWindowController) {
        guard let item = controller.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "viewer.smartZoom" }), let action = item.action else { fatalError("Panel item missing") }
        NSApp.sendAction(action, to: item.target, from: item)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }
    private static func click(_ title: String, in view: NSView) {
        guard let button = descendants(view).first(where: { ($0 as? NSButton)?.title == title }) as? NSButton else { fatalError("Missing action: \(title)") }
        button.performClick(nil)
    }
    private static func table(_ id: String, in view: NSView) -> NSTableView {
        guard let table = descendants(view).first(where: { $0.identifier?.rawValue == id }) as? NSTableView else { fatalError("Missing table") }; return table
    }
    private static func checkbox(_ row: Int, in table: NSTableView) {
        guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSButton else { fatalError("Missing category") }; view.performClick(nil)
    }
    private static func weight(_ value: String, in table: NSTableView) {
        guard let field = table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField else { fatalError("Missing weight") }
        field.stringValue = value
        field.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    }
    static func editor(controller: ViewerWindowController) async -> Bool {
        controller.viewerView.debugPerform(.manualZoom)
        showPanel(controller)
        guard let parent = controller.window, let root = parent.contentView else { fatalError("No window") }
        var start = cpu(); click("New profile…", in: root)
        guard let sheet = parent.attachedSheet, let body = sheet.contentView else { fatalError("Editor sheet missing") }
        body.layoutSubtreeIfNeeded(); print("PROFILE new-mainCPUms=\((cpu() - start) * 1000)")
        if let bitmap = body.bitmapImageRepForCachingDisplay(in: body.bounds) {
            body.cacheDisplay(in: body.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/loupe-profile-editor.png"))
        }
        guard let name = descendants(body).first(where: { $0.identifier?.rawValue == "profile.name" }) as? NSTextField else { fatalError("Name missing") }
        if let form = descendants(body).first(where: { $0 is NSScrollView }) as? NSScrollView, let document = form.documentView {
            print("PROFILE form=\(form.frame) doc=\(document.frame) clip=\(form.contentView.bounds) flipped=\(document.isFlipped) name=\(name.convert(name.bounds, to: document))")
        }
        name.stringValue = "bench-custom"
        let categories = table("profile.categories", in: body)
        checkbox(0, in: categories); weight("1.75", in: categories); click("Add", in: body)
        click("Create profile", in: body)
        await wait { parent.attachedSheet == nil }
        let initial = Settings.shared.config.detectorSetup.modes.first { $0.name == "bench-custom" }
        let created = initial?.chain.count == 1 && initial?.composition.weights.values.contains(1.75) == true
            && controller.session.smartZoom.mode == .off
        print("PROFILE created-and-selected ok=\(created)")
        start = cpu(); click("Edit profile…", in: root)
        guard let edit = parent.attachedSheet?.contentView else { fatalError("Edit sheet missing") }
        edit.layoutSubtreeIfNeeded(); print("PROFILE edit-mainCPUms=\((cpu() - start) * 1000)")
        let types = table("profile.categories", in: edit)
        let visionRow = Settings.shared.config.detectorSetup.kinds.count
        checkbox(visionRow, in: types); click("Add", in: edit)
        let rules = table("profile.rules", in: edit)
        rules.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); click("↑", in: edit)
        weight("2", in: types); click("Save profile", in: edit)
        await wait { parent.attachedSheet == nil }
        let saved = Settings.shared.config.detectorSetup.modes.first { $0.name == "bench-custom" }
        let edited = saved?.chain.first == .face && saved?.chain.count == 2 && saved?.composition.weights.values.contains(2) == true
        print("PROFILE edited-order-and-weights ok=\(edited)")
        start = cpu(); click("Edit profile…", in: root)
        guard let again = parent.attachedSheet?.contentView else { fatalError("Reopen sheet missing") }
        again.layoutSubtreeIfNeeded(); print("PROFILE return-mainCPUms=\((cpu() - start) * 1000)")
        weight("3", in: table("profile.categories", in: again)); click("Cancel", in: again)
        await wait { parent.attachedSheet == nil }
        let cancelled = Settings.shared.config.detectorSetup.modes.first { $0.name == "bench-custom" } == saved
        print("PROFILE cancel-keeps-profile ok=\(cancelled)")
        return created && edited && cancelled
    }
    private static func wait(_ condition: () -> Bool) async {
        for _ in 0..<1500 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        fatalError("Profile benchmark action did not complete")
    }
}
