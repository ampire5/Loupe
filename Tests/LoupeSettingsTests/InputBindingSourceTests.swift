import Testing
import AppKit
import SettingsKit
import LoupeCore
@testable import LoupeSettings

/// A binding source over a temp `input.conf` (or none), counting the reloads it asks for.
@MainActor
private final class Fixture {
    let dir: URL
    let file: URL
    var reloads = 0
    var source: InputBindingSource!

    init(_ text: String? = nil, menu: [(input: String, title: String)] = []) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("input.conf")
        if let text { try text.write(to: file, atomically: true, encoding: .utf8) }
        source = InputBindingSource(fileURL: file, reload: { [unowned self] in self.reloads += 1 },
                                    translateKey: { _, _ in nil }, menuRows: { menu })
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var text: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    var lines: [InputLine] { InputConf.parse(text).lines }

    func row(_ id: String) -> KeyBindingRowModel? { source.rows().first { $0.id == id } }
}

@MainActor
struct InputBindingSourceTests {
    private let f = InputTrigger.key(KeyChord(keyCode: nil, character: "f", modifiers: []))

    /// The menus' shortcuts come after the keys, read-only, and the search finds them by input and title.
    @Test func menuShortcutsAreReadOnlyRows() throws {
        let fixture = try Fixture(InputConfTemplate.text, menu: [("⌘T", "New Tab"), ("⇧⌘T", "Reopen Closed Tab")])
        let rows = fixture.source.rows()
        let menu = rows.filter { $0.source == "menu" }
        #expect(menu.map(\.input) == ["⌘T", "⇧⌘T"])
        #expect(menu.map(\.action) == ["New Tab", "Reopen Closed Tab"])
        #expect(menu.allSatisfy { !$0.isEditable && !$0.canRemove && !$0.canRestore && !$0.isMouse })
        #expect(rows.last?.input == "⇧⌘T" || rows.last?.isMouse == true)
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(fixture.source.searchTexts(mouse: false).contains("Reopen Closed Tab"))
        #expect(!fixture.source.searchTexts(mouse: true).contains("New Tab"))
        // Removing one is refused quietly: the file is not touched.
        let before = fixture.text
        try fixture.source.remove(rowID: menu[0].id)
        #expect(fixture.text == before)
    }

    @Test func bindWritesFileAndReloads() throws {
        let fixture = try Fixture(InputConfTemplate.text)
        var posted = 0
        let observer = NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: fixture.source,
                                                              queue: nil) { note in
            #expect(note.userInfo?["keys"] as? [String] == ["input.conf"])
            posted += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try fixture.source.bind(input: "f", action: "fill", step: nil)
        #expect(fixture.lines == [InputLine(trigger: f, action: .action(.fill), line: fixture.lines.first?.line ?? 0)])
        #expect(fixture.reloads == 1)
        #expect(posted == 1)
        let row = fixture.row("f")
        #expect(row?.action == "Fill the window")
        #expect(row?.source == "input.conf")
        #expect(row?.actionID == "fill")
        #expect(row?.canRestore == true)
        // The template's other lines stay as they were: only the f line changed.
        let before = InputConfTemplate.text.components(separatedBy: "\n")
        let after = fixture.text.components(separatedBy: "\n")
        #expect(before.count == after.count)
        #expect(zip(before, after).filter { $0 != $1 }.count == 1)
    }

    @Test func missingFileIsMadeFromTheTemplate() throws {
        let fixture = try Fixture()
        try fixture.source.bind(input: "MX_PANEL+WHEEL", action: "add vibrance-amount", step: 0.1)
        #expect(fixture.text.hasPrefix(String(InputConfTemplate.text.prefix(40))))
        #expect(fixture.lines.map(\.action) == [.add(key: "vibrance-amount", step: 0.1)])
        #expect(fixture.row("MX_PANEL+WHEEL")?.actionID == "add vibrance-amount")
        #expect(fixture.row("MX_PANEL+WHEEL")?.step == 0.1)
    }

    @Test func removeBuiltInWritesIgnore() throws {
        let fixture = try Fixture(InputConfTemplate.text)
        #expect(fixture.row("f")?.source == "built-in")
        try fixture.source.remove(rowID: "f")
        #expect(fixture.lines.map(\.action) == [.ignore])
        #expect(fixture.lines.first?.trigger == f)
        let row = fixture.row("f")
        #expect(row?.source == "off")
        #expect(row?.canRemove == false)
        #expect(row?.canRestore == true)
        #expect(row?.actionID == nil)
        // A built-in mouse binding the same way.
        try fixture.source.remove(rowID: "MX_GESTURE+WHEEL")
        #expect(fixture.row("MX_GESTURE+WHEEL")?.source == "off")
        #expect(fixture.lines.contains { $0.trigger == .mouse(.gesture, .wheel) && $0.action == .ignore })
        // Restore Built-in on an off row comments its ignore line out.
        try fixture.source.restoreBuiltIn(rowID: "f")
        #expect(fixture.row("f")?.source == "built-in")
        #expect(fixture.reloads == 3)
    }

    @Test func readOnlyFileIsNotOverwritten() throws {
        let fixture = try Fixture("g fit\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fixture.file.path)
        #expect(throws: CocoaError.self) { try fixture.source.bind(input: "f", action: "fill", step: nil) }
        do {
            try fixture.source.bind(input: "f", action: "fill", step: nil)
        } catch let error as CocoaError {
            #expect(error.code == .fileWriteNoPermission)
            #expect(error.userInfo[NSFilePathErrorKey] as? String == fixture.file.path)
        }
        #expect(fixture.text == "g fit\n")
        #expect(fixture.reloads == 0)
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o444)
    }

    @Test func removeFileLineCommentsOut() throws {
        let fixture = try Fixture("f fill   # mine\ng fit\n")
        #expect(fixture.row("f")?.source == "input.conf")
        try fixture.source.remove(rowID: "f")
        #expect(fixture.text == "# f fill   # mine\ng fit\n")
        #expect(fixture.row("f")?.source == "built-in")
        #expect(fixture.row("f")?.action == "Toggle full screen")
        // A file-only input goes away with its line.
        try fixture.source.restoreBuiltIn(rowID: "g")
        #expect(fixture.text == "# f fill   # mine\n# g fit\n")
        #expect(fixture.row("g") == nil)
    }

    @Test func mouseKindsDisabledWhenInvalid() throws {
        let fixture = try Fixture()
        let source = fixture.source!
        let right = source.pressKinds(for: "MBTN_RIGHT")
        #expect(right.first { $0.title == "Tap" }?.enabled == false)
        #expect(right.allSatisfy { !$0.enabled })
        let panel = source.pressKinds(for: "MX_PANEL")
        #expect(panel.map(\.id) == ["MX_PANEL", "MX_PANEL-long", "MX_PANEL+WHEEL", "MX_PANEL+MX_THUMB", "MX_PANEL+MOVE",
                                    "MBTN_RIGHT+MX_PANEL"])
        #expect(panel.map(\.enabled) == [true, true, true, true, true, false])
        #expect(source.pressKinds(for: "MBTN_MID").last?.enabled == true)
        #expect(source.mouseButtons().map(\.id) == ["MBTN_MID", "MBTN_BACK", "MBTN_FORWARD", "MX_PANEL", "MX_GESTURE",
                                                    "MX_SHIFT", "TP_3UP", "TP_3DOWN", "TP_3TAP", "TP_FORCE",
                                                    "TP_CLICK_DOWN", "TP_CLICK_UP"])
        // A trackpad gesture has only its tap.
        #expect(source.pressKinds(for: "TP_3UP").map(\.enabled) == [true, false, false, false, false, false])
    }

    /// Every action of the file is offered once, `ignore` is not (that is «−»), and `add` takes a step.
    @Test func actionGroupsOfferEveryAction() throws {
        let fixture = try Fixture()
        let source = fixture.source!
        let groups = source.actionGroups()
        #expect(groups.map(\.group) == ["Navigation", "Zoom", "Scaling", "Colour", "View", "Folder", "Tabs and windows"])
        let ids = groups.flatMap { $0.actions.map(\.id) }
        #expect(Set(ids).count == ids.count)
        let expected = KeyAction.allCases.map(InputConf.actionName) + ["zoom-step", "add auto-color-strength",
                                                                       "add vibrance-amount"]
        #expect(Set(ids) == Set(expected))
        let steps = groups.flatMap(\.actions).filter(\.takesStep).map(\.id)
        #expect(Set(steps) == ["add auto-color-strength", "add vibrance-amount"])
    }

    @Test func conflictNamesTheCurrentAction() throws {
        let fixture = try Fixture("g ignore\n")
        #expect(fixture.source.conflict(input: "f") == "Toggle full screen")
        #expect(fixture.source.conflict(input: "Shift+f") == fixture.source.conflict(input: "F"))
        #expect(fixture.source.conflict(input: "q") == nil)            // unbound
        #expect(fixture.source.conflict(input: "MBTN_MID") == "Fit / actual size at the pointer")
        #expect(fixture.source.conflict(input: "nonsense") == nil)
    }

    @Test func badInputIsRefused() throws {
        let fixture = try Fixture("")
        #expect(throws: (any Error).self) { try fixture.source.bind(input: "Cmd+f", action: "fit", step: nil) }
        #expect(throws: (any Error).self) { try fixture.source.bind(input: "f", action: "launch-rockets", step: nil) }
        #expect(throws: (any Error).self) { try fixture.source.bind(input: "f", action: "add vibrance-amount", step: 3) }
        #expect(fixture.text == "")
        #expect(fixture.reloads == 0)
    }

    /// The recorder: a letter by the Latin letter of its key (the Russian layout's а on F records `f`), ⌘ refused.
    @Test func recorderUsesTranslatedLetter() throws {
        let fixture = try Fixture()
        let source = InputBindingSource(fileURL: fixture.file, reload: {}, translateKey: { code, _ in code == 3 ? "f" : nil })
        func press(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                             keyCode: code)!
        }
        #expect(try source.keyToken(for: press("а", code: 3)).get() == "f")
        #expect(try source.keyToken(for: press("А", code: 3, .shift)).get() == "F")
        #expect(try source.keyToken(for: press("\u{F702}", code: 123, .option)).get() == "Alt+LEFT")
        #expect(throws: KeyBindingRefusal("⌘ and ⌃ shortcuts belong to the menus")) {
            try source.keyToken(for: press("f", code: 3, .command)).get()
        }
    }

    @Test func externalEditIsAnnouncedOnActivation() throws {
        let fixture = try Fixture("")
        var posted = 0
        let observer = NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: fixture.source,
                                                              queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = fixture.source.rows()
        fixture.source.checkForExternalChange()
        #expect(posted == 0)
        try "f fill\n".write(to: fixture.file, atomically: true, encoding: .utf8)
        fixture.source.checkForExternalChange()
        #expect(posted == 1)
        #expect(fixture.row("f")?.source == "input.conf")
    }

    /// Spec §7: the window's search finds the tables by their rows' inputs and actions, as shown and as the file
    /// writes them.
    @Test func searchFindsBindingRows() throws {
        let fixture = try Fixture("g add vibrance-amount 0.1\n")
        SettingsPanel.bindingSource = fixture.source
        defer { SettingsPanel.bindingSource = nil }
        let search = SettingsSearch(pages: SettingsPanel.pages())
        func found(_ query: String) -> Set<String> {
            Set(search.matches(query).filter { $0.page == "key-bindings" }.map(\.rowID))
        }
        #expect(found("MX_GESTURE+WHEEL") == ["#Mouse bindings"])
        #expect(found("add vibrance-amount") == ["#Keyboard bindings", "#Mouse bindings"])
        #expect(found("Gesture button + wheel") == ["#Mouse bindings"])
        #expect(found("Toggle full screen") == ["#Keyboard bindings"])
        // The vibrance rows of the Colour page are found too.
        #expect(search.matches("vibrance").contains { $0.page == "colour" })
    }
}
