import Testing
@testable import LoupeCore

/// `InputConfText` edits `input.conf` in place (spec §8.3) and `InputConf.text(of:)` writes inputs and actions back as
/// the file names them.
@Suite struct InputConfTextTests {
    private func key(_ code: UInt16, _ modifiers: KeyModifiers = []) -> InputTrigger {
        .key(KeyChord(keyCode: code, character: nil, modifiers: modifiers))
    }

    private func letter(_ c: String, _ modifiers: KeyModifiers = []) -> InputTrigger {
        .key(KeyChord(keyCode: nil, character: c, modifiers: modifiers))
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The text parses without warnings.
    private func parsed(_ text: String) -> [InputLine] {
        let result = InputConf.parse(text)
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        return result.lines
    }

    // MARK: - Names

    @Test func textRoundTrips() {
        var triggers: [(InputTrigger, InputAction)] = InputMap.standardMouse.map { (.mouse($0.0, $0.1), $0.2) }
        for b in KeyMap.standard.bindings {
            for code in b.keyCodes { triggers.append((key(code, b.modifiers), b.input)) }
            if let c = b.character, c.count == 1, c.first!.isLetter {
                triggers.append((letter(c, b.modifiers), b.input))
            }
        }
        #expect(triggers.count > 60)
        for (t, a) in triggers {
            let triggerText = InputConf.text(of: t)
            #expect(InputConf.trigger(triggerText) == t, "\(triggerText)")
            let result = InputConf.parse("\(triggerText) \(InputConf.text(of: a))\n")
            #expect(result.warnings.isEmpty, "\(triggerText): \(result.warnings)")
            #expect(result.lines.count == 1 && result.lines[0].trigger == t && result.lines[0].action == a, "\(triggerText)")
        }
        var actions: [InputAction] = KeyAction.allCases.map { .action($0) }
        actions += [.zoomStep, .ignore, .add(key: "vibrance-amount", step: 0.05),
                    .add(key: "auto-color-strength", step: -0.25), .add(key: "vibrance-amount", step: 1)]
        for a in actions {
            let result = InputConf.parse("f \(InputConf.text(of: a))\n")
            #expect(result.lines.first?.action == a && result.warnings.isEmpty, "\(InputConf.text(of: a))")
        }
    }

    @Test func textIsCanonical() {
        #expect(InputConf.text(of: letter("f")) == "f")
        #expect(InputConf.text(of: letter("l", .shift)) == "L")
        #expect(InputConf.text(of: letter("l", .option)) == "Alt+l")
        #expect(InputConf.text(of: key(123, .shift)) == "Shift+LEFT")
        #expect(InputConf.text(of: key(123, [.shift, .option])) == "Shift+Alt+LEFT")
        #expect(InputConf.text(of: key(44, .shift)) == "?")
        #expect(InputConf.text(of: key(44)) == "/")
        #expect(InputConf.text(of: key(69)) == "KP_ADD")
        #expect(InputConf.text(of: .mouse(.middle, .tap)) == "MBTN_MID")
        #expect(InputConf.text(of: .mouse(.panel, .long)) == "MX_PANEL-long")
        #expect(InputConf.text(of: .mouse(.back, .wheel)) == "MBTN_BACK+WHEEL")
        #expect(InputConf.text(of: .mouse(.gesture, .thumbWheel)) == "MX_GESTURE+MX_THUMB")
        #expect(InputConf.text(of: .mouse(.panel, .move)) == "MX_PANEL+MOVE")
        #expect(InputConf.text(of: .mouse(.middle, .withRight)) == "MBTN_RIGHT+MBTN_MID")
        #expect(InputConf.text(of: .action(.fit)) == "fit")
        #expect(InputConf.text(of: .action(.actual100)) == "actual-100")
        #expect(InputConf.text(of: .add(key: "vibrance-amount", step: 0.05)) == "add vibrance-amount 0.05")
        #expect(InputConf.text(of: .zoomStep) == "zoom-step")
        #expect(InputConf.text(of: .ignore) == "ignore")
    }

    // MARK: - Placement

    @Test func activeLineReplaced() {
        let text = "# header\nf fit  # my note\nc fill\n"
        let out = InputConfText.binding(letter("f"), to: .action(.fill), in: text)
        let rows = lines(out)
        #expect(rows[0] == "# header")
        #expect(rows[1].hasPrefix("f fill") && rows[1].hasSuffix("# my note"), "\(rows[1])")
        #expect(rows[2] == "c fill")
        #expect(rows.count == 4)
    }

    @Test func lastDuplicateIsReplaced() {
        let text = "f fit\nc fill\nf next\n"
        let out = InputConfText.binding(letter("f"), to: .action(.last), in: text)
        #expect(lines(out) == ["f fit", "c fill", "f last", ""])
        let result = parsed(out)
        #expect(result.last { $0.trigger == letter("f") }?.action == .action(.last))
    }

    @Test func commentedTemplateLineUncommented() {
        let out = InputConfText.binding(letter("f"), to: .action(.fill), in: InputConfTemplate.text)
        let result = parsed(out)
        #expect(result.count == 1)
        #expect(result[0].trigger == letter("f") && result[0].action == .action(.fill))
        let template = lines(InputConfTemplate.text)
        let at = template.firstIndex { $0.hasPrefix("# f toggle-full-screen") }!
        #expect(result[0].line == at + 1)
        let row = lines(out)[at]
        #expect(row.hasPrefix("f fill") && row.contains("# full screen"), "\(row)")
        #expect(lines(out).count == template.count)
    }

    @Test func templateDocLineIsNotUncommented() {
        // `#   MX_GESTURE+MX_THUMB add vibrance-amount 0.05   hold + thumb wheel…` is documentation, not a binding.
        let out = InputConfText.binding(.mouse(.gesture, .thumbWheel), to: .action(.fit), in: InputConfTemplate.text)
        let result = parsed(out)
        #expect(result.count == 1 && result[0].trigger == .mouse(.gesture, .thumbWheel))
        let row = lines(out)[result[0].line - 1]
        #expect(row == "MX_GESTURE+MX_THUMB fit", "\(row)")
        // It lands after the last mouse line of the template.
        let template = lines(InputConfTemplate.text)
        let last = template.lastIndex { $0.hasPrefix("# MBTN_RIGHT+MBTN_MID fit-width") }!
        #expect(result[0].line == last + 2)
    }

    @Test func newKeyGoesAfterKeyGroup() {
        let text = "# keys\nf fit\n# c fill\nMBTN_MID fit\n# MX_PANEL fit\n# tail\n"
        let out = InputConfText.binding(letter("q"), to: .action(.last), in: text)
        #expect(lines(out) == ["# keys", "f fit", "# c fill", "q last", "MBTN_MID fit", "# MX_PANEL fit", "# tail", ""])
    }

    @Test func newMouseGoesAfterMouseGroup() {
        let text = "f fit\nMBTN_MID fit\n# MX_PANEL fit\n# tail\nc fill\n"
        let out = InputConfText.binding(.mouse(.back, .tap), to: .action(.last), in: text)
        #expect(lines(out) == ["f fit", "MBTN_MID fit", "# MX_PANEL fit", "MBTN_BACK last", "# tail", "c fill", ""])
    }

    @Test func newInputAppendsWhenGroupIsAbsent() {
        #expect(InputConfText.binding(letter("f"), to: .action(.fit), in: "") == "f fit\n")
        #expect(InputConfText.binding(.mouse(.back, .tap), to: .action(.fit), in: "# note\nf fit")
            == "# note\nf fit\nMBTN_BACK fit\n")
        #expect(InputConfText.binding(.mouse(.back, .tap), to: .action(.fit), in: "# note\n") == "# note\nMBTN_BACK fit\n")
    }

    @Test func ignoreForBuiltIn() {
        let t = key(123)
        let out = InputConfText.binding(t, to: .ignore, in: InputConfTemplate.text)
        let result = parsed(out)
        #expect(result.count == 1 && result[0].trigger == t && result[0].action == .ignore)
        let map = InputMap(lines: result)
        #expect(map.keys.lookup(keyCode: 123, character: nil, modifiers: [], isRepeat: false) == .unbound)
    }

    @Test func restoringBuiltInCommentsOut() {
        let text = "f fit  # a\nc fill\n  f next\nShift+LEFT fit\n"
        let out = InputConfText.restoringBuiltIn(letter("f"), in: text)
        #expect(lines(out) == ["# f fit  # a", "c fill", "#   f next", "Shift+LEFT fit", ""])
        #expect(parsed(out).map(\.trigger) == [letter("c"), key(123, .shift)])
        #expect(InputConfText.restoringBuiltIn(letter("z"), in: text) == text)
    }

    @Test func shiftLetterSameInput() {
        let text = "L save-keep-zoom  # note\nc fill\n"
        let out = InputConfText.binding(letter("l", .shift), to: .action(.fit), in: text)
        let result = parsed(out)
        #expect(result.count == 2)
        #expect(result[0].trigger == letter("l", .shift) && result[0].action == .action(.fit))
        #expect(lines(out)[0].hasSuffix("# note"))
    }

    @Test func lineEndingsAndBOMSurvive() {
        let text = "\u{FEFF}f fit\r\nc fill\r\n"
        let out = InputConfText.binding(letter("f"), to: .action(.last), in: text)
        #expect(out == "\u{FEFF}f last\r\nc fill\r\n")
        let added = InputConfText.binding(letter("q"), to: .action(.last), in: text)
        #expect(InputConfText.restoringBuiltIn(letter("f"), in: text) == "\u{FEFF}# f fit\r\nc fill\r\n")
        #expect(added == "\u{FEFF}f fit\r\nc fill\r\nq last\r\n")
    }
}
