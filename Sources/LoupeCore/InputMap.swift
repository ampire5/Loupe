/// The effective layout: the built-in keys (`KeyMap.standard`) and mouse buttons (`standardMouse`, spec §4), with the
/// lines of `input.conf` on top (spec §2.1). The view, the menus, the cheat sheet and the button recogniser read it.
public struct InputMap: Sendable, Equatable {
    /// The built-in mouse layout (spec §4), in the cheat sheet's order.
    public static let standardMouse: [(MouseButton, PressKind, InputAction)] = [
        (.panel, .tap, .action(.toggleAutoColor)),
        (.panel, .long, .action(.toggleVibrance)),
        (.panel, .wheel, .add(key: "auto-color-strength", step: 0.05)),
        (.panel, .move, .add(key: "vibrance-amount", step: 0.05)),
        (.middle, .tap, .action(.toggleFitActual)),
        (.middle, .long, .action(.fill)),
        (.back, .tap, .action(.back)),
        (.back, .long, .action(.cycleStats)),
        (.back, .wheel, .action(.nextFolder)),
        (.forward, .tap, .action(.toggleInfoPanel)),
        (.forward, .wheel, .zoomStep),
        (.gesture, .tap, .action(.cycleStats)),
        (.gesture, .wheel, .add(key: "vibrance-amount", step: 0.05)),
        (.middle, .withRight, .action(.fitWidth)),
        (.threeUp, .tap, .action(.browse)),
        (.threeDown, .tap, .action(.back)),
        (.threeTap, .tap, .action(.cycleStats)),
        (.forceClick, .tap, .action(.toggleInfoPanel)),
        (.clickDown, .tap, .action(.nextTab)),
        (.clickUp, .tap, .action(.previousTab)),
    ]

    /// The layout without `input.conf`.
    public static let standard = InputMap(lines: [])

    /// The keyboard table, built-in keys and the file's.
    public let keys: KeyMap
    private let buttons: [MouseInput: InputAction]

    struct MouseInput: Hashable, Sendable {
        let button: MouseButton
        let kind: PressKind
    }

    /// The built-in layout, then `lines` in order: a line replaces the binding of its input (built-in or from an
    /// earlier line, so the last line wins) and `ignore` only removes it.
    ///
    /// A key line takes its key (code or letter, with exactly its modifiers) out of every built-in binding: the other
    /// keys of a binding keep their action (`SPACE fit` leaves → and PgDn on `next`), and a binding left without key
    /// codes goes with its character (the digits' `"0"` doubles their codes). The file's bindings, `ignore` included
    /// (it matches the key so that nothing after it does), go in front of the built-in ones of their kind, ⇧/⌥ before
    /// plain: file ⇧/⌥, built-in ⇧/⌥, file plain, built-in plain — as plain keys ignore Shift, `Shift+f fit` must come
    /// before the built-in `f`.
    public init(lines: [InputLine]) {
        let merged = Self.merge(lines)
        if merged.fileKeys.isEmpty {
            keys = .standard
        } else {
            let file = merged.fileKeys.map { key in
                KeyBinding(keyCodes: key.chord.keyCode.map { [$0] } ?? [], character: key.chord.character,
                           modifiers: key.chord.modifiers, allowsRepeat: Self.repeats(key.input), input: key.input)
            }
            let modified = { (b: KeyBinding) in !b.modifiers.isEmpty }
            keys = KeyMap(bindings: file.filter(modified) + merged.builtIn.filter(modified)
                + file.filter { !modified($0) } + merged.builtIn.filter { !modified($0) })
        }
        var buttons = Dictionary(uniqueKeysWithValues: Self.standardMouse.map { (MouseInput(button: $0.0, kind: $0.1), $0.2) })
        for (input, file) in merged.fileButtons { buttons[input] = file.input == .ignore ? nil : file.input }
        self.buttons = buttons
    }

    /// What `lines` do to the built-in layout, before the tables are built: `init(lines:)` and `rows(lines:)` (the
    /// settings table) both read this, so they cannot disagree.
    struct Merged {
        /// The built-in key bindings that no line took a key from (a binding may have lost some of its keys).
        var builtIn: [KeyBinding]
        /// The key lines that count, one per chord (the last one), in file order.
        var fileKeys: [(chord: KeyChord, input: InputAction, line: Int)]
        /// The button lines that count, one per input (the last one); `ignore` is kept.
        var fileButtons: [MouseInput: (input: InputAction, line: Int)]
    }

    static func merge(_ lines: [InputLine]) -> Merged {
        var merged = Merged(builtIn: KeyMap.standard.bindings, fileKeys: [], fileButtons: [:])
        for line in lines {
            switch line.trigger {
            case .key(let chord):
                merged.builtIn = merged.builtIn.compactMap { Self.removing(chord, from: $0) }
                merged.fileKeys.removeAll { $0.chord == chord }
                merged.fileKeys.append((chord, line.action, line.line))
            case .mouse(let button, let kind):
                merged.fileButtons[MouseInput(button: button, kind: kind)] = (line.action, line.line)
            }
        }
        return merged
    }

    /// `b` without `chord`'s key, or nil when it has no key left. Only a binding with exactly the chord's modifiers
    /// loses it.
    private static func removing(_ chord: KeyChord, from b: KeyBinding) -> KeyBinding? {
        guard b.modifiers == chord.modifiers else { return b }
        var codes = b.keyCodes
        var character = b.character
        if let code = chord.keyCode, codes.contains(code) {
            codes.removeAll { $0 == code }
            if codes.isEmpty { return nil }                     // the character only doubled the codes
        } else if let c = chord.character, character == c {
            character = nil
            if codes.isEmpty { return nil }
        } else {
            return b
        }
        return KeyBinding(keyCodes: codes, character: character, modifiers: b.modifiers, allowsRepeat: b.allowsRepeat,
                          input: b.input)
    }

    /// Whether a held key repeats a file binding: as the action's built-in keys do (steps, pans, zoom), and for `add` and
    /// `zoom-step`.
    private static func repeats(_ input: InputAction) -> Bool {
        switch input {
        case .action(let a): repeatingActions.contains(a)
        case .add, .zoomStep: true
        case .ignore: false
        }
    }

    private static let repeatingActions = Set(KeyMap.standard.bindings.filter(\.allowsRepeat).compactMap(\.action))

    /// What pressing `b` that way does; nil when nothing is bound (or `ignore` removed it).
    public func mouse(_ b: MouseButton, _ k: PressKind) -> InputAction? {
        buttons[MouseInput(button: b, kind: k)]
    }

    /// The ways of pressing `b` that do something: what the button recogniser has to wait for.
    public func kinds(of b: MouseButton) -> Set<PressKind> {
        Set(buttons.keys.filter { $0.button == b }.map(\.kind))
    }

    /// The control IDs of the Logitech buttons with any binding: the ones to divert from the system.
    public var divertedCIDs: Set<UInt16> {
        Set(buttons.keys.compactMap(\.button.cid))
    }

    /// Whether any binding uses the thumb wheel, which is diverted from the system only then.
    public var wantsThumbWheel: Bool {
        buttons.keys.contains { $0.kind == .thumbWheel }
    }

    /// The cheat sheet's mouse rows: each bound input (`Panel (hold)`, `Panel + wheel`, …) and what it does, by button
    /// (as `standardMouse` lists them) and press kind, the right-button combinations last.
    public func mouseLabels() -> [(input: String, title: String)] {
        buttons.sorted { Self.order($0.key) < Self.order($1.key) }.map { input, action in
            let title = Self.mouseTitle(kind: input.kind, action: action)
            return (Self.name(input), title)
        }
    }

    /// What a button input does, as the cheat sheet words it: a folder or tab step on a held button's wheel, thumb wheel
    /// or move goes both ways (`next-folder`, `next-tab`: down is next), the action's title otherwise.
    static func mouseTitle(kind: PressKind, action: InputAction) -> String {
        switch (kind, action) {
        case (.wheel, .action(.nextFolder)), (.thumbWheel, .action(.nextFolder)), (.move, .action(.nextFolder)):
            "Next / previous folder"
        case (.wheel, .action(.previousFolder)), (.thumbWheel, .action(.previousFolder)), (.move, .action(.previousFolder)):
            "Previous / next folder"
        case (.wheel, .action(.nextTab)), (.thumbWheel, .action(.nextTab)), (.move, .action(.nextTab)):
            "Next / previous tab"
        case (.wheel, .action(.previousTab)), (.thumbWheel, .action(.previousTab)), (.move, .action(.previousTab)):
            "Previous / next tab"
        default: title(action)
        }
    }

    private static let buttonOrder: [MouseButton] = [.panel, .middle, .back, .forward, .gesture, .shift, .right,
                                                     .threeUp, .threeDown, .threeTap, .forceClick, .clickDown, .clickUp]
    private static let kindOrder: [PressKind] = [.tap, .long, .wheel, .thumbWheel, .move, .withRight]

    static func order(_ input: MouseInput) -> Int {
        let button = buttonOrder.firstIndex(of: input.button) ?? buttonOrder.count
        let kind = kindOrder.firstIndex(of: input.kind) ?? kindOrder.count
        return (input.kind == .withRight ? 1000 : 0) + button * 10 + kind
    }

    static func name(_ input: MouseInput) -> String {
        let button = switch input.button {
        case .panel: "Panel"
        case .middle: "Middle"
        case .back: "Back"
        case .forward: "Forward"
        case .gesture: "Gesture button"
        case .shift: "Wheel button"
        case .right: "Right"
        case .threeUp: "Three fingers up"
        case .threeDown: "Three fingers down"
        case .threeTap: "Three-finger tap"
        case .forceClick: "Force click"
        case .clickUp: "Click held + two fingers up"
        case .clickDown: "Click held + two fingers down"
        }
        return switch input.kind {
        case .tap: button
        case .long: "\(button) (hold)"
        case .wheel: "\(button) + wheel"
        case .thumbWheel: "\(button) + thumb wheel"
        case .move: "\(button) + move up/down"
        case .withRight: "Right + \(button.lowercased())"
        }
    }

    /// How the cheat sheet names what an input does: the action's title, or for `add` the folder value and the step
    /// (`Auto colour strength ±0.05`; `∓` when the wheel up subtracts).
    public static func title(_ a: InputAction) -> String {
        switch a {
        case .action(let action):
            return KeyMap.titles[action]?.title ?? action.rawValue
        case .add(let key, let step):
            let name = switch key {
            case "auto-color-strength": "Auto colour strength"
            case "vibrance-amount": "Vibrance amount"
            default: key
            }
            return "\(name) \(step < 0 ? "∓" : "±")\(decimal(abs(step)))"
        case .zoomStep:
            return "Zoom in / out at the pointer"
        case .ignore:
            return "Unbound"
        }
    }

    /// A step as the toasts write values: two decimals, more when the step has them (up to four).
    private static func decimal(_ value: Double) -> String {
        let scaled = Int((value * 10_000).rounded())
        var fraction = String(scaled % 10_000)
        fraction = String(repeating: "0", count: 4 - fraction.count) + fraction
        while fraction.count > 2, fraction.hasSuffix("0") { fraction.removeLast() }
        return "\(scaled / 10_000).\(fraction)"
    }
}
