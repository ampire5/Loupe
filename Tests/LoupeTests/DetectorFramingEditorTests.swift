import AppKit
import Testing
import LoupeCore
import LoupeRender
@testable import Loupe

@Suite(.serialized) @MainActor struct DetectorFramingEditorTests {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func field(_ column: String, row: Int, table: NSTableView) throws -> NSTextField {
        let i = try #require(table.tableColumns.firstIndex { $0.identifier.rawValue == column })
        return try #require(table.view(atColumn: i, row: row, makeIfNecessary: true) as? NSTextField)
    }
    func edit(_ field: NSTextField, _ text: String) {
        field.stringValue = text
        field.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    }

    @Test func classControlsSaveRadiusCutAndPaddingInTheDraft() throws {
        _ = NSApplication.shared
        let editor = DetectorProfileEditor(draft: .init(name: "portrait", chain: [.face]), categories: [.face, .object], creating: true)
        let root = try #require(editor.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let table = try #require(descendants(root).first { $0.identifier?.rawValue == "profile.categories" } as? NSTableView)
        #expect(try #require(table.tableColumns.first { $0.identifier.rawValue == "crop" }).width >= 70)
        let cropColumn = try #require(table.tableColumns.firstIndex { $0.identifier.rawValue == "crop" })
        #expect(table.rect(ofColumn: cropColumn).maxX <= table.enclosingScrollView!.contentSize.width + 1)
        edit(try field("radius", row: 0, table: table), "125")
        edit(try field("crop", row: 0, table: table), "5")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let padding = try #require(descendants(root).first { $0.identifier?.rawValue == "profile.protection-padding" } as? NSTextField)
        edit(padding, "8")
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/loupe-circle-editor.png"))
        }
        var saved: DetectorProfileDraft?
        editor.save = { draft, done in saved = draft; done(.success(())) }
        let button = try #require(descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "Create profile" })
        button.performClick(nil)
        let draft = try #require(saved)
        #expect(draft.composition.circleRadii[.face] == 1.25)
        #expect(draft.composition.maxCrop[.face] == 0.05)
        #expect(draft.composition.protectionMargins[.face] == 0.08)
    }

    @Test func invalidClassCutKeepsTheLastValidValueAndOffSurvivesSave() throws {
        _ = NSApplication.shared
        let editor = DetectorProfileEditor(draft: .init(name: "portrait", chain: [.face]), categories: [.face], creating: true)
        let root = try #require(editor.window?.contentView)
        let table = try #require(descendants(root).first { $0.identifier?.rawValue == "profile.categories" } as? NSTableView)
        let cut = try field("crop", row: 0, table: table)
        edit(cut, "off"); edit(cut, "50")
        #expect(cut.stringValue.lowercased() == "off")
        var saved: DetectorProfileDraft?
        editor.save = { draft, done in saved = draft; done(.success(())) }
        try #require(descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "Create profile" }).performClick(nil)
        #expect(saved?.composition.maxCrop[.face] == 1)
    }

    @Test func quickRadiusControlUsesTheExistingEditRouteAndStaysQuietWhenHidden() throws {
        _ = NSApplication.shared
        let panel = SmartZoomPanel()
        var calls = 0
        panel.source = {
            calls += 1
            return .init(mode: .frame, profile: "Vision", profiles: ["Vision"], groups: [.face], selected: .face,
                         kinds: [.face], options: .init(), size: 0.7, note: "", showsBoxes: false)
        }
        panel.refresh(); #expect(calls == 0)
        panel.setVisible(true)
        let row = try #require(descendants(panel.view).first { $0.identifier?.rawValue == "smartzoom.circle-radius" })
        let slider = try #require(descendants(row).compactMap { $0 as? NSSlider }.first)
        var edited: (String, String)?
        panel.edit = { edited = ($0, $1) }
        slider.doubleValue = 75
        slider.sendAction(slider.action, to: slider.target)
        let change = try #require(edited)
        var options = CompositionOptions()
        #expect(change.0 == "circle-radius")
        #expect(options.set(change.0, change.1) == true && options.circleRadius == 0.75)
        panel.setVisible(false)
        let before = calls; panel.refresh(); #expect(calls == before)
    }

    @Test func visionClassPoliciesAreEditableWithoutInstallingAModel() throws {
        _ = NSApplication.shared
        let preferences = Settings.detectorPreferences
        let previousMode = preferences.object(forKey: SmartZoomState.preferenceKey)
        let previousProfile = preferences.object(forKey: ZoomKeys.lastProfileKey)
        defer {
            if let previousMode { preferences.set(previousMode, forKey: SmartZoomState.preferenceKey) }
            else { preferences.removeObject(forKey: SmartZoomState.preferenceKey) }
            if let previousProfile { preferences.set(previousProfile, forKey: ZoomKeys.lastProfileKey) }
            else { preferences.removeObject(forKey: ZoomKeys.lastProfileKey) }
        }
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
            thumbnailsReady: nil, positions: FolderPositions(database: nil), folderSettings: FolderSettings(database: nil), recent: nil)
        defer { controller.window?.close() }
        controller.session.smartZoom.select(.off)
        controller.turnDetectorOff(nil)
        controller.session.smartZoom.select(.off)
        #expect(controller.session.zoomRules(URL(fileURLWithPath: "/Demo/photo.jpg")).detector == nil)
        #expect(!Settings.shared.config.detectorSetup.detects)
        let window = try #require(controller.window)
        let item = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "viewer.smartZoom" })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        let root = try #require(window.contentView); root.layoutSubtreeIfNeeded()
        let editButton = try #require(descendants(root).compactMap { $0 as? NSButton }.first {
            $0.title == "Edit profile…" || $0.title == "Edit Vision settings…"
        })
        #expect(editButton.isEnabled)
        editButton.performClick(nil)
        controller.session.smartZoom.select(.off)
        let sheet = try #require(window.attachedSheet?.contentView)
        sheet.layoutSubtreeIfNeeded()
        let table = try #require(descendants(sheet).first { $0.identifier?.rawValue == "profile.categories" } as? NSTableView)
        edit(try field("crop", row: 0, table: table), "off")
        edit(try field("radius", row: 0, table: table), "125")
        try #require(descendants(sheet).compactMap { $0 as? NSButton }.first { $0.title == "Apply to tab" }).performClick(nil)
        let rules = controller.session.zoomRules(URL(fileURLWithPath: "/Demo/photo.jpg"))
        #expect(rules.detector == nil)
        #expect(rules.composition.cropLimit(for: .face) == nil)
        #expect(rules.composition.circleRadii[.face] == 1.25)
        #expect(controller.session.smartZoom.mode == .off)
    }
}
