import Testing
@testable import LoupeCore

/// The effective layout: `KeyMap.standard` and the spec §4 mouse table, with `input.conf` lines on top (spec §2.1, §4).
@Suite struct InputMapTests {
    private func map(_ text: String) -> InputMap {
        let parsed = InputConf.parse(text)
        #expect(parsed.warnings.isEmpty, "\(parsed.warnings)")
        return InputMap(lines: parsed.lines)
    }

    private func lookup(_ m: InputMap, _ code: UInt16, _ character: String? = nil, _ modifiers: KeyModifiers = [],
                        repeat isRepeat: Bool = false) -> KeyMap.Lookup {
        m.keys.lookup(keyCode: code, character: character, modifiers: modifiers, isRepeat: isRepeat)
    }

    /// Every key press `KeyMap.standard` binds, in both repeat states, means the same in `m`. A character that doubles
    /// key codes (the digits) is pressed as typed by the binding's first key; a letter by an unbound key code.
    private func expectStandardKeys(_ m: InputMap, _ context: String) {
        for b in KeyMap.standard.bindings {
            var presses: [(UInt16, String?)] = b.keyCodes.map { ($0, nil) }
            if let c = b.character { presses.append((b.keyCodes.first ?? 200, c)) }
            for (code, character) in presses {
                for isRepeat in [false, true] {
                    let want = KeyMap.standard.lookup(keyCode: code, character: character, modifiers: b.modifiers, isRepeat: isRepeat)
                    let got = lookup(m, code, character, b.modifiers, repeat: isRepeat)
                    #expect(got == want, "\(context): keyCode \(code) \(character ?? "-") \(b.modifiers) repeat \(isRepeat): \(got), not \(want)")
                }
            }
        }
    }

    private func expectStandardMouse(_ m: InputMap, _ context: String) {
        for button in MouseButton.allCases {
            for kind in [PressKind.tap, .long, .wheel, .thumbWheel, .move, .withRight] {
                let want = InputMap.standardMouse.first { $0.0 == button && $0.1 == kind }?.2
                #expect(m.mouse(button, kind) == want, "\(context): \(button) \(kind)")
            }
        }
    }

    @Test func standardKeysMatchKeyMap() {
        expectStandardKeys(.standard, "standard")
        #expect(lookup(.standard, 0, "q") == .unbound)
    }

    @Test func standardMouseIsSpecLayout() {
        let m = InputMap.standard
        #expect(m.mouse(.panel, .tap) == .action(.toggleAutoColor))
        #expect(m.mouse(.panel, .long) == .action(.toggleVibrance))
        #expect(m.mouse(.panel, .wheel) == .add(key: "auto-color-strength", step: 0.05))
        #expect(m.mouse(.panel, .move) == .add(key: "vibrance-amount", step: 0.05))
        #expect(m.mouse(.middle, .tap) == .action(.toggleFitActual))
        #expect(m.mouse(.middle, .long) == .action(.fill))
        #expect(m.mouse(.back, .tap) == .action(.back))
        #expect(m.mouse(.back, .long) == .action(.cycleStats))
        #expect(m.mouse(.back, .wheel) == .action(.nextFolder))
        #expect(m.mouse(.forward, .tap) == .action(.toggleInfoPanel))
        #expect(m.mouse(.forward, .wheel) == .zoomStep)
        #expect(m.mouse(.middle, .withRight) == .action(.fitWidth))
        #expect(m.mouse(.forward, .long) == nil)
        #expect(m.mouse(.gesture, .tap) == .action(.cycleStats))
        #expect(m.mouse(.gesture, .wheel) == .add(key: "vibrance-amount", step: 0.05))
        #expect(m.mouse(.gesture, .long) == nil)
        #expect(m.mouse(.panel, .thumbWheel) == nil)
        #expect(m.divertedCIDs == [0x01A0, 0x00C3])
        #expect(m.wantsThumbWheel == false)
        #expect(m.kinds(of: .panel) == [.tap, .long, .wheel, .move])
        #expect(m.kinds(of: .middle) == [.tap, .long, .withRight])
        #expect(m.kinds(of: .back) == [.tap, .long, .wheel])
        #expect(m.kinds(of: .forward) == [.tap, .wheel])
        #expect(m.kinds(of: .gesture) == [.tap, .wheel])
        #expect(m.kinds(of: .shift).isEmpty)
        #expect(InputMap.standardMouse.count == 20)
    }

    @Test func folderStepFollowsTheWheel() {
        #expect(InputAction.action(.nextFolder).folderStep(steps: -1) == 1)    // down: the next folder
        #expect(InputAction.action(.nextFolder).folderStep(steps: 3) == -1)    // up, however many notches: one back
        #expect(InputAction.action(.previousFolder).folderStep(steps: -2) == -1)
        #expect(InputAction.action(.previousFolder).folderStep(steps: 1) == 1)
        #expect(InputAction.action(.nextFolder).folderStep(steps: 0) == nil)
        #expect(InputAction.action(.next).folderStep(steps: -1) == nil)
        #expect(InputAction.zoomStep.folderStep(steps: 1) == nil)
    }

    /// `next-tab` / `previous-tab` on a held button's wheel, thumb wheel or move go both ways, as the folder steps do.
    @Test func tabStepFollowsTheWheel() {
        #expect(InputAction.action(.nextTab).tabStep(steps: -1) == 1)         // down: the next tab
        #expect(InputAction.action(.nextTab).tabStep(steps: 3) == -1)         // up, however many notches: one back
        #expect(InputAction.action(.previousTab).tabStep(steps: -2) == -1)
        #expect(InputAction.action(.previousTab).tabStep(steps: 1) == 1)
        #expect(InputAction.action(.nextTab).tabStep(steps: 0) == nil)
        #expect(InputAction.action(.nextFolder).tabStep(steps: -1) == nil)
        #expect(InputAction.action(.nextTab).folderStep(steps: -1) == nil)
        #expect(InputAction.action(.newTab).tabStep(steps: -1) == nil)
        let m = map("MX_SHIFT+WHEEL next-tab\nMX_GESTURE+MX_THUMB previous-tab\nMX_PANEL+MOVE next-tab\nMBTN_FORWARD-long new-tab")
        let rows = m.mouseLabels()
        #expect(rows.contains { $0 == ("Wheel button + wheel", "Next / previous tab") })
        #expect(rows.contains { $0 == ("Gesture button + thumb wheel", "Previous / next tab") })
        #expect(rows.contains { $0 == ("Panel + move up/down", "Next / previous tab") })
        #expect(rows.contains { $0 == ("Forward (hold)", "New tab") })
    }

    /// No built-in key or mouse button does a tab or window action: ⌘T, ⌘N, ⌘W and ⌘⇧] / ⌘⇧[ stay the menu's. The
    /// trackpad's click held + two fingers up / down step tabs.
    @Test func tabActionsHaveNoDefaultBinding() {
        let tabs: Set<KeyAction> = [.newTab, .newWindow, .closeTab, .nextTab, .previousTab]
        #expect(KeyMap.standard.bindings.compactMap(\.action).allSatisfy { !tabs.contains($0) })
        #expect(InputMap.standardMouse.filter { !$0.0.isTrackpad }
            .allSatisfy { if case .action(let a) = $0.2 { !tabs.contains(a) } else { true } })
        #expect(InputMap.standard.mouse(.clickDown, .tap) == .action(.nextTab))
        #expect(InputMap.standard.mouse(.clickUp, .tap) == .action(.previousTab))
        for a in tabs {
            #expect(InputMap.standard.keys.label(a).keys.isEmpty, "\(a)")
            #expect(KeyMap.standard.menuKey(a) == nil, "\(a)")
        }
    }

    /// The template names the five, commented, in a section of their own, with gesture examples (none of them active).
    @Test func templateListsTabActions() throws {
        let text = InputConfTemplate.text
        let start = try #require(text.range(of: "# ── Window ──"))
        let body = String(text[start.lowerBound...].components(separatedBy: "\n\n")[0])
        for name in ["new-tab", "new-window", "close-tab", "next-tab", "previous-tab", "MX_SHIFT+WHEEL next-tab"] {
            #expect(body.contains(name), "\(name)")
        }
        // The examples are notes, not commented bindings: binding one of their inputs in the settings leaves the
        // section as it is (the line goes with the other mouse lines).
        for (input, action) in [(InputTrigger.mouse(.shift, .wheel), KeyAction.fit), (.mouse(.gesture, .thumbWheel), .fit),
                                (.mouse(.forward, .long), .fill), (.mouse(.gesture, .long), .fill)] {
            let out = InputConfText.binding(input, to: .action(action), in: text)
            let outStart = try #require(out.range(of: "# ── Window ──"))
            #expect(String(out[outStart.lowerBound...].components(separatedBy: "\n\n")[0]) == body, "\(input)")
            #expect(InputConf.parse(out).lines.map(\.trigger) == [input])
        }
    }

    @Test func fileLineOverridesOneKeyOnly() {
        let m = map("SPACE fit")
        #expect(lookup(m, 49, " ") == .action(.action(.fit)))
        #expect(lookup(m, 124) == .action(.action(.next)))
        #expect(lookup(m, 121) == .action(.action(.next)))
        #expect(lookup(m, 49, " ", .shift) == .action(.action(.fit)))      // plain bindings ignore Shift, as before
        #expect(m.keys.label(.next).keys == "→  PgDn")
        // A digit: the top-row key changes, the keypad one keeps its action.
        let digit = map("0 toggle-strip")
        #expect(lookup(digit, 29, "0") == .action(.action(.toggleStrip)))
        #expect(lookup(digit, 82, "0") == .action(.action(.fit)))
    }

    @Test func ignoreRemoves() {
        var m = map("MX_PANEL ignore")
        #expect(m.mouse(.panel, .tap) == nil)
        #expect(m.mouse(.panel, .long) == .action(.toggleVibrance))
        #expect(m.divertedCIDs.contains(0x01A0))
        m = map("MX_PANEL ignore\nMX_PANEL-long ignore\nMX_PANEL+WHEEL ignore\nMX_PANEL+MOVE ignore")
        #expect(m.divertedCIDs == [0x00C3])
        #expect(m.kinds(of: .panel).isEmpty)
        m = map("MX_GESTURE ignore\nMX_GESTURE+WHEEL ignore")
        #expect(m.divertedCIDs == [0x01A0])                               // the gesture button goes back to the system
        // Keys: the key goes to `super.keyDown`; its neighbours keep their actions.
        m = map("SPACE ignore")
        #expect(lookup(m, 49, " ") == .unbound)
        #expect(lookup(m, 124) == .action(.action(.next)))
        m = map("0 ignore")
        #expect(lookup(m, 29, "0") == .unbound)
        #expect(lookup(m, 82, "0") == .action(.action(.fit)))
        m = map("Shift+LEFT ignore")
        #expect(lookup(m, 123, nil, .shift) == .unbound)                     // not ← (previous) by ignoring Shift
        #expect(lookup(m, 123) == .action(.action(.previous)))
        #expect(m.keys.label(.panLeft).keys == "")
        m = map("SPACE fit\nSPACE ignore")
        #expect(lookup(m, 49, " ") == .unbound)
        #expect(m.keys.label(.fit).keys == "0")
    }

    @Test func lastLineWins() {
        var m = map("SPACE fit\nSPACE fill")
        #expect(lookup(m, 49, " ") == .action(.action(.fill)))
        #expect(m.keys.label(.fit).keys == "0")
        m = map("MX_PANEL fit\nMX_PANEL fill")
        #expect(m.mouse(.panel, .tap) == .action(.fill))
        m = map("MX_PANEL ignore\nMX_PANEL fit")
        #expect(m.mouse(.panel, .tap) == .action(.fit))
        m = map("q fit\nq ignore\nq fill")
        #expect(lookup(m, 12, "q") == .action(.action(.fill)))
    }

    @Test func shiftedFileBindingBeatsPlain() {
        let m = map("Shift+f fit")
        #expect(lookup(m, 3, "f", .shift) == .action(.action(.fit)))
        #expect(lookup(m, 3, "f") == .action(.action(.toggleFullScreen)))
        // ⌥ must match exactly: the plain f is not reached with ⌥, nor the ⌥ binding without it.
        let alt = map("Alt+f fill")
        #expect(lookup(alt, 3, "f", .option) == .action(.action(.fill)))
        #expect(lookup(alt, 3, "f") == .action(.action(.toggleFullScreen)))
    }

    @Test func thumbWheelBindingWantsWheel() {
        let m = map("MX_GESTURE+MX_THUMB add vibrance-amount 0.05")
        #expect(m.wantsThumbWheel)
        #expect(m.divertedCIDs.isSuperset(of: [0x00C3]))
        #expect(m.divertedCIDs == [0x01A0, 0x00C3])
        #expect(m.kinds(of: .gesture) == [.tap, .wheel, .thumbWheel])
        #expect(m.mouse(.gesture, .thumbWheel) == .add(key: "vibrance-amount", step: 0.05))
    }

    @Test func zoomStepBindsLikeAnyAction() {
        let m = map("MX_GESTURE+WHEEL ignore\nMX_PANEL+WHEEL zoom-step\nMBTN_MID zoom-step\nq zoom-step")
        #expect(m.mouse(.gesture, .wheel) == nil && m.kinds(of: .gesture) == [.tap])
        #expect(m.mouse(.panel, .wheel) == .zoomStep)
        #expect(m.mouse(.middle, .tap) == .zoomStep)                      // a press: one stop in
        #expect(lookup(m, 12, "q") == .action(.zoomStep))
        #expect(lookup(m, 12, "q", repeat: true) == .action(.zoomStep))   // repeats like zoom-in
    }

    @Test func fileBindingsRepeatLikeTheirAction() {
        var m = map("SPACE fit")
        #expect(lookup(m, 49, " ", repeat: true) == .action(.action(.fit)))
        m = map("SPACE toggle-strip")
        #expect(lookup(m, 49, " ", repeat: true) == .ignoredRepeat)
        m = map("UP add vibrance-amount 0.05\nq pan-left\nDOWN toggle-info-panel")
        #expect(lookup(m, 126, nil, repeat: true) == .action(.add(key: "vibrance-amount", step: 0.05)))
        #expect(lookup(m, 12, "q", repeat: true) == .action(.action(.panLeft)))
        #expect(lookup(m, 125, nil, repeat: true) == .ignoredRepeat)
        #expect(lookup(m, 125, nil) == .action(.action(.toggleInfoPanel)))
        #expect(m.keys.action(keyCode: 126, character: nil, modifiers: [], isRepeat: false) == nil)   // `add` is no KeyAction
    }

    @Test func menuKeyFollowsRemap() {
        var m = map("Alt+9 fit")
        #expect(m.keys.menuKey(.fit)?.keyEquivalent == "0" && m.keys.menuKey(.fit)?.modifiers == [])
        #expect(m.keys.label(.fit).keys == "0  ⌥9")
        m = map("Alt+9 fit\n0 ignore\nKP0 ignore")
        #expect(m.keys.menuKey(.fit)?.keyEquivalent == "9" && m.keys.menuKey(.fit)?.modifiers == .option)
        #expect(m.keys.label(.fit).keys == "⌥9")
        m = map("q toggle-info-panel")
        #expect(m.keys.menuKey(.toggleInfoPanel)?.keyEquivalent == "q")
        m = map("KP_ADD zoom-out\n= ignore")
        #expect(m.keys.menuKey(.zoomOut)?.keyEquivalent == "+")              // the file's binding comes first
        #expect(m.keys.label(.zoomOut).keys == "+  -")
        #expect(m.keys.menuKey(.zoomIn) == nil)
        #expect(lookup(m, 69) == .action(.action(.zoomOut)))
    }

    /// A rebinding that removes a menu item's only key leaves the item without one (and without an assertion).
    @Test func menuKeyIsNilAfterTheKeyIsUnbound() {
        #expect(InputMap.standard.keys.menuKey(.cycleStats)?.keyEquivalent == "i")
        let m = map("i ignore")
        #expect(m.keys.menuKey(.cycleStats) == nil)
        #expect(m.keys.label(.cycleStats).keys == "")
        #expect(lookup(m, 34, "i") == .unbound)
    }

    /// The template's commented binding lines (`# <input> <action>`, no indentation), uncommented, give exactly the
    /// built-in layout, and name every built-in key and mouse input.
    @Test func templateParsesToStandard() {
        var uncommented: [String] = []
        for row in InputConfTemplate.text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard row.hasPrefix("# "), let first = row.dropFirst(2).first, first != " " else { continue }
            let tokens = row.dropFirst(2).prefix { $0 != "#" }.split(separator: " ").map(String.init)
            guard tokens.count >= 2, ["add", "zoom-step"].contains(tokens[1]) || InputConf.action(named: tokens[1]) != nil
            else { continue }
            uncommented.append(String(row.dropFirst(2)))
        }
        let parsed = InputConf.parse(uncommented.joined(separator: "\n"))
        #expect(parsed.warnings.isEmpty, "\(parsed.warnings)")
        let m = InputMap(lines: parsed.lines)
        expectStandardKeys(m, "template")
        expectStandardMouse(m, "template")
        #expect(m.divertedCIDs == InputMap.standard.divertedCIDs)
        #expect(m.mouseLabels().map(\.input) == InputMap.standard.mouseLabels().map(\.input))
        let bound = Set(parsed.lines.map { InputBound(trigger: $0.trigger, action: $0.action) })
        for b in KeyMap.standard.bindings {
            for code in b.keyCodes {
                let t = InputTrigger.key(KeyChord(keyCode: code, character: nil, modifiers: b.modifiers))
                #expect(bound.contains(InputBound(trigger: t, action: b.input)), "keyCode \(code) \(b.modifiers) missing")
            }
            if let c = b.character, b.keyCodes.isEmpty {
                let t = InputTrigger.key(KeyChord(keyCode: nil, character: c, modifiers: b.modifiers))
                #expect(bound.contains(InputBound(trigger: t, action: b.input)), "\(c) \(b.modifiers) missing")
            }
        }
        for (button, kind, action) in InputMap.standardMouse {
            #expect(bound.contains(InputBound(trigger: .mouse(button, kind), action: action)), "\(button) \(kind) missing")
        }
        #expect(parsed.lines.count == Set(parsed.lines.map(\.trigger)).count, "an input appears twice")
    }

    @Test func templateHasTheHeader() {
        let text = InputConfTemplate.text
        #expect(text.hasPrefix("# Loupe"))
        for word in ["ignore", "MX_PANEL-long", "+WHEEL", "+MX_THUMB", "+MOVE", "MBTN_RIGHT+MBTN_MID", "⌘",
                     "on release", "MBTN_FORWARD+WHEEL zoom-step",
                     "MX_GESTURE+WHEEL add vibrance-amount 0.05", "MX_GESTURE cycle-stats", "zoom-step",
                     "MBTN_BACK+WHEEL next-folder"] {
            #expect(text.contains(word), "\(word)")
        }
        #expect(text.hasSuffix("\n"))
    }

    @Test func labels() {
        let rows = InputMap.standard.mouseLabels()
        #expect(rows.contains { $0 == ("Panel + wheel", "Auto colour strength ±0.05") })
        #expect(rows.contains { $0 == ("Right + middle", "Fit width") })
        #expect(rows.map(\.input) == ["Panel", "Panel (hold)", "Panel + wheel", "Panel + move up/down", "Middle",
                                      "Middle (hold)", "Back", "Back (hold)", "Back + wheel", "Forward", "Forward + wheel", "Gesture button",
                                      "Gesture button + wheel", "Three fingers up", "Three fingers down",
                                      "Three-finger tap", "Force click", "Click held + two fingers down",
                                      "Click held + two fingers up", "Right + middle"])
        #expect(rows.contains { $0 == ("Forward + wheel", "Zoom in / out at the pointer") })
        #expect(rows.contains { $0 == ("Back + wheel", "Next / previous folder") })
        #expect(InputMap.title(.zoomStep) == "Zoom in / out at the pointer")
        #expect(rows.first! == ("Panel", "Auto colour on/off (this folder)"))
        let more = map("MX_SHIFT+MX_THUMB add vibrance-amount -0.1\nMX_GESTURE fit\nMX_PANEL ignore").mouseLabels()
        #expect(more.contains { $0 == ("Wheel button + thumb wheel", "Vibrance amount ∓0.10") })
        #expect(more.contains { $0 == ("Gesture button", "Fit to window") })
        let folders = map("MX_PANEL+MOVE previous-folder\nMX_GESTURE next-folder").mouseLabels()
        #expect(folders.contains { $0 == ("Panel + move up/down", "Previous / next folder") })
        #expect(folders.contains { $0 == ("Gesture button", "Next folder") })
        #expect(!more.contains { $0.input == "Panel" })
        #expect(InputMap.title(.add(key: "auto-color-strength", step: 0.125)) == "Auto colour strength ±0.125")
        #expect(InputMap.title(.action(.fill)) == "Fill the window")
    }
}

private struct InputBound: Hashable {
    let trigger: InputTrigger
    let action: InputAction
}
