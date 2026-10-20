/// One row of the Key Bindings table in the settings panel (spec §8.1): an input, what it does and where the binding
/// comes from.
public struct BindingRow: Equatable, Sendable {
    public enum Source: Sendable, Equatable {
        case builtIn
        /// An active line of `input.conf`, 1-based.
        case file(line: Int)
        /// An `ignore` line: the input is unbound.
        case off
    }

    public let trigger: InputTrigger
    /// The input as the cheat sheet shows it: `⇧L`, `Space`, `Panel (hold)`, `Back + wheel`, `Right + middle`.
    public let input: String
    public let action: InputAction
    /// What the cheat sheet says: `InputMap.title(action)`, and for a folder step on a held button's wheel or move
    /// `InputMap.mouseTitle`.
    public let title: String
    public let source: Source

    public init(trigger: InputTrigger, input: String, action: InputAction, title: String, source: Source) {
        self.trigger = trigger
        self.input = input
        self.action = action
        self.title = title
        self.source = source
    }

    public var isMouse: Bool {
        if case .mouse = trigger { true } else { false }
    }
}

extension InputMap {
    /// The effective layout as table rows: the built-in layout with `lines` on top, merged by the function that builds
    /// `InputMap(lines:)`. Keys come in `KeyMap.standard` order, one row per key of a binding (`next` has →, Space and
    /// PgDn), a key the file rebinds or ignores staying where the built-in one was, then the file's other keys in file
    /// order; buttons follow in `mouseLabels()` order. An `ignore` line gives an `.off` row with the action `ignore`.
    public static func rows(lines: [InputLine]) -> [BindingRow] {
        let merged = merge(lines)
        var rows: [BindingRow] = []
        var shown: Set<KeyChord> = []
        func append(_ chord: KeyChord, builtIn action: InputAction) {
            guard shown.insert(chord).inserted else { return }
            if let file = merged.fileKeys.first(where: { $0.chord == chord }) {
                rows.append(row(.key(chord), file.input, file.input == .ignore ? .off : .file(line: file.line)))
            } else {
                rows.append(row(.key(chord), action, .builtIn))
            }
        }
        for b in KeyMap.standard.bindings {
            for code in b.keyCodes { append(KeyChord(keyCode: code, character: nil, modifiers: b.modifiers), builtIn: b.input) }
            // A digit's character only doubles its key codes.
            if b.keyCodes.isEmpty, let c = b.character {
                append(KeyChord(keyCode: nil, character: c, modifiers: b.modifiers), builtIn: b.input)
            }
        }
        for file in merged.fileKeys { append(file.chord, builtIn: file.input) }

        let standard = Dictionary(uniqueKeysWithValues: standardMouse.map { (MouseInput(button: $0.0, kind: $0.1), $0.2) })
        let inputs = Set(standard.keys).union(merged.fileButtons.keys).sorted { order($0) < order($1) }
        for input in inputs {
            let trigger = InputTrigger.mouse(input.button, input.kind)
            if let file = merged.fileButtons[input] {
                rows.append(row(trigger, file.input, file.input == .ignore ? .off : .file(line: file.line)))
            } else if let action = standard[input] {
                rows.append(row(trigger, action, .builtIn))
            }
        }
        return rows
    }

    private static func row(_ trigger: InputTrigger, _ action: InputAction, _ source: BindingRow.Source) -> BindingRow {
        let title = if case .mouse(_, let kind) = trigger { mouseTitle(kind: kind, action: action) } else { title(action) }
        return BindingRow(trigger: trigger, input: displayName(of: trigger), action: action, title: title, source: source)
    }

    /// An input as the cheat sheet names it: `KeyMap.keyNames` for a key, the mouse names of `mouseLabels()` for a button.
    static func displayName(of trigger: InputTrigger) -> String {
        switch trigger {
        case .mouse(let button, let kind):
            return name(MouseInput(button: button, kind: kind))
        case .key(let chord):
            let binding = KeyBinding(keyCodes: chord.keyCode.map { [$0] } ?? [], character: chord.character,
                                     modifiers: chord.modifiers, allowsRepeat: false, input: .ignore)
            // The table tells the keypad's keys from the top row's (`0` twice); the cheat sheet does not.
            let keypad: Set<UInt16> = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 78]
            guard let name = KeyMap.keyNames(binding).first else { return InputConf.text(of: trigger) }
            guard let code = chord.keyCode, keypad.contains(code), let key = KeyMap.keyName(code) else { return name }
            return name.dropLast(key.count) + "Keypad " + key
        }
    }
}

/// Why the key recorder does not take a press.
public enum KeyTokenRefusal: Error, Equatable, Sendable {
    /// ⌘ or ⌃ held: those chords belong to the menus.
    case menuModifier
    /// A key `input.conf` has no name for.
    case unknownKey

    /// The line under the recorder.
    public var text: String {
        switch self {
        case .menuModifier: "⌘ and ⌃ shortcuts belong to the menus"
        case .unknownKey: "This key cannot be bound"
        }
    }
}

extension InputConf {
    /// What the key recorder writes for a press, by the rules of the file (spec §8.2): a letter by the Latin letter the
    /// key types on any layout (`latinCharacter`, from `KeyboardLayout`; on the Russian layout F stays `f`), a capital
    /// with Shift; any other key by its name (`LEFT`, `KP_ADD`), `Shift+` and `Alt+` in front. ⌘ and ⌃ are refused.
    public static func keyToken(keyCode: UInt16, latinCharacter: String?, shift: Bool, option: Bool, command: Bool,
                                control: Bool) -> Result<String, KeyTokenRefusal> {
        if command || control { return .failure(.menuModifier) }
        var modifiers: KeyModifiers = []
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        let chord: KeyChord
        if keyNames[keyCode] != nil {
            chord = KeyChord(keyCode: keyCode, character: nil, modifiers: modifiers)
        } else if let c = latinCharacter, c.count == 1, let first = c.first, first.isASCII, first.isLetter {
            chord = KeyChord(keyCode: nil, character: c.lowercased(), modifiers: modifiers)
        } else {
            return .failure(.unknownKey)
        }
        let token = text(of: .key(chord))
        return trigger(token) == .key(chord) ? .success(token) : .failure(.unknownKey)
    }
}
