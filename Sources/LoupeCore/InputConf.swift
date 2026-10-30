/// A mouse or Logitech button an `input.conf` line can bind. The raw value is its name in the file.
public enum MouseButton: String, CaseIterable, Sendable {
    case middle = "MBTN_MID", back = "MBTN_BACK", forward = "MBTN_FORWARD", right = "MBTN_RIGHT"
    case panel = "MX_PANEL", gesture = "MX_GESTURE", shift = "MX_SHIFT"
    /// Trackpad gestures, bound like a button's tap (no other press kinds): three fingers swiped up or down or tapped,
    /// a force click, and a click held while two other fingers swipe up or down.
    case threeUp = "TP_3UP", threeDown = "TP_3DOWN", threeTap = "TP_3TAP", forceClick = "TP_FORCE"
    case clickUp = "TP_CLICK_UP", clickDown = "TP_CLICK_DOWN"

    /// A trackpad gesture rather than a mouse button: only its tap exists.
    public var isTrackpad: Bool {
        switch self {
        case .threeUp, .threeDown, .threeTap, .forceClick, .clickUp, .clickDown: true
        default: false
        }
    }

    /// The control ID the button has in LogiHIDPP's table; nil for the buttons macOS reports itself.
    public var cid: UInt16? {
        switch self {
        case .panel: 0x01A0
        case .gesture: 0x00C3
        case .shift: 0x00C4
        case .middle, .back, .forward, .right, .threeUp, .threeDown, .threeTap, .forceClick, .clickUp, .clickDown: nil
        }
    }
}

/// How a button is pressed: a short tap, a long press, held with the wheel / the thumb wheel / a move, or the
/// middle button pressed while the right one is held.
public enum PressKind: Hashable, Sendable { case tap, long, wheel, thumbWheel, move, withRight, withRightWheel }

/// A key and its modifiers, as `input.conf` names it: a letter by `character` (lowercase), everything else by
/// `keyCode`; exactly one of the two is set.
public struct KeyChord: Hashable, Sendable {
    public let keyCode: UInt16?
    public let character: String?
    public let modifiers: KeyModifiers

    public init(keyCode: UInt16?, character: String?, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.character = character
        self.modifiers = modifiers
    }
}

/// What an `input.conf` line binds: a key, or a button pressed in one of the ways.
public enum InputTrigger: Hashable, Sendable {
    case key(KeyChord)
    case mouse(MouseButton, PressKind)
}

/// What a line does: a `KeyAction`, `add` (a step added to a folder's number), `zoom-step` (zoom stops at the pointer,
/// M4c spec §12.3), or `ignore` (unbinds the input). `add` and `zoom-step` take a held button's signed wheel / move
/// steps; on a press or a key they make one step up.
public enum InputAction: Hashable, Sendable {
    case action(KeyAction)
    case add(key: String, step: Double)
    case zoomStep
    case ignore

    /// The folder step (+1 next, -1 previous) of a held button's wheel or move step bound to `next-folder` /
    /// `previous-folder`, by the step's sign (`steps` positive = up): `next-folder` goes on to the next folder on the
    /// way down, as the plain wheel shows the next photo (`wheel-direction=content`), and back on the way up;
    /// `previous-folder` the other way round. Nil for any other action or no step.
    public func folderStep(steps: Int) -> Int? { step(steps, next: .nextFolder, previous: .previousFolder) }

    /// The tab step (+1 next, -1 previous) of a held button's wheel or move step bound to `next-tab` / `previous-tab`,
    /// the same way round as `folderStep`. Nil for any other action or no step.
    public func tabStep(steps: Int) -> Int? { step(steps, next: .nextTab, previous: .previousTab) }

    private func step(_ steps: Int, next: KeyAction, previous: KeyAction) -> Int? {
        guard steps != 0, case .action(let a) = self, a == next || a == previous else { return nil }
        return (a == next) == (steps < 0) ? 1 : -1
    }
}

/// One parsed line of `input.conf`, with its 1-based line number.
public struct InputLine: Sendable, Equatable {
    public let trigger: InputTrigger
    public let action: InputAction
    public let line: Int

    public init(trigger: InputTrigger, action: InputAction, line: Int) {
        self.trigger = trigger
        self.action = action
        self.line = line
    }
}

/// `~/.config/loupe/input.conf`, mpv style: `<input> <action> [arguments]  # comment`. This is the pure part, the
/// names and the line parser; what the lines do to the built-in layout is decided elsewhere.
public enum InputConf {
    public static let fileName = "input.conf"

    /// The keys `add` can change, with the wording of the problem for anything else.
    private static let addKeys: Set<String> = ["auto-color-strength", "vibrance-amount"]

    /// Parses the file's text. A line with a problem is skipped and named in `warnings` (`input.conf:<line>: …`), the
    /// rest apply; a BOM, CRLF, tabs and trailing `#` comments are fine.
    public static func parse(_ text: String) -> (lines: [InputLine], warnings: [String]) {
        var lines: [InputLine] = []
        var warnings: [String] = []
        var text = Substring(text)
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        let rows = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        for (index, row) in rows.enumerated() {
            let number = index + 1
            let content = row.prefix { $0 != "#" }
            let tokens = content.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = tokens.first else { continue }
            func warn(_ problem: String) { warnings.append("input.conf:\(number): \(problem)") }
            let trigger: InputTrigger
            switch resolve(first) {
            case .success(let t): trigger = t
            case .failure(let problem): warn(problem.text); continue
            }
            guard tokens.count > 1 else { warn("missing action"); continue }
            switch parseAction(Array(tokens.dropFirst())) {
            case .success(let action): lines.append(InputLine(trigger: trigger, action: action, line: number))
            case .failure(let problem): warn(problem.text)
            }
        }
        return (lines, warnings)
    }

    /// The input a name stands for (`f`, `Shift+LEFT`, `MX_PANEL+WHEEL`), or nil when it is not a usable input.
    public static func trigger(_ name: String) -> InputTrigger? {
        guard case .success(let t) = resolve(name) else { return nil }
        return t
    }

    /// The action's name in the file: its case name in kebab-case, digits set off (`actual100` is `actual-100`).
    public static func actionName(_ a: KeyAction) -> String {
        var out = ""
        var previous: Character?
        for c in a.rawValue {
            if let p = previous, (c.isUppercase && !p.isUppercase) || (c.isNumber && p.isLetter) { out.append("-") }
            out.append(contentsOf: c.lowercased())
            previous = c
        }
        return out
    }

    /// The action a name stands for; nil for an unknown name and for `ignore`, which is not a `KeyAction`.
    public static func action(named name: String) -> KeyAction? { actionsByName[name] }

    private static let actionsByName: [String: KeyAction] =
        Dictionary(uniqueKeysWithValues: KeyAction.allCases.map { (actionName($0), $0) })

    /// Whether the action switches something (`toggle-*`, `cycle-*`, except `toggle-fit-actual`, a zoom rather than a
    /// switch): done from a key or a mouse button, the mouse answers with `haptic-toggle` (M4c spec §5).
    public static func isToggle(_ a: KeyAction) -> Bool {
        guard a != .toggleFitActual else { return false }
        let name = actionName(a)
        return name.hasPrefix("toggle-") || name.hasPrefix("cycle-")
    }

    // MARK: - Back to text

    /// The input as the file names it, the spelling the template uses: a letter by character, a capital for Shift+letter
    /// (`L`), everything else by key name (`Shift+LEFT`, `KP_ADD`, `?` for Shift+/), `Alt+` for ⌥, a button with its press
    /// kind (`MX_PANEL-long`, `MBTN_BACK+WHEEL`, `MBTN_RIGHT+MBTN_MID`). `trigger(_:)` reads it back as the same input.
    public static func text(of trigger: InputTrigger) -> String {
        switch trigger {
        case .mouse(let button, let kind):
            let name = button.rawValue
            return switch kind {
            case .tap: name
            case .long: name + "-long"
            case .wheel: name + "+WHEEL"
            case .thumbWheel: name + "+MX_THUMB"
            case .move: name + "+MOVE"
            case .withRight: "MBTN_RIGHT+" + name
            case .withRightWheel: "MBTN_RIGHT+" + name + "+WHEEL"
            }
        case .key(let chord):
            var modifiers = chord.modifiers
            var name: String
            if let c = chord.character, c.count == 1, c.first!.isASCII, c.first!.isLetter {
                name = modifiers.contains(.shift) ? c.uppercased() : c.lowercased()
                modifiers.remove(.shift)
            } else if let code = chord.keyCode {
                if code == 44, modifiers.contains(.shift) {
                    name = "?"                                   // ? is Shift+/
                    modifiers.remove(.shift)
                } else {
                    name = keyNames[code] ?? "KEY\(code)"
                }
            } else {
                name = chord.character ?? ""
            }
            if modifiers.contains(.option) { name = "Alt+" + name }
            if modifiers.contains(.shift) { name = "Shift+" + name }
            return name
        }
    }

    /// The action as the file names it: `fit`, `add vibrance-amount 0.05`, `zoom-step`, `ignore`.
    public static func text(of action: InputAction) -> String {
        switch action {
        case .action(let a): actionName(a)
        case .add(let key, let step): "add \(key) \(stepText(step))"
        case .zoomStep: "zoom-step"
        case .ignore: "ignore"
        }
    }

    /// A step in its shortest spelling: `0.05`, `-0.25`, `1`.
    private static func stepText(_ step: Double) -> String {
        step == step.rounded() && abs(step) < 1e9 ? String(Int(step)) : "\(step)"
    }

    static let keyNames: [UInt16: String] =
        Dictionary(keyCodes.map { ($0.value, $0.key) }, uniquingKeysWith: { min($0, $1) })

    // MARK: - Inputs

    private struct Problem: Error { let text: String }

    private static func resolve(_ name: String) -> Result<InputTrigger, Problem> {
        let unknown = Problem(text: "unknown input \"\(name)\"")
        if name.hasPrefix("MBTN_RIGHT+"), name != "MBTN_RIGHT+WHEEL" {
            let rest = String(name.dropFirst("MBTN_RIGHT+".count))
            if rest.hasSuffix("+WHEEL"), let button = MouseButton(rawValue: String(rest.dropLast(6))),
               button != .right, !button.isTrackpad {
                return .success(.mouse(button, .withRightWheel))
            }
            if let button = MouseButton(rawValue: rest), button != .right, !button.isTrackpad {
                return .success(.mouse(button, .withRight))
            }
            return .failure(unknown)
        }
        // A press kind after a name: `-long` or `+WHEEL`, `+MX_THUMB`, `+MOVE`.
        let kinds: [(suffix: String, kind: PressKind)] = [("-long", .long), ("+WHEEL", .wheel), ("+MX_THUMB", .thumbWheel), ("+MOVE", .move)]
        for (suffix, kind) in kinds where name.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            if let button = MouseButton(rawValue: base) {
                if button.isTrackpad { return .failure(Problem(text: "trackpad gestures take no press kind")) }
                return button == .right && kind != .wheel ? .failure(rightOnly) : .success(.mouse(button, kind))
            }
            if case .success = resolveKey(base) { return .failure(Problem(text: "press kinds are for mouse buttons")) }
            return .failure(unknown)
        }
        if name.hasPrefix("MBTN_RIGHT+") {
            return name == "MBTN_RIGHT+MBTN_MID" ? .success(.mouse(.middle, .withRight)) : .failure(unknown)
        }
        if let button = MouseButton(rawValue: name) {
            return button == .right ? .failure(rightOnly) : .success(.mouse(button, .tap))
        }
        switch resolveKey(name) {
        case .success(let t): return .success(t)
        case .failure(.menus): return .failure(Problem(text: "⌘ and ⌃ belong to the menus"))
        case .failure(.notAKey): return .failure(unknown)
        }
    }

    private static let rightOnly = Problem(text: "MBTN_RIGHT requires a button or wheel combination")

    private enum KeyFailure: Error { case notAKey, menus }

    /// A key with its modifiers; ⌘ and ⌃ are told apart from a name that is no key at all.
    private static func resolveKey(_ name: String) -> Result<InputTrigger, KeyFailure> {
        var rest = Substring(name)
        var modifiers: KeyModifiers = []
        while let plus = rest.firstIndex(of: "+"), plus != rest.startIndex, rest.index(after: plus) != rest.endIndex {
            switch rest[..<plus].lowercased() {
            case "shift": modifiers.insert(.shift)
            case "alt": modifiers.insert(.option)
            case "cmd", "command", "ctrl", "control", "meta", "super":
                return .failure(.menus)
            default: return .failure(.notAKey)
            }
            rest = rest[rest.index(after: plus)...]
        }
        let key = String(rest)
        if key.count == 1, let c = key.first, c.isASCII, c.isLetter {
            if c.isUppercase { modifiers.insert(.shift) }
            return .success(.key(KeyChord(keyCode: nil, character: key.lowercased(), modifiers: modifiers)))
        }
        if key == "?" { return .success(.key(KeyChord(keyCode: 44, character: nil, modifiers: modifiers.union(.shift)))) }
        guard let code = keyCodes[key] else { return .failure(.notAKey) }
        return .success(.key(KeyChord(keyCode: code, character: nil, modifiers: modifiers)))
    }

    /// The names of the keys that are not letters, and their positions (virtual key codes).
    static let keyCodes: [String: UInt16] = {
        var table: [String: UInt16] = [
            "LEFT": 123, "RIGHT": 124, "DOWN": 125, "UP": 126, "SPACE": 49, "BS": 51, "PGUP": 116, "PGDWN": 121,
            "HOME": 115, "END": 119, "ESC": 53, "[": 33, "]": 30, "/": 44, "=": 24, "-": 27,
            "KP_ADD": 69, "KP_SUBTRACT": 78, "ENTER": 36, "KP_ENTER": 76,
        ]
        let digits: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        let keypad: [UInt16] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for d in 0...9 {
            table["\(d)"] = digits[d]
            table["KP\(d)"] = keypad[d]
        }
        return table
    }()

    // MARK: - Actions

    private static func parseAction(_ tokens: [String]) -> Result<InputAction, Problem> {
        let name = tokens[0]
        let arguments = tokens.dropFirst()
        if name == "add" { return parseAdd(Array(arguments)) }
        let action: InputAction
        if name == "ignore" {
            action = .ignore
        } else if name == "zoom-step" {
            action = .zoomStep
        } else if let a = Self.action(named: name) {
            action = .action(a)
        } else {
            return .failure(Problem(text: "unknown action \"\(name)\""))
        }
        return arguments.isEmpty ? .success(action) : .failure(Problem(text: "\(name) takes no arguments"))
    }

    private static func parseAdd(_ arguments: [String]) -> Result<InputAction, Problem> {
        guard let key = arguments.first, addKeys.contains(key) else {
            return .failure(Problem(text: "add takes auto-color-strength or vibrance-amount"))
        }
        guard arguments.count > 1 else { return .failure(Problem(text: "add needs a step")) }
        guard arguments.count == 2 else { return .failure(Problem(text: "add takes a key and a step, nothing more")) }
        guard let step = Double(arguments[1]), step.isFinite, (0.01...1).contains(abs(step)) else {
            return .failure(Problem(text: "step must be 0.01…1 in size"))
        }
        return .success(.add(key: key, step: step))
    }
}
