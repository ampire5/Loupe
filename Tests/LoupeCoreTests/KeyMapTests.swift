import Testing
@testable import LoupeCore

private let map = KeyMap.standard

private func action(_ code: UInt16, _ character: String? = nil, _ modifiers: KeyModifiers = [], repeat isRepeat: Bool = false) -> KeyAction? {
    map.action(keyCode: code, character: character, modifiers: modifiers, isRepeat: isRepeat)
}

/// Actions with no key of their own by default: they are on the mouse (spec §4; the info panel also has ⌘I in the menu),
/// and input.conf can add a key.
/// The tab and window actions have no key or button at all (⌘T, ⌘N, ⌘W, ⌘⇧] / ⌘⇧[ are the menu's): input.conf only.
private let mouseOnlyByDefault: Set<KeyAction> = [.toggleInfoPanel, .newTab, .newWindow, .closeTab, .nextTab, .previousTab,
                                                       .openInNewTab, .openInNewWindow, .home,
                                                       .back, .reopenTab, .closeWindow]

/// The browser's ⌘[, ⇧⌘T and ⇧⌘W as input.conf actions.
@Test func browserTabActionNames() {
    #expect(InputConf.action(named: "back") == .back)
    #expect(InputConf.action(named: "reopen-tab") == .reopenTab)
    #expect(InputConf.action(named: "close-window") == .closeWindow)
    #expect(map.label(.closeTab).title == "Close tab")
    #expect(map.label(.back).group == .tabs)
}

@Test func everyActionHasLabel() {
    for a in KeyAction.allCases {
        let label = map.label(a)
        #expect(mouseOnlyByDefault.contains(a) || !label.keys.isEmpty, "\(a) has no key text")
        #expect(!label.title.isEmpty, "\(a) has no title")
    }
    #expect(map.bindings.contains { $0.action == .toggleStrip })
    for a in KeyAction.allCases where !mouseOnlyByDefault.contains(a) {
        #expect(map.bindings.contains { $0.action == a }, "\(a) is bound to no key")
    }
}

/// What the bound keys type on the US layout (`KeyboardLayout` reads every layout through the ASCII-capable one), with
/// Shift where a binding asks for it. A key the table binds must be listed here, so the test below sees it.
private let usCharacters: [UInt16: (plain: String?, shifted: String?)] = [
    36: (nil, nil), 76: (nil, nil), 123: (nil, nil), 124: (nil, nil), 125: (nil, nil), 126: (nil, nil), 51: (nil, nil), 53: (nil, nil),
    115: (nil, nil), 119: (nil, nil), 116: (nil, nil), 121: (nil, nil), 49: (" ", " "),
    30: ("]", "}"), 33: ("[", "{"), 44: ("/", "?"),
    29: ("0", ")"), 18: ("1", "!"), 19: ("2", "@"), 21: ("4", "$"), 82: ("0", "0"), 83: ("1", "1"), 84: ("2", "2"),
    86: ("4", "4"), 24: ("=", "+"), 27: ("-", "_"), 69: ("+", "+"), 78: ("-", "-"),
    2: ("d", "D"), 13: ("w", "W"), 4: ("h", "H"), 7: ("x", "X"), 6: ("z", "Z"), 3: ("f", "F"), 34: ("i", "I"), 17: ("t", "T"),
    1: ("s", "S"), 0: ("a", "A"), 8: ("c", "C"), 9: ("v", "V"), 37: ("l", "L"), 40: ("k", "K"), 35: ("p", "P"),
]

/// `label` would fall back to the raw case name in the View section; every action has a title of its own instead.
@Test func everyActionHasATitle() {
    for a in KeyAction.allCases { #expect(KeyMap.titles[a] != nil, "\(a) has no title in KeyMap.titles") }
}

/// Every binding is reached by each key it names, pressed with exactly the modifiers it asks for, as the full key
/// press (key code and the character it types): a binding shadowed by an earlier one (the same key, an earlier
/// binding that ignores Shift, or one naming the same physical key by character instead of code) fails here.
@Test func everyBindingIsReachable() {
    for b in map.bindings {
        let shift = b.modifiers.contains(.shift)
        var presses: [(UInt16, String?)] = []
        for code in b.keyCodes {
            guard let typed = usCharacters[code] else { Issue.record("keyCode \(code) missing from usCharacters"); continue }
            presses.append((code, shift ? typed.shifted : typed.plain))
        }
        if let c = b.character {
            guard let code = usCharacters.first(where: { $0.value.plain == c })?.key else {
                Issue.record("\"\(c)\" missing from usCharacters"); continue
            }
            presses.append((code, shift ? usCharacters[code]?.shifted : c))
        }
        for (code, character) in presses {
            let got = action(code, character, b.modifiers)
            #expect(got == b.action, "keyCode \(code) \(character ?? "-") \(b.modifiers) reaches \(String(describing: got)), not \(b.action)")
        }
    }
}

@Test func lookupTellsARepeatFromAnUnboundKey() {
    #expect(map.lookup(keyCode: 123, character: nil, modifiers: [], isRepeat: true) == .action(.action(.previous)))
    #expect(map.lookup(keyCode: 0, character: "f", modifiers: [], isRepeat: true) == .ignoredRepeat)
    #expect(map.lookup(keyCode: 53, character: nil, modifiers: [], isRepeat: true) == .ignoredRepeat)
    #expect(map.lookup(keyCode: 0, character: "q", modifiers: [], isRepeat: true) == .unbound)
    #expect(map.lookup(keyCode: 0, character: "q", modifiers: [], isRepeat: false) == .unbound)
    #expect(map.lookup(keyCode: 44, character: "?", modifiers: .shift, isRepeat: false) == .action(.action(.cheatSheet)))
}

/// The key text is made from the bindings; these pin what that gives, and every bound key code has a name.
@Test func labelsShowTheBoundKeys() {
    let expected: [KeyAction: String] = [
        .previous: "←  ⌫  PgUp", .next: "→  Space  PgDn", .previousFolder: "[  ⌥←", .nextFolder: "]  ⌥→",
        .first: "Home", .last: "End", .browse: "Return  Enter", .exitFullScreen: "Esc", .fit: "0", .actual100: "1", .actual200: "2",
        .actual400: "4", .fitWidth: "W", .fitHeight: "H", .fill: "X", .toggleFitActual: "Z", .zoomIn: "=  +",
        .zoomOut: "-", .panLeft: "⇧←", .panRight: "⇧→", .panUp: "⇧↑", .panDown: "⇧↓", .toggleFullScreen: "F",
        .cycleStats: "I", .toggleStrip: "T", .toggleStripPlacement: "⇧T", .cheatSheet: "?",
        .cycleFilter: "S", .saveFilters: "⇧S", .toggleAntiring: "A", .saveAntiring: "⇧A",
        .toggleAutoColor: "C", .saveAutoColor: "⇧C", .toggleVibrance: "V", .saveVibrance: "⇧V",
        .toggleKeepZoom: "L", .saveKeepZoom: "⇧L", .toggleZoomCarry: "K", .saveZoomCarry: "⇧K", .cyclePanIndicators: "P", .savePanIndicators: "⇧P",
        .toggleSpread: "D", .saveSpread: "⇧D", .shiftSpread: "⌥D",
    ]
    for a in KeyAction.allCases {
        #expect(map.label(a).keys == (mouseOnlyByDefault.contains(a) ? "" : expected[a]), "\(a): \(map.label(a).keys)")
    }
    for b in map.bindings {
        for code in b.keyCodes { #expect(KeyMap.keyName(code) != nil, "keyCode \(code) has no name") }
    }
}

/// Every key `input.conf` can name has a name for the cheat sheet and the menus, so any rebinding shows: digits as
/// themselves (the keypad's too), the keypad's + and − as `+` and `-`.
@Test func everyInputConfKeyHasAName() {
    for (name, code) in InputConf.keyCodes {
        let want: String? = switch name {
        case let d where d.count == 1 && d.first!.isNumber: d
        case let d where d.hasPrefix("KP") && d.count == 3: String(d.last!)
        case "KP_ADD": "+"
        case "KP_SUBTRACT": "-"
        default: nil
        }
        #expect(KeyMap.keyName(code) != nil, "\(name) (\(code)) has no name")
        if let want { #expect(KeyMap.keyName(code) == want, "\(name): \(KeyMap.keyName(code) ?? "nil")") }
    }
}

@Test func todaysKeysMapAsBefore() {
    let table: [(UInt16, String?, KeyModifiers, KeyAction)] = [
        (123, nil, [], .previous), (51, nil, [], .previous), (116, nil, [], .previous),
        (124, nil, [], .next), (49, nil, [], .next), (121, nil, [], .next),
        (30, nil, [], .nextFolder), (33, nil, [], .previousFolder),
        (124, nil, .option, .nextFolder), (123, nil, .option, .previousFolder),
        (115, nil, [], .first), (119, nil, [], .last), (53, nil, [], .exitFullScreen),
        (29, nil, [], .fit), (82, nil, [], .fit), (200, "0", [], .fit),
        (18, nil, [], .actual100), (83, nil, [], .actual100), (200, "1", [], .actual100),
        (19, nil, [], .actual200), (84, nil, [], .actual200), (200, "2", [], .actual200),
        (21, nil, [], .actual400), (86, nil, [], .actual400), (200, "4", [], .actual400),
        (200, "w", [], .fitWidth), (200, "h", [], .fitHeight), (200, "x", [], .fill), (200, "z", [], .toggleFitActual),
        (24, nil, [], .zoomIn), (69, nil, [], .zoomIn), (27, nil, [], .zoomOut), (78, nil, [], .zoomOut),
        (200, "f", [], .toggleFullScreen), (200, "i", [], .cycleStats),
        (123, nil, .shift, .panLeft), (124, nil, .shift, .panRight), (126, nil, .shift, .panUp), (125, nil, .shift, .panDown),
        // Shift is ignored by every key but the arrows and `?`, as before.
        (49, nil, .shift, .next), (200, "f", .shift, .toggleFullScreen),
    ]
    for (code, character, modifiers, expected) in table {
        #expect(action(code, character, modifiers) == expected, "keyCode \(code) \(character ?? "-") \(modifiers)")
    }
}

@Test func unhandledKeysFallThrough() {
    #expect(action(125) == nil)                       // ↓ and ↑ go to super
    #expect(action(126) == nil)
    #expect(action(0, "q") == nil)
    #expect(action(44) == nil)                        // "/" without Shift
    #expect(action(123, nil, [.option, .shift]) == nil)
    #expect(action(200, "z", .option) == nil)         // ⌥ belongs to the menus
    #expect(action(29, nil, .option) == nil)
}

@Test func repeatsFiltered() {
    // Held keys that repeat today.
    for (code, character) in [(UInt16(123), String?.none), (124, nil), (49, nil), (115, nil), (24, nil), (200, "w")] {
        #expect(action(code, character, [], repeat: true) != nil, "keyCode \(code) repeats")
    }
    #expect(action(123, nil, .shift, repeat: true) == .panLeft)
    // One-shot keys.
    for (code, character, modifiers) in [(UInt16(200), String?.some("z"), KeyModifiers()), (200, "f", []), (200, "i", []), (200, "t", []),
                                         (30, nil, []), (33, nil, []), (124, nil, .option), (123, nil, .option),
                                         (53, nil, []), (44, nil, .shift)] {
        #expect(action(code, character, modifiers, repeat: true) == nil, "keyCode \(code) \(character ?? "-") is one-shot")
    }
    #expect(action(200, "z") == .toggleFitActual)
}

@Test func questionMarkIsShiftSlash() {
    #expect(action(44, nil, .shift) == .cheatSheet)
    #expect(action(44, "?", .shift) == .cheatSheet)
}

@Test func statsKeyText() {
    #expect(map.label(.cycleStats).title == "Stats bar on/off")
    #expect(map.label(.cycleStats).keys == "I")
}

@Test func scalingKeys() {
    #expect(action(1, "s") == .cycleFilter)
    #expect(action(1, "S", .shift) == .saveFilters)
    #expect(action(0, "a") == .toggleAntiring)
    #expect(action(0, "A", .shift) == .saveAntiring)
    // Letters are bound by character, which `KeyboardLayout` reads through the ASCII layout: ы and ф arrive as s and a.
    #expect(map.label(.saveFilters).keys == "⇧S")
    #expect(map.label(.cycleFilter).group == .scaling)
    for (code, character, modifiers) in [(UInt16(1), "s", KeyModifiers()), (1, "s", .shift), (0, "a", []), (0, "a", .shift)] {
        #expect(map.lookup(keyCode: code, character: character, modifiers: modifiers, isRepeat: true) == .ignoredRepeat)
    }
}

@Test func colourKeys() {
    #expect(action(8, "c") == .toggleAutoColor)
    #expect(action(8, "C", .shift) == .saveAutoColor)       // ⇧ first: plain letters ignore Shift
    #expect(action(9, "v") == .toggleVibrance)
    #expect(action(9, "V", .shift) == .saveVibrance)
    #expect(map.label(.saveAutoColor).keys == "⇧C")
    #expect(map.label(.toggleVibrance).keys == "V")
    #expect(map.label(.toggleAutoColor).group == .colour)
    #expect(map.menuKey(.toggleAutoColor)?.keyEquivalent == "c" && map.menuKey(.toggleAutoColor)?.modifiers == [])
    #expect(map.menuKey(.saveAutoColor)?.keyEquivalent == "c" && map.menuKey(.saveAutoColor)?.modifiers == .shift)
    for (code, character, modifiers) in [(UInt16(8), "c", KeyModifiers()), (8, "c", .shift), (9, "v", []), (9, "v", .shift)] {
        #expect(map.lookup(keyCode: code, character: character, modifiers: modifiers, isRepeat: true) == .ignoredRepeat)
    }
}

/// `L` / `⇧L` (M4b spec §4.4): keep zoom and position for the folder, and saved as the default.
@Test func keepZoomKeys() {
    #expect(action(37, "l") == .toggleKeepZoom)
    #expect(action(37, "L", .shift) == .saveKeepZoom)        // ⇧ first: plain letters ignore Shift
    for (character, modifiers) in [("l", KeyModifiers()), ("l", .shift)] {
        #expect(map.lookup(keyCode: 37, character: character, modifiers: modifiers, isRepeat: true) == .ignoredRepeat)
    }
    #expect(map.menuKey(.toggleKeepZoom)?.keyEquivalent == "l" && map.menuKey(.toggleKeepZoom)?.modifiers == [])
    #expect(map.menuKey(.saveKeepZoom)?.keyEquivalent == "l" && map.menuKey(.saveKeepZoom)?.modifiers == .shift)
    #expect(map.label(.toggleKeepZoom) == (keys: "L", title: "Keep zoom and position on/off (this folder)", group: .zoom))
    #expect(map.label(.saveKeepZoom) == (keys: "⇧L", title: "Save keep zoom as default", group: .zoom))
}

/// `D` / `⇧D` / `⌥D`: two pages for the folder, saved as the default, and the pairing shifted by one page.
@Test func dKeysForSpread() {
    #expect(action(2, "d") == .toggleSpread)
    #expect(action(2, "D", .shift) == .saveSpread)
    #expect(action(2, "d", .option) == .shiftSpread)
    #expect(map.menuKey(.toggleSpread) == nil)
    #expect(map.label(.toggleSpread) == (keys: "D", title: "Two pages", group: .view))
    #expect(map.label(.saveSpread) == (keys: "⇧D", title: "Two pages as default", group: .view))
    #expect(map.label(.shiftSpread) == (keys: "⌥D", title: "Shift pages", group: .view))
}

/// `P` / `⇧P` (M4b spec §5.4): the pan indicators' mode for the session in every window, and saved as the default.
@Test func panIndicatorKeys() {
    #expect(action(35, "p") == .cyclePanIndicators)
    #expect(action(35, "P", .shift) == .savePanIndicators)   // ⇧ first: plain letters ignore Shift
    for (character, modifiers) in [("p", KeyModifiers()), ("P", .shift)] {
        #expect(map.lookup(keyCode: 35, character: character, modifiers: modifiers, isRepeat: true) == .ignoredRepeat)
    }
    #expect(map.menuKey(.cyclePanIndicators)?.keyEquivalent == "p" && map.menuKey(.cyclePanIndicators)?.modifiers == [])
    #expect(map.menuKey(.savePanIndicators)?.keyEquivalent == "p" && map.menuKey(.savePanIndicators)?.modifiers == .shift)
    #expect(map.label(.cyclePanIndicators) == (keys: "P", title: "Pan indicators: auto / always / off", group: .view))
    #expect(map.label(.savePanIndicators) == (keys: "⇧P", title: "Save pan indicators as default", group: .view))
}

@Test func tIsToggleStrip() {
    #expect(action(200, "t") == .toggleStrip)
}

/// ⇧T has its own action, bound before plain t (which ignores Shift).
@Test func shiftTPlacesTheStrip() {
    #expect(action(17, "t") == .toggleStrip)
    #expect(action(17, "T", .shift) == .toggleStripPlacement)
    #expect(map.label(.toggleStripPlacement).keys == "⇧T")
    #expect(map.label(.toggleStripPlacement).title == "Strip beside or over the photo")
}

/// The strip as Photos' filmstrip (2026-10-21): no magnifier any more, and T hides the strip.
@Test func stripHelpDescribesTheFilmstrip() {
    let strip = KeyMap.gestures.filter { $0.input.hasPrefix("Strip:") }
    #expect(!strip.contains { $0.title.localizedCaseInsensitiveContains("magnif") })
    #expect(strip.contains { $0.input == "Strip: hover" && $0.title == "Number and name of the photo" })
    #expect(strip.contains { $0.input == "Strip: press and drag" && $0.title == "Move the strip; the photo in the middle opens" })
    #expect(KeyMap.titles[.toggleStrip]?.title == "Hide or show the strip")
}

@Test func gesturesAreListed() {
    #expect(!KeyMap.gestures.isEmpty)
    #expect(KeyMap.gestures.contains { $0.input.hasPrefix("Strip:") && $0.input.contains("swipe") })   // Task 20
    for g in KeyMap.gestures {
        #expect(!g.input.isEmpty)
        #expect(!g.title.isEmpty)
    }
}

@Test func groupsCoverEveryAction() {
    for group in KeyGroup.allCases {
        #expect(KeyAction.allCases.contains { map.label($0).group == group }, "\(group) is empty")
    }
}

/// What the Zoom, Scaling, Colour and View menu items show: `NSMenuItem`'s key equivalent (the typed character, lowercase,
/// with ⇧ as a modifier) for each action a menu does, nil for the rest.
@Test func menuKeyForActions() {
    let expected: [KeyAction: (String, KeyModifiers)] = [
        .fit: ("0", []), .actual100: ("1", []), .actual200: ("2", []), .actual400: ("4", []),
        .fitWidth: ("w", []), .fitHeight: ("h", []), .fill: ("x", []), .toggleFitActual: ("z", []),
        .zoomIn: ("+", []), .zoomOut: ("-", []),
        .cycleFilter: ("s", []), .saveFilters: ("s", .shift), .toggleAntiring: ("a", []), .saveAntiring: ("a", .shift),
        .toggleAutoColor: ("c", []), .saveAutoColor: ("c", .shift), .toggleVibrance: ("v", []), .saveVibrance: ("v", .shift),
        .toggleStrip: ("t", []), .toggleStripPlacement: ("t", .shift), .cycleStats: ("i", []), .cheatSheet: ("?", []),
        .toggleKeepZoom: ("l", []), .saveKeepZoom: ("l", .shift),
        .toggleZoomCarry: ("k", []), .saveZoomCarry: ("k", .shift),
        .cyclePanIndicators: ("p", []), .savePanIndicators: ("p", .shift),
    ]
    for a in KeyAction.allCases {
        let got = map.menuKey(a)
        guard let (key, modifiers) = expected[a] else {
            // Steps, pans, Esc have no menu item; full screen's item shows the macOS-standard ⌃⌘F.
            #expect(got == nil, "\(a) has a menu key \(got?.keyEquivalent ?? "")")
            continue
        }
        #expect(got?.keyEquivalent == key && got?.modifiers == modifiers,
                "\(a): \(got?.keyEquivalent ?? "nil") \(got?.modifiers.rawValue ?? -1)")
        // The key the menu shows does that action when typed (US layout): the menu cannot name another key.
        if let code = usCharacters.first(where: { $0.value.plain == key })?.key {
            #expect(action(code, key, modifiers) == a, "\(a): typing \(key) does something else")
        } else if let code = usCharacters.first(where: { $0.value.shifted == key })?.key {
            #expect(action(code, key, modifiers.union(.shift)) == a, "\(a): typing \(key) does something else")
        } else {
            Issue.record("\(a): \(key) is typed by no key in usCharacters")
        }
    }
}

@Test func stepLabelsListAddAndZoomStepKeys() {
    let map = KeyMap(bindings: [
        KeyBinding(character: "k", allowsRepeat: true, input: .add(key: "vibrance-amount", step: 0.05)),
        KeyBinding(character: "j", allowsRepeat: true, input: .add(key: "vibrance-amount", step: 0.05)),
        KeyBinding(character: "z", modifiers: .option, allowsRepeat: true, input: .zoomStep),
        KeyBinding(character: "x", allowsRepeat: false, action: .fit),
    ])
    let rows = map.stepLabels()
    #expect(rows.map(\.keys) == ["K  J", "⌥Z"])
    #expect(rows.map(\.title) == ["Vibrance amount ±0.05", "Zoom in / out at the pointer"])
    #expect(KeyMap.standard.stepLabels().isEmpty)
}

@Test func returnIsBrowse() {
    #expect(KeyMap.standard.bindings.filter { $0.action == .browse }.flatMap(\.keyCodes).sorted() == [36, 76])
    #expect(InputConf.action(named: "browse") == .browse)
    #expect(map.label(.browse).group == .navigation)
}

/// View › Strip Beside the Photo shows ⇧T; the cheat sheet names the capsule and the reveal chevron.
@Test func stripPlacementHasAMenuKeyAndHelp() {
    let key = KeyMap.standard.menuKey(.toggleStripPlacement)
    #expect(key?.keyEquivalent == "t" && key?.modifiers == .shift)
    #expect(KeyMap.standard.menuKey(.toggleStrip)?.modifiers == [])
    #expect(KeyMap.gestures.contains { $0.input == "Chevron at the bottom edge" && $0.title == "Show the hidden strip (T)" })
    #expect(KeyMap.gestures.contains { $0.input.hasPrefix("Strip: buttons") && $0.title.contains("(⇧T)") })
}
