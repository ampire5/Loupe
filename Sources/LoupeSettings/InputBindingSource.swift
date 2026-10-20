import AppKit
import LoupeCore
import SettingsKit

/// The Key Bindings page's table over `input.conf` (spec §8): the effective layout as `InputMap.rows` builds it, edits
/// written in place by `InputConfText`. After a write it runs `reload` (the app's `Settings.reload()`: menus, the `?`
/// sheet and the mouse follow at once) and posts `.settingsStoreDidChange` (object self, keys `["input.conf"]`); an edit
/// made in a text editor is announced the same way when the app becomes active again.
@MainActor
public final class InputBindingSource: KeyBindingSource {
    public let fileURL: URL
    private let reload: @MainActor () -> Void
    private let translateKey: (UInt16, Bool) -> String?
    private let menuRows: @MainActor () -> [(input: String, title: String)]
    /// The file's text as last read (nil: no file), to tell an outside edit from none.
    private var lastText: String?
    private nonisolated(unsafe) var activeObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - reload: re-reads `input.conf` into the app (`Settings.reload()`).
    ///   - translateKey: the Latin character a key code types with or without Shift (`KeyboardLayout.translate`), so
    ///     a letter records by its Latin letter on any layout.
    ///   - menuRows: the menus' shortcuts (`⇧⌘T`, `Reopen Closed Tab`), shown after the keys and not edited here.
    public init(fileURL: URL, reload: @escaping @MainActor () -> Void,
                translateKey: @escaping (UInt16, Bool) -> String?,
                menuRows: @escaping @MainActor () -> [(input: String, title: String)] = { [] }) {
        self.fileURL = fileURL
        self.reload = reload
        self.translateKey = translateKey
        self.menuRows = menuRows
        lastText = Self.read(fileURL)
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForExternalChange() }
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    /// Re-reads the file and announces it when it changed since the last read (an edit in a text editor).
    func checkForExternalChange() {
        let text = Self.read(fileURL)
        guard text != lastText else { return }
        lastText = text
        announce()
    }

    // MARK: Rows

    /// The table's rows: `InputMap.rows` over the file's lines.
    func bindingRows() -> [BindingRow] {
        InputMap.rows(lines: InputConf.parse(Self.read(fileURL) ?? "").lines)
    }

    public func rows() -> [KeyBindingRowModel] {
        let menu = menuRows().map { row in
            KeyBindingRowModel(id: Self.menuPrefix + row.input, input: row.input, action: row.title, source: "menu",
                               isMouse: false, canRemove: false, isEditable: false)
        }
        let file = bindingRows().map { row in
            let off = row.source == .off
            let fromFile = row.source != .builtIn
            let source = switch row.source {
            case .builtIn: "built-in"
            case .file: "input.conf"
            case .off: "off"
            }
            return KeyBindingRowModel(
                id: InputConf.text(of: row.trigger), input: row.input, action: row.title, source: source,
                isMouse: row.isMouse, actionID: off ? nil : Self.actionID(row.action), step: Self.step(row.action),
                canRestore: fromFile, canRemove: !off)
        }
        let keys = file.filter { !$0.isMouse }
        return keys + menu + file.filter(\.isMouse)
    }

    /// A menu row's id: no input of the file starts so, so `remove` and `restoreBuiltIn` pass it by.
    private static let menuPrefix = "menu "

    /// Under the keyboard table: where the menu rows are changed.
    public static let menuNote = "Menu shortcuts: System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts"

    /// What the window's search finds the table by: each row's input (as shown and as the file writes it) and action
    /// (its title and its name in the file, `add vibrance-amount 0.05`).
    func searchTexts(mouse: Bool) -> [String] {
        let file = bindingRows().filter { $0.isMouse == mouse }.flatMap { row in
            [row.input, InputConf.text(of: row.trigger), row.title, InputConf.text(of: row.action)]
        }
        return mouse ? file : file + menuRows().flatMap { [$0.input, $0.title] }
    }

    // MARK: Sheet

    /// The pop-up's groups (spec §8.2): the cheat sheet's sections, with folder steps apart, `zoom-step` and `add`
    /// where they belong, and the tab and window actions last. `ignore` is «−», not an action.
    public func actionGroups() -> [(group: String, actions: [(id: String, title: String, takesStep: Bool)])] {
        typealias Item = (id: String, title: String, takesStep: Bool)
        func items(_ group: KeyGroup) -> [Item] {
            KeyAction.allCases.filter { KeyMap.standard.label($0).group == group && !Self.folderSteps.contains($0) }
                .map { (InputConf.actionName($0), KeyMap.standard.label($0).title, false) }
        }
        let zoomStep: Item = ("zoom-step", InputMap.title(.zoomStep), false)
        let adds: [Item] = ["auto-color-strength", "vibrance-amount"].map { key in
            ("add " + key, Self.addTitles[key] ?? key, true)
        }
        let folder: [Item] = Self.folderSteps.map { (InputConf.actionName($0), KeyMap.standard.label($0).title, false) }
        return [("Navigation", items(.navigation)), ("Zoom", items(.zoom) + [zoomStep]), ("Scaling", items(.scaling)),
                ("Colour", items(.colour) + adds), ("View", items(.view)), ("Folder", folder),
                ("Tabs and windows", items(.tabs))]
    }

    private static let folderSteps: [KeyAction] = [.previousFolder, .nextFolder]
    private static let addTitles = ["auto-color-strength": "Change auto colour strength",
                                    "vibrance-amount": "Change vibrance amount"]

    /// The buttons the sheet offers (spec §8.2); `MBTN_RIGHT` only comes with the middle button.
    public func mouseButtons() -> [(id: String, title: String)] {
        [(MouseButton.middle, "Middle"), (.back, "Back"), (.forward, "Forward"), (.panel, "Panel"),
         (.gesture, "Gesture button"), (.shift, "Wheel button"),
         (.threeUp, "Trackpad: three fingers up"), (.threeDown, "Trackpad: three fingers down"),
         (.threeTap, "Trackpad: three-finger tap"), (.forceClick, "Trackpad: force click"),
         (.clickDown, "Trackpad: click held + two fingers down"),
         (.clickUp, "Trackpad: click held + two fingers up")].map { ($0.0.rawValue, $0.1) }
    }

    /// Every press kind of `button`, disabled where `InputConf.trigger` does not take the combination.
    public func pressKinds(for button: String) -> [(id: String, title: String, enabled: Bool)] {
        let kinds: [(PressKind, String)] = [(.tap, "Tap"), (.long, "Long press"), (.wheel, "+ wheel"),
                                            (.thumbWheel, "+ thumb wheel"), (.move, "+ move up/down"),
                                            (.withRight, "With right button")]
        guard let b = MouseButton(rawValue: button) else { return [] }
        return kinds.map { kind, title in
            let text = InputConf.text(of: .mouse(b, kind))
            return (text, title, InputConf.trigger(text) == .mouse(b, kind))
        }
    }

    public func keyToken(for event: NSEvent) -> Result<String, KeyBindingRefusal> {
        let flags = event.modifierFlags
        let latin = translateKey(event.keyCode, false) ?? event.charactersIgnoringModifiers
        return InputConf.keyToken(keyCode: event.keyCode, latinCharacter: latin, shift: flags.contains(.shift),
                                  option: flags.contains(.option), command: flags.contains(.command),
                                  control: flags.contains(.control))
            .mapError { KeyBindingRefusal($0.text) }
    }

    public func conflict(input: String) -> String? {
        guard let trigger = InputConf.trigger(input),
              let row = bindingRows().first(where: { $0.trigger == trigger }), row.source != .off else { return nil }
        return row.title
    }

    // MARK: Writes

    /// A problem with what the sheet asked for (it offers only good inputs and actions).
    struct Refused: LocalizedError {
        let errorDescription: String?
    }

    public func bind(input: String, action: String, step: Double?) throws {
        guard let trigger = InputConf.trigger(input) else { throw Refused(errorDescription: "\(input) is not an input") }
        guard let parsed = Self.action(action, step: step) else {
            throw Refused(errorDescription: "\(action) is not an action input.conf takes")
        }
        try write { InputConfText.binding(trigger, to: parsed, in: $0) }
    }

    /// A built-in binding gets an `ignore` line; a line of the file is commented out (the built-in one, if any, is
    /// back). An input that is off already is left alone.
    public func remove(rowID: String) throws {
        guard let trigger = InputConf.trigger(rowID),
              let row = bindingRows().first(where: { $0.trigger == trigger }) else { return }
        switch row.source {
        case .builtIn: try write { InputConfText.binding(trigger, to: .ignore, in: $0) }
        case .file: try write { InputConfText.restoringBuiltIn(trigger, in: $0) }
        case .off: return
        }
    }

    public func restoreBuiltIn(rowID: String) throws {
        guard let trigger = InputConf.trigger(rowID) else { return }
        try write { InputConfText.restoringBuiltIn(trigger, in: $0) }
    }

    /// Reads the file (the template when there is none yet), writes what `change` makes of it, then reloads and
    /// announces. A file that exists but cannot be read, or is read-only, is not overwritten.
    private func write(_ change: (String) -> String) throws {
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        let text = exists ? try String(contentsOf: fileURL, encoding: .utf8) : InputConfTemplate.text
        let updated = change(text)
        guard updated != text || !exists else { return }
        try requireWritable(fileURL)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
        lastText = updated
        reload()
        announce()
    }

    private func announce() {
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": ["input.conf"]])
    }

    // MARK: Actions

    /// The pop-up item of an action: its name in the file, `add <key>` without the step.
    static func actionID(_ action: InputAction) -> String {
        if case .add(let key, _) = action { return "add " + key }
        return InputConf.text(of: action)
    }

    static func step(_ action: InputAction) -> Double? {
        if case .add(_, let step) = action { return step }
        return nil
    }

    /// The action an item and step stand for, read back through `InputConf.parse` so the file's rules decide.
    static func action(_ id: String, step: Double?) -> InputAction? {
        guard id != "ignore" else { return nil }
        let text = "f " + id + (step.map { " \($0)" } ?? "")
        let parsed = InputConf.parse(text)
        guard parsed.warnings.isEmpty, let line = parsed.lines.first else { return nil }
        return line.action
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}
