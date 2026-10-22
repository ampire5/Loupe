import Testing
@testable import LoupeCore

private func key(_ code: UInt16, _ modifiers: KeyModifiers = []) -> InputTrigger {
    .key(KeyChord(keyCode: code, character: nil, modifiers: modifiers))
}

@Test func lettersAreByCharacter() {
    #expect(InputConf.trigger("f") == .key(KeyChord(keyCode: nil, character: "f", modifiers: [])))
    #expect(InputConf.trigger("L") == InputConf.trigger("Shift+l"))
    #expect(InputConf.trigger("L") == .key(KeyChord(keyCode: nil, character: "l", modifiers: .shift)))
    #expect(InputConf.trigger("shift+L") == InputConf.trigger("L"))
    #expect(InputConf.trigger("ALT+l") == .key(KeyChord(keyCode: nil, character: "l", modifiers: .option)))
}

@Test func otherKeysAreByPosition() {
    #expect(InputConf.trigger("Alt+=") == key(24, .option))
    #expect(InputConf.trigger("Alt+Shift+=") == key(24, [.option, .shift]))
    #expect(InputConf.trigger("?") == InputConf.trigger("Shift+/"))
    #expect(InputConf.trigger("?") == key(44, .shift))
    let named: [(String, UInt16)] = [
        ("LEFT", 123), ("RIGHT", 124), ("DOWN", 125), ("UP", 126), ("SPACE", 49), ("BS", 51), ("PGUP", 116),
        ("PGDWN", 121), ("HOME", 115), ("END", 119), ("ESC", 53), ("[", 33), ("]", 30), ("/", 44), ("=", 24),
        ("-", 27), ("KP_ADD", 69), ("KP_SUBTRACT", 78),
    ]
    for (name, code) in named { #expect(InputConf.trigger(name) == key(code), "\(name)") }
    let digits: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
    let keypad: [UInt16] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
    for d in 0...9 {
        #expect(InputConf.trigger("\(d)") == key(digits[d]), "\(d)")
        #expect(InputConf.trigger("KP\(d)") == key(keypad[d]), "KP\(d)")
    }
    #expect(InputConf.trigger("Shift+LEFT") == key(123, .shift))
}

@Test func mouseInputs() {
    #expect(InputConf.trigger("MX_PANEL") == .mouse(.panel, .tap))
    #expect(InputConf.trigger("MX_PANEL-long") == .mouse(.panel, .long))
    #expect(InputConf.trigger("MX_PANEL+WHEEL") == .mouse(.panel, .wheel))
    #expect(InputConf.trigger("MX_PANEL+MX_THUMB") == .mouse(.panel, .thumbWheel))
    #expect(InputConf.trigger("MX_PANEL+MOVE") == .mouse(.panel, .move))
    #expect(InputConf.trigger("MBTN_RIGHT+MBTN_MID") == .mouse(.middle, .withRight))
    #expect(InputConf.trigger("MBTN_MID") == .mouse(.middle, .tap))
    #expect(InputConf.trigger("MBTN_BACK-long") == .mouse(.back, .long))
    #expect(InputConf.trigger("MBTN_FORWARD") == .mouse(.forward, .tap))
    #expect(InputConf.trigger("MX_GESTURE") == .mouse(.gesture, .tap))
    #expect(InputConf.trigger("MX_SHIFT+MX_THUMB") == .mouse(.shift, .thumbWheel))
}

@Test func mouseButtonCIDs() {
    #expect(MouseButton.panel.cid == 0x01A0)
    #expect(MouseButton.gesture.cid == 0x00C3)
    #expect(MouseButton.shift.cid == 0x00C4)
    for b in [MouseButton.middle, .back, .forward, .right] { #expect(b.cid == nil) }
}

@Test func notInputs() {
    for name in ["MBTN_RIGHT", "Cmd+f", "Ctrl+f", "f-long", "MX_THUMB", "MX_FOO", "", "Shift+", "MBTN_RIGHT-long",
                 "MBTN_RIGHT+MBTN_BACK", "MBTN_RIGHT+WHEEL", "LEFT+WHEEL", "f+MOVE"] {
        #expect(InputConf.trigger(name) == nil, "\(name)")
    }
}

@Test func actionNames() {
    #expect(InputConf.actionName(.toggleAutoColor) == "toggle-auto-color")
    #expect(InputConf.actionName(.actual100) == "actual-100")
    #expect(InputConf.actionName(.toggleInfoPanel) == "toggle-info-panel")
    #expect(InputConf.actionName(.fit) == "fit")
    for a in KeyAction.allCases { #expect(InputConf.action(named: InputConf.actionName(a)) == a, "\(a)") }
    #expect(InputConf.action(named: "fitt") == nil)
    #expect(InputConf.action(named: "ignore") == nil)
    #expect(InputConf.action(named: "Fit") == nil)
}

/// The tab and window actions: the file's names, each parsed on a key and on a held button's wheel.
@Test func tabAndWindowActionNames() {
    let names: [(String, KeyAction)] = [("new-tab", .newTab), ("new-window", .newWindow), ("close-tab", .closeTab),
                                        ("next-tab", .nextTab), ("previous-tab", .previousTab),
                                        ("open-in-new-tab", .openInNewTab), ("open-in-new-window", .openInNewWindow),
                                        ("home", .home), ("back", .back), ("reopen-tab", .reopenTab),
                                        ("close-window", .closeWindow)]
    for (name, action) in names {
        #expect(InputConf.actionName(action) == name)
        #expect(InputConf.action(named: name) == action)
        let r = InputConf.parse("Alt+t \(name)\nMX_SHIFT+WHEEL \(name)\n")
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        #expect(r.lines.map(\.action) == [.action(action), .action(action)])
        #expect(!InputConf.isToggle(action))
    }
}

@Test func togglesAreTheToggleAndCycleActions() {
    let toggles = KeyAction.allCases.filter(InputConf.isToggle)
    #expect(Set(toggles) == [.toggleKeepZoom, .toggleZoomCarry, .toggleFullScreen, .cycleStats, .toggleStrip, .toggleStripPlacement,
                             .toggleInfoPanel, .cyclePanIndicators, .cycleFilter, .toggleAntiring, .toggleAutoColor,
                             .toggleVibrance, .toggleSpread])
}

@Test func parsesAddWithTrailingComment() {
    let r = InputConf.parse("MX_PANEL+WHEEL add auto-color-strength 0.05  # x\n")
    #expect(r.lines == [InputLine(trigger: .mouse(.panel, .wheel), action: .add(key: "auto-color-strength", step: 0.05), line: 1)])
    #expect(r.warnings.isEmpty)
    let v = InputConf.parse("MX_PANEL+MOVE add vibrance-amount -0.1\n")
    #expect(v.lines.first?.action == .add(key: "vibrance-amount", step: -0.1))
}

@Test func parsesZoomStep() {
    let r = InputConf.parse("MX_GESTURE+WHEEL zoom-step\nMBTN_MID zoom-step  # one stop in\n= zoom-step\n")
    #expect(r.warnings.isEmpty)
    #expect(r.lines.map(\.action) == [.zoomStep, .zoomStep, .zoomStep])
    #expect(r.lines.first?.trigger == .mouse(.gesture, .wheel))
    #expect(InputConf.action(named: "zoom-step") == nil)                 // not a KeyAction: an input action like add
    #expect(InputConf.parse("MX_GESTURE+WHEEL zoom-step 2").warnings == ["input.conf:1: zoom-step takes no arguments"])
}

@Test func messyTextParsesTheSame() {
    let clean = InputConf.parse("# comment\n\nf fit\nMX_PANEL-long\ttoggle-vibrance\n")
    let messy = InputConf.parse("\u{FEFF}# comment\r\n\r\nf fit\r\nMX_PANEL-long\ttoggle-vibrance\t# tail\r\n   \t\r\n")
    #expect(clean.lines.count == 2)
    #expect(messy.lines == clean.lines)
    #expect(messy.warnings.isEmpty)
    #expect(messy.lines.map(\.line) == [3, 4])
    // Tabs and runs of blanks between the fields, no final newline.
    #expect(InputConf.parse("f\t \tfit").lines.map(\.line) == [1])
}

@Test func badLineIsSkippedTheRestApply() {
    let r = InputConf.parse("f fitt\nx ignore\n")
    #expect(r.lines == [InputLine(trigger: InputConf.trigger("x")!, action: .ignore, line: 2)])
    #expect(r.warnings == ["input.conf:1: unknown action \"fitt\""])
    let mid = InputConf.parse("f fit\nMX_FOO fit\nz fill\n")
    #expect(mid.lines.map(\.line) == [1, 3])
    #expect(mid.warnings == ["input.conf:2: unknown input \"MX_FOO\""])
}

@Test func duplicateInputsAreKeptInOrder() {
    let r = InputConf.parse("f fit\nf fill\n")
    #expect(r.lines.map(\.action) == [.action(.fit), .action(.fill)])
    #expect(r.warnings.isEmpty)
}

@Test func warningsAreWorded() {
    func warnings(_ line: String) -> [String] { InputConf.parse("\n" + line + "\n").warnings }
    #expect(warnings("MX_FOO fit") == ["input.conf:2: unknown input \"MX_FOO\""])
    #expect(warnings("Cmd+f fit") == ["input.conf:2: ⌘ and ⌃ belong to the menus"])
    #expect(warnings("Ctrl+f fit") == ["input.conf:2: ⌘ and ⌃ belong to the menus"])
    #expect(warnings("f-long fit") == ["input.conf:2: press kinds are for mouse buttons"])
    #expect(warnings("add_ fit") == ["input.conf:2: unknown input \"add_\""])
    #expect(warnings("MX_PANEL+WHEEL add vibrance 0.1") == ["input.conf:2: add takes auto-color-strength or vibrance-amount"])
    #expect(warnings("MX_PANEL+WHEEL add vibrance-amount 2") == ["input.conf:2: step must be 0.01…1 in size"])
    #expect(warnings("MX_PANEL+WHEEL add vibrance-amount 0") == ["input.conf:2: step must be 0.01…1 in size"])
    #expect(warnings("MX_PANEL+WHEEL add vibrance-amount x") == ["input.conf:2: step must be 0.01…1 in size"])
    #expect(warnings("MX_PANEL+WHEEL add vibrance-amount") == ["input.conf:2: add needs a step"])
    #expect(warnings("MX_PANEL+WHEEL add") == ["input.conf:2: add takes auto-color-strength or vibrance-amount"])
    #expect(warnings("MX_PANEL+WHEEL add vibrance-amount 0.1 0.2") == ["input.conf:2: add takes a key and a step, nothing more"])
    #expect(warnings("f fit extra") == ["input.conf:2: fit takes no arguments"])
    #expect(warnings("f ignore now") == ["input.conf:2: ignore takes no arguments"])
    #expect(warnings("f") == ["input.conf:2: missing action"])
    #expect(warnings("MBTN_RIGHT fit") == ["input.conf:2: MBTN_RIGHT only works as MBTN_RIGHT+MBTN_MID"])
}

@Test func stepBounds() {
    for s in ["0.01", "-0.01", "1", "-1", "0.5"] {
        #expect(InputConf.parse("MX_PANEL+WHEEL add vibrance-amount \(s)").warnings.isEmpty, "\(s)")
    }
    for s in ["0.009", "1.01", "-2", "nan", "inf"] {
        #expect(InputConf.parse("MX_PANEL+WHEEL add vibrance-amount \(s)").lines.isEmpty, "\(s)")
    }
}

@Test func trackpadGesturesAreTapsOnly() {
    #expect(InputConf.trigger("TP_3UP") == .mouse(.threeUp, .tap))
    #expect(InputConf.trigger("TP_FORCE") == .mouse(.forceClick, .tap))
    #expect(InputConf.trigger("TP_CLICK_DOWN") == .mouse(.clickDown, .tap))
    #expect(InputConf.trigger("TP_3TAP-long") == nil)
    #expect(InputConf.trigger("TP_3UP+WHEEL") == nil)
    #expect(InputConf.parse("TP_3UP+WHEEL fit").warnings == ["input.conf:1: trackpad gestures take no press kind"])
    #expect(InputConf.text(of: .mouse(.threeDown, .tap)) == "TP_3DOWN")
    let lines = InputConf.parse("TP_3DOWN fit\nTP_FORCE ignore").lines
    #expect(InputMap(lines: lines).mouse(.threeDown, .tap) == .action(.fit))
    #expect(InputMap(lines: lines).mouse(.forceClick, .tap) == nil)
    #expect(MouseButton.allCases.filter(\.isTrackpad).allSatisfy { $0.cid == nil })
}

@Test func templateHasTheSpreadKeys() {
    let text = InputConfTemplate.text
    for line in ["# d toggle-spread", "# D save-spread", "# Alt+d shift-spread"] {
        #expect(text.contains(line), "\(line)")
    }
}
