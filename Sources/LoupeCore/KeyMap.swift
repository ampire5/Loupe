/// What a key press does in the viewer. One case per action of `ViewerView.keyDown`, so the view's `switch`
/// and the `?` cheat sheet read the same table (`KeyMap.standard`).
public enum KeyAction: String, CaseIterable, Sendable {
    case previous, next, previousFolder, nextFolder, first, last
    case exitFullScreen
    case fit, actual100, actual200, actual400, fitWidth, fitHeight, fill, toggleFitActual, zoomIn, zoomOut
    case toggleKeepZoom, saveKeepZoom
    /// `keep-zoom-as` for the folder (`share` ↔ `scale`), and as the loupe.conf default.
    case toggleZoomCarry, saveZoomCarry
    case toggleFullScreen, cycleStats, toggleStrip, toggleStripPlacement, cheatSheet, toggleInfoPanel
    case cyclePanIndicators, savePanIndicators
    case panLeft, panRight, panUp, panDown
    case cycleFilter, saveFilters, toggleAntiring, saveAntiring
    case toggleAutoColor, saveAutoColor, toggleVibrance, saveVibrance
    /// Tabs and windows, as ⌘T, ⌘N, ⌘W and ⌘⇧] / ⌘⇧[ do: no built-in key or button, only `input.conf` lines.
    case newTab, newWindow, closeTab, nextTab, previousTab
    /// File › Open in New Tab / Open in New Window: the Open panel, then a new tab or window whatever `open-in` says.
    case openInNewTab, openInNewWindow
    /// Home in this tab (File › Home, ⇧⌘H).
    case home
    /// The Folders tab on the photo's folder, the photo selected (Return, a double click; file browser spec §4.4).
    case browse
    /// File › Back (⌘[), Reopen Closed Tab (⇧⌘T), Close Window (⇧⌘W).
    case back, reopenTab, closeWindow
}

/// The modifiers a binding can ask for. ⌘ and ⌃ never reach the table: the view hands them to the menus.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
}

/// The cheat sheet's sections.
public enum KeyGroup: String, CaseIterable, Sendable { case navigation, zoom, scaling, colour, view, tabs }

/// One key (or several keys that do the same) and what it does. A key is named by its position
/// (`keyCodes`, for keys whose meaning must not move with the layout: digits, `=`/`-`, `[`/`]`, the keypad,
/// arrows) and/or by the character it types on the ASCII layout (`character`, lowercase, for letters, so a
/// Russian layout still gets `f` on the F key).
public struct KeyBinding: Sendable, Equatable {
    public let keyCodes: [UInt16]
    public let character: String?
    /// Shift: required when set, ignored otherwise (as `keyDown` always did, except that ⇧+arrows pan and ⇧+/ is `?`).
    /// Option: must match exactly; with ⌥ the shift state must match too.
    public let modifiers: KeyModifiers
    /// False for one-shot actions (toggles, folder steps): an auto-repeat of the held key does nothing.
    public let allowsRepeat: Bool
    /// What the key does: a `KeyAction`, an `add` step, or `ignore` (an `input.conf` line that unbinds the key: it
    /// matches, so nothing after it does, and the press is `.unbound`).
    public let input: InputAction

    /// The `KeyAction` the key does; nil for `add` and `ignore`.
    public var action: KeyAction? {
        if case .action(let a) = input { a } else { nil }
    }

    public init(keyCodes: [UInt16] = [], character: String? = nil, modifiers: KeyModifiers = [],
                allowsRepeat: Bool, input: InputAction) {
        self.keyCodes = keyCodes
        self.character = character
        self.modifiers = modifiers
        self.allowsRepeat = allowsRepeat
        self.input = input
    }

    public init(keyCodes: [UInt16] = [], character: String? = nil, modifiers: KeyModifiers = [],
                allowsRepeat: Bool, action: KeyAction) {
        self.init(keyCodes: keyCodes, character: character, modifiers: modifiers, allowsRepeat: allowsRepeat,
                  input: .action(action))
    }
}

/// The viewer's keyboard table. The order is the precedence: the first binding that matches wins, which is how
/// ⇧+← (pan) beats ← (previous photo).
public struct KeyMap: Sendable, Equatable {
    public let bindings: [KeyBinding]

    public init(bindings: [KeyBinding]) { self.bindings = bindings }

    /// What a key press means: an action (a `KeyAction` or an `add` step, never `ignore`), the auto-repeat of a
    /// one-shot key (to be swallowed, not beeped at), or a key the table does not bind (the view passes it on,
    /// `super.keyDown`).
    public enum Lookup: Equatable, Sendable {
        case action(InputAction)
        case ignoredRepeat
        case unbound
    }

    public func lookup(keyCode: UInt16, character: String?, modifiers: KeyModifiers, isRepeat: Bool) -> Lookup {
        guard let b = binding(keyCode: keyCode, character: character, modifiers: modifiers), b.input != .ignore else {
            return .unbound
        }
        return isRepeat && !b.allowsRepeat ? .ignoredRepeat : .action(b.input)
    }

    /// The `KeyAction` for a key press, or nil when the key is unbound, does an `add` step, or is the repeat of a
    /// one-shot key.
    public func action(keyCode: UInt16, character: String?, modifiers: KeyModifiers, isRepeat: Bool) -> KeyAction? {
        guard case .action(.action(let action)) = lookup(keyCode: keyCode, character: character, modifiers: modifiers,
                                                         isRepeat: isRepeat) else { return nil }
        return action
    }

    /// The actions whose keys work in a viewer window whatever it shows: Home over the viewer, a page with no photo.
    public static let windowActions: Set<KeyAction> = [.toggleFullScreen]

    /// `lookup` for a key pressed while the viewer does not have the keys: a `windowActions` key (or its swallowed
    /// repeat), else `.unbound`, so every other key stays with what is on screen.
    public func windowLookup(keyCode: UInt16, character: String?, modifiers: KeyModifiers, isRepeat: Bool) -> Lookup {
        guard let action = binding(keyCode: keyCode, character: character, modifiers: modifiers)?.action,
              Self.windowActions.contains(action) else { return .unbound }
        return lookup(keyCode: keyCode, character: character, modifiers: modifiers, isRepeat: isRepeat)
    }

    /// The first binding that matches the key, whatever the repeat.
    private func binding(keyCode: UInt16, character: String?, modifiers: KeyModifiers) -> KeyBinding? {
        let character = character?.lowercased()
        let shift = modifiers.contains(.shift)
        let option = modifiers.contains(.option)
        return bindings.first { b in
            guard b.keyCodes.contains(keyCode) || (b.character != nil && b.character == character) else { return false }
            let wantsOption = b.modifiers.contains(.option)
            let wantsShift = b.modifiers.contains(.shift)
            return option == wantsOption && (!wantsShift || shift) && (!option || shift == wantsShift)
        }
    }

    /// How the cheat sheet shows an action: its key text, its title and the section it belongs to. The key text is
    /// made from the action's bindings (plain keys first, then the ⌥ ones), so it cannot drift from what the keys do.
    public func label(_ action: KeyAction) -> (keys: String, title: String, group: KeyGroup) {
        var names: [String] = []
        for b in shownBindings(action) {
            for name in Self.keyNames(b) where !names.contains(name) { names.append(name) }
        }
        let (title, group) = Self.titles[action] ?? (action.rawValue, .view)
        return (names.joined(separator: "  "), title, group)
    }

    /// The cheat sheet's rows for keys that do an `add` step or a zoom step (input.conf lines): the keys, by first
    /// appearance, and what they do (`InputMap.title`).
    public func stepLabels() -> [(keys: String, title: String)] {
        var rows: [(input: InputAction, names: [String])] = []
        for b in bindings {
            switch b.input {
            case .add, .zoomStep: break
            default: continue
            }
            let names = Self.keyNames(b)
            if let i = rows.firstIndex(where: { $0.input == b.input }) {
                for name in names where !rows[i].names.contains(name) { rows[i].names.append(name) }
            } else {
                rows.append((b.input, names))
            }
        }
        return rows.filter { !$0.names.isEmpty }.map { ($0.names.joined(separator: "  "), InputMap.title($0.input)) }
    }

    /// The actions a menu item does (Zoom, Scaling, Colour, View); `menuKey` gives the key each item shows.
    static let menuActions: Set<KeyAction> = [
        .fit, .actual100, .actual200, .actual400, .fitWidth, .fitHeight, .fill, .toggleFitActual, .zoomIn, .zoomOut,
        .toggleKeepZoom, .saveKeepZoom, .toggleZoomCarry, .saveZoomCarry,
        .cycleFilter, .saveFilters, .toggleAntiring, .saveAntiring, .toggleAutoColor, .saveAutoColor, .toggleVibrance, .saveVibrance,
        .toggleStrip, .toggleStripPlacement, .cycleStats, .cheatSheet, .cyclePanIndicators, .savePanIndicators, .toggleInfoPanel,
    ]

    /// An action's bindings in the order the cheat sheet and the menus show them: plain (and ⇧) keys first, then the ⌥
    /// ones, each in table order.
    private func shownBindings(_ action: KeyAction) -> [KeyBinding] {
        let mine = bindings.filter { $0.action == action }
        return mine.filter { !$0.modifiers.contains(.option) } + mine.filter { $0.modifiers.contains(.option) }
    }

    /// The key a menu item shows for `action`, as `NSMenuItem` takes it: the action's first shown binding (a ⌥ key
    /// only when it has no other), by its character (lowercase, ⇧ in `modifiers`) or else by the name of its last key
    /// code (the keypad's `+` rather than the top row's `=`; ⇧/ as `?`, the Shift being in the character). Nil for an
    /// action no menu item does (photo and folder steps, pans, Esc) and for full screen, whose item shows the
    /// macOS-standard ⌃⌘F.
    public func menuKey(_ action: KeyAction) -> (keyEquivalent: String, modifiers: KeyModifiers)? {
        guard Self.menuActions.contains(action), let b = shownBindings(action).first else { return nil }
        if let c = b.character { return (c, b.modifiers) }
        guard let code = b.keyCodes.last else { return nil }
        if code == 44, b.modifiers.contains(.shift) { return ("?", b.modifiers.subtracting(.shift)) }
        return Self.keyName(code).map { ($0, b.modifiers) }
    }

    /// The names of a binding's keys, with its modifiers in front; a key code without a name is left out (a test
    /// requires every bound code to have one).
    static func keyNames(_ b: KeyBinding) -> [String] {
        let shift = b.modifiers.contains(.shift)
        let prefix = (b.modifiers.contains(.option) ? "⌥" : "") + (shift ? "⇧" : "")
        var names = b.keyCodes.compactMap { code -> String? in
            if shift, code == 44 { return "?" }                 // ⇧ + the / key reads as what it types
            return keyName(code).map { prefix + $0 }
        }
        if let c = b.character { names.append(prefix + c.uppercased()) }
        return names
    }

    /// The name of a key bound by position: every key `input.conf` names (a test checks). Keypad keys share the name of
    /// the key they double.
    static func keyName(_ code: UInt16) -> String? {
        switch code {
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        case 51: "⌫"
        case 49: "Space"
        case 116: "PgUp"
        case 121: "PgDn"
        case 115: "Home"
        case 119: "End"
        case 53: "Esc"
        case 36: "Return"
        case 76: "Enter"
        case 30: "]"
        case 33: "["
        case 44: "/"
        case 29, 82: "0"
        case 18, 83: "1"
        case 19, 84: "2"
        case 20, 85: "3"
        case 21, 86: "4"
        case 23, 87: "5"
        case 22, 88: "6"
        case 26, 89: "7"
        case 28, 91: "8"
        case 25, 92: "9"
        case 24: "="
        case 69: "+"
        case 27, 78: "-"
        default: nil
        }
    }

    /// Every action has its entry (a test checks): the fallback in `label` is never meant to show.
    static let titles: [KeyAction: (title: String, group: KeyGroup)] = [
        .previous: ("Previous photo", .navigation),
        .next: ("Next photo", .navigation),
        .previousFolder: ("Previous folder", .navigation),
        .nextFolder: ("Next folder", .navigation),
        .first: ("First photo", .navigation),
        .last: ("Last photo", .navigation),
        .browse: ("Folder browser on this photo's folder", .navigation),
        .fit: ("Fit to window", .zoom),
        .actual100: ("Actual size (100%)", .zoom),
        .actual200: ("200%", .zoom),
        .actual400: ("400%", .zoom),
        .fitWidth: ("Fit width", .zoom),
        .fitHeight: ("Fit height", .zoom),
        .fill: ("Fill the window", .zoom),
        .toggleFitActual: ("Fit / actual size at the pointer", .zoom),
        .zoomIn: ("Zoom in", .zoom),
        .zoomOut: ("Zoom out", .zoom),
        .toggleKeepZoom: ("Keep zoom and position on/off (this folder)", .zoom),
        .saveKeepZoom: ("Save keep zoom as default", .zoom),
        .toggleZoomCarry: ("Keep the share of the photo / the scale (this folder)", .zoom),
        .saveZoomCarry: ("Save share / scale as default", .zoom),
        .panLeft: ("Pan left", .zoom),
        .panRight: ("Pan right", .zoom),
        .panUp: ("Pan up", .zoom),
        .panDown: ("Pan down", .zoom),
        .cycleFilter: ("Next scaling filter (this folder)", .scaling),
        .saveFilters: ("Save scaling filters as default", .scaling),
        .toggleAntiring: ("Anti-ringing on/off (this folder)", .scaling),
        .saveAntiring: ("Save anti-ringing as default", .scaling),
        .toggleAutoColor: ("Auto colour on/off (this folder)", .colour),
        .saveAutoColor: ("Save auto colour as default", .colour),
        .toggleVibrance: ("Vibrance on/off (this folder)", .colour),
        .saveVibrance: ("Save vibrance as default", .colour),
        .toggleFullScreen: ("Toggle full screen", .view),
        .exitFullScreen: ("Leave full screen", .view),
        .cycleStats: ("Stats bar on/off", .view),
        .toggleStrip: ("Hide or show the strip", .view),
        .toggleStripPlacement: ("Strip beside or over the photo", .view),
        .cheatSheet: ("Show or hide this sheet", .view),
        .toggleInfoPanel: ("Show or hide the info panel", .view),
        .cyclePanIndicators: ("Pan indicators: auto / always / off", .view),
        .savePanIndicators: ("Save pan indicators as default", .view),
        .newTab: ("New tab", .tabs),
        .newWindow: ("New window", .tabs),
        .closeTab: ("Close tab", .tabs),
        .closeWindow: ("Close window (all its tabs)", .tabs),
        .reopenTab: ("Reopen the last closed tab", .tabs),
        .back: ("Back to Recent, Folders or Stash, where it was opened from", .tabs),
        .nextTab: ("Next tab", .tabs),
        .previousTab: ("Previous tab", .tabs),
        .openInNewTab: ("Open a file in a new tab", .tabs),
        .openInNewWindow: ("Open a file in a new window", .tabs),
        .home: ("Home: recent folders and Stash", .tabs),
    ]

    /// Mouse and trackpad inputs for the cheat sheet's last column (they have no bindings to read them from): what
    /// `ViewerView` and `FilmstripView` do with them.
    public static let gestures: [(input: String, title: String)] = [
        ("Left-drag", "Pan (glides on after release)"),
        ("Right-drag up / down", "Zoom in / out at the pointer"),
        ("Pinch", "Zoom at the pointer"),
        ("Two-finger double tap", "Fit ↔ 100 % at the fingers (Smart zoom)"),
        ("Two-finger scroll", "Pan"),
        ("Three-finger swipe", "Previous / next photo"),
        ("Mouse wheel", "Previous / next photo"),
        ("MX thumb wheel right / left", "Zoom in / out at the pointer"),
        ("Click held + two-finger swipe", "Previous / next folder"),
        ("Right button + tilt or ⇧-wheel", "Previous / next folder"),
        ("Strip: hover", "Number and name of the photo"),
        ("Strip: click", "Jump to that photo"),
        ("Strip: press and drag", "Move the strip; the photo in the middle opens"),
        ("Strip: two-finger swipe sideways", "Move the strip; the photo in the middle opens"),
        ("Strip: drag its top edge", "Resize the strip"),
        ("Strip: buttons above its right end", "Beside or over the photo (⇧T); pin or hide (T)"),
        ("Chevron at the bottom edge", "Show the hidden strip (T)"),
    ]

    /// Today's `ViewerView.keyDown`, as a table.
    public static let standard = KeyMap(bindings: [
        KeyBinding(keyCodes: [44], modifiers: .shift, allowsRepeat: false, action: .cheatSheet),     // ? = ⇧ + the / key
        // ⇧+arrows pan by a tenth of the view; plain ← → navigate, plain ↑ ↓ are unbound.
        KeyBinding(keyCodes: [123], modifiers: .shift, allowsRepeat: true, action: .panLeft),
        KeyBinding(keyCodes: [124], modifiers: .shift, allowsRepeat: true, action: .panRight),
        KeyBinding(keyCodes: [125], modifiers: .shift, allowsRepeat: true, action: .panDown),
        KeyBinding(keyCodes: [126], modifiers: .shift, allowsRepeat: true, action: .panUp),
        KeyBinding(keyCodes: [123, 51, 116], allowsRepeat: true, action: .previous),                 // ← ⌫ PgUp
        KeyBinding(keyCodes: [124, 49, 121], allowsRepeat: true, action: .next),                     // → space PgDn
        KeyBinding(keyCodes: [123], modifiers: .option, allowsRepeat: false, action: .previousFolder),
        KeyBinding(keyCodes: [124], modifiers: .option, allowsRepeat: false, action: .nextFolder),
        KeyBinding(keyCodes: [30], allowsRepeat: false, action: .nextFolder),                        // ] and [ by key position
        KeyBinding(keyCodes: [33], allowsRepeat: false, action: .previousFolder),
        KeyBinding(keyCodes: [115], allowsRepeat: true, action: .first),                             // Home
        KeyBinding(keyCodes: [119], allowsRepeat: true, action: .last),                              // End
        KeyBinding(keyCodes: [36, 76], allowsRepeat: false, action: .browse),                        // Return, Enter
        KeyBinding(keyCodes: [53], allowsRepeat: false, action: .exitFullScreen),                    // Esc
        // Digits by position too (top row and keypad), so AZERTY works without Shift.
        KeyBinding(keyCodes: [29, 82], character: "0", allowsRepeat: true, action: .fit),
        KeyBinding(keyCodes: [18, 83], character: "1", allowsRepeat: true, action: .actual100),
        KeyBinding(keyCodes: [19, 84], character: "2", allowsRepeat: true, action: .actual200),
        KeyBinding(keyCodes: [21, 86], character: "4", allowsRepeat: true, action: .actual400),
        KeyBinding(character: "w", allowsRepeat: true, action: .fitWidth),
        KeyBinding(character: "h", allowsRepeat: true, action: .fitHeight),
        KeyBinding(character: "x", allowsRepeat: true, action: .fill),
        KeyBinding(character: "z", allowsRepeat: false, action: .toggleFitActual),
        // Zoom by key position (= on the top row, keypad +/−), so no layout needs Shift for +.
        KeyBinding(keyCodes: [24, 69], allowsRepeat: true, action: .zoomIn),
        KeyBinding(keyCodes: [27, 78], allowsRepeat: true, action: .zoomOut),
        // Keep zoom: ⇧ first, as plain letters ignore Shift.
        KeyBinding(character: "l", modifiers: .shift, allowsRepeat: false, action: .saveKeepZoom),
        KeyBinding(character: "l", allowsRepeat: false, action: .toggleKeepZoom),
        KeyBinding(character: "k", modifiers: .shift, allowsRepeat: false, action: .saveZoomCarry),
        KeyBinding(character: "k", allowsRepeat: false, action: .toggleZoomCarry),
        // Scaling: ⇧ variants first, as plain letters ignore Shift.
        KeyBinding(character: "s", modifiers: .shift, allowsRepeat: false, action: .saveFilters),
        KeyBinding(character: "s", allowsRepeat: false, action: .cycleFilter),
        KeyBinding(character: "a", modifiers: .shift, allowsRepeat: false, action: .saveAntiring),
        KeyBinding(character: "a", allowsRepeat: false, action: .toggleAntiring),
        // Colour, the same way.
        KeyBinding(character: "c", modifiers: .shift, allowsRepeat: false, action: .saveAutoColor),
        KeyBinding(character: "c", allowsRepeat: false, action: .toggleAutoColor),
        KeyBinding(character: "v", modifiers: .shift, allowsRepeat: false, action: .saveVibrance),
        KeyBinding(character: "v", allowsRepeat: false, action: .toggleVibrance),
        KeyBinding(character: "f", allowsRepeat: false, action: .toggleFullScreen),
        KeyBinding(character: "i", allowsRepeat: false, action: .cycleStats),
        // ⇧T first, as plain letters ignore Shift.
        KeyBinding(character: "t", modifiers: .shift, allowsRepeat: false, action: .toggleStripPlacement),
        KeyBinding(character: "t", allowsRepeat: false, action: .toggleStrip),
        // Pan indicators: ⇧ first, as plain letters ignore Shift.
        KeyBinding(character: "p", modifiers: .shift, allowsRepeat: false, action: .savePanIndicators),
        KeyBinding(character: "p", allowsRepeat: false, action: .cyclePanIndicators),
    ])
}
