import Foundation
import Testing
@testable import LoupeCore

/// The settings table (spec §8.1) is the effective layout as rows, from the same merge as `InputMap(lines:)`, and the
/// key recorder writes tokens as the file spells them (§8.2).
@Suite struct BindingRowsTests {
    private func parsed(_ text: String) -> [InputLine] {
        let result = InputConf.parse(text)
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        return result.lines
    }

    private func userLines() throws -> [InputLine] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/input-user.conf")
        return InputConf.parse(try String(contentsOf: url, encoding: .utf8)).lines
    }

    /// What `map` does for the row's input.
    private func effect(_ map: InputMap, _ row: BindingRow) -> InputAction? {
        switch row.trigger {
        case .mouse(let button, let kind): return map.mouse(button, kind)
        case .key(let chord):
            let result = map.keys.lookup(keyCode: chord.keyCode ?? 0xFFFF, character: chord.character,
                                         modifiers: chord.modifiers, isRepeat: false)
            if case .action(let a) = result { return a }
            return nil
        }
    }

    private func check(_ lines: [InputLine]) {
        let map = InputMap(lines: lines)
        let rows = InputMap.rows(lines: lines)
        #expect(rows.count > 40)
        for row in rows {
            if row.source == .off {
                #expect(row.action == .ignore)
                #expect(effect(map, row) == nil, "\(row.input)")
            } else {
                #expect(effect(map, row) == row.action, "\(row.input)")
            }
        }
        // Every key of the built-in table has a row (its action may be the file's), and every bound mouse input too.
        for b in KeyMap.standard.bindings {
            for code in b.keyCodes {
                let chord = KeyChord(keyCode: code, character: nil, modifiers: b.modifiers)
                #expect(rows.contains { $0.trigger == .key(chord) }, "code \(code)")
            }
            if b.keyCodes.isEmpty, let c = b.character {
                #expect(rows.contains { $0.trigger == .key(KeyChord(keyCode: nil, character: c, modifiers: b.modifiers)) }, "\(c)")
            }
        }
        let labels = map.mouseLabels()
        for row in rows where row.isMouse && row.source != .off {
            #expect(labels.first { $0.input == row.input }?.title == row.title, "\(row.input)")
        }
        let mouseRows = rows.filter(\.isMouse).filter { $0.source != .off }
        #expect(mouseRows.map(\.input) == map.mouseLabels().map(\.input))
    }

    @Test func rowsMatchInputMap() throws {
        check([])
        check(try userLines())
        check(parsed("""
            SPACE fit
            Shift+f toggle-strip
            Alt+LEFT ignore
            MBTN_MID ignore
            MX_PANEL-long ignore
            MBTN_FORWARD+WHEEL zoom-step
            MBTN_BACK+MOVE next-folder
            """))
    }

    @Test func standardRowsKeepTheTableOrder() {
        let rows = InputMap.rows(lines: [])
        let keys = rows.filter { !$0.isMouse }
        #expect(keys.first?.input == "?")
        #expect(keys.map(\.input).filter { $0 == "→" || $0 == "Space" || $0 == "PgDn" }.count == 3)
        #expect(rows.allSatisfy { $0.source == .builtIn })
        // Keys first, then buttons.
        #expect(rows.firstIndex(where: \.isMouse)! == keys.count)
        #expect(rows.filter(\.isMouse).count == InputMap.standardMouse.count)
        let f = rows.first { $0.trigger == .key(KeyChord(keyCode: nil, character: "f", modifiers: [])) }
        #expect(f?.input == "F")
        #expect(f?.title == "Toggle full screen")
        let shiftL = rows.first { $0.trigger == .key(KeyChord(keyCode: nil, character: "l", modifiers: .shift)) }
        #expect(shiftL?.input == "⇧L")
    }

    @Test func mouseRowsAreNamedAsTheCheatSheet() {
        let rows = InputMap.rows(lines: parsed("MX_PANEL-long ignore\n")).filter(\.isMouse)
        let names = rows.map(\.input)
        #expect(names.contains("Panel (hold)"))
        #expect(names.contains("Right + wheel"))
        #expect(names.contains("Right + middle"))
        #expect(!names.contains("Right + panel + wheel"))
        #expect(rows.first { $0.input == "Panel (hold)" }?.source == .off)
    }

    @Test func mouseFolderStepsReadAsTheCheatSheet() {
        let rows = InputMap.rows(lines: parsed("MBTN_BACK+MOVE next-folder\nMX_PANEL+WHEEL previous-folder\nMX_GESTURE+MX_THUMB next-folder\n"))
        func title(_ input: String) -> String? { rows.first { $0.input == input }?.title }
        #expect(title("Right + wheel") == "Next / previous folder")        // built-in
        #expect(title("Back + move up/down") == "Next / previous folder")
        #expect(title("Panel + wheel") == "Previous / next folder")
        #expect(title("Gesture button + thumb wheel") == "Next / previous folder")
        #expect(title("Back") == "Previous detected group in the selected profile")
        #expect(title("Right + gesture button") == "Stats bar on/off")
    }

    @Test func keypadKeysAreToldApart() {
        let rows = InputMap.rows(lines: [])
        let names = rows.filter { !$0.isMouse }.map(\.input)
        #expect(names.filter { $0 == "0" }.count == 1)
        #expect(names.contains("Keypad 0"))
        #expect(names.contains("Keypad 4"))
        #expect(names.contains("Keypad -"))
        #expect(Set(names).count == names.count)
        #expect(names.contains("+"))                                     // KP_ADD is the only +
        // The cheat sheet keeps the plain names.
        #expect(!KeyMap.standard.label(.fit).keys.contains("Keypad"))
    }

    @Test func tableShowsLastDuplicate() {
        let lines = parsed("""
            f fit
            Shift+f toggle-strip
            f fill
            """)
        let rows = InputMap.rows(lines: lines)
        let f = rows.filter { $0.trigger == .key(KeyChord(keyCode: nil, character: "f", modifiers: [])) }
        #expect(f.count == 1)
        #expect(f[0].action == .action(.fill))
        #expect(f[0].source == .file(line: 3))
        // The row stays where the built-in `f` was, not at the end.
        let index = rows.firstIndex { $0 == f[0] }!
        #expect(index < rows.firstIndex { $0.source == .file(line: 2) }!)
        #expect(InputMap(lines: lines).keys.action(keyCode: 3, character: "f", modifiers: [], isRepeat: false) == .fill)
    }

    @Test func ignoreLineShowsOff() {
        let rows = InputMap.rows(lines: parsed("f ignore\nMBTN_MID ignore\nPGDWN ignore\n"))
        let f = rows.first { $0.trigger == .key(KeyChord(keyCode: nil, character: "f", modifiers: [])) }!
        #expect(f.source == .off)
        #expect(f.action == .ignore)
        #expect(f.title == "Unbound")
        #expect(rows.first { $0.input == "Middle" }?.source == .off)
        #expect(rows.first { $0.input == "PgDn" }?.source == .off)
        #expect(rows.first { $0.input == "→" }?.source == .builtIn)       // the other keys of `next` stay
    }

    @Test func fileOnlyKeysComeAfterTheBuiltInOnes() {
        let rows = InputMap.rows(lines: parsed("q fit\n"))
        let keys = rows.filter { !$0.isMouse }
        #expect(keys.last?.input == "Q")
        #expect(keys.last?.source == .file(line: 1))
    }

    // MARK: - Key recorder

    @Test func recorderTokenUsesLatinLetter() {
        func token(_ latin: String?, shift: Bool = false, command: Bool = false, control: Bool = false) -> Result<String, KeyTokenRefusal> {
            InputConf.keyToken(keyCode: 3, latinCharacter: latin, shift: shift, option: false, command: command, control: control)
        }
        #expect(token("f") == .success("f"))
        #expect(token("F", shift: true) == .success("F"))
        #expect(token("f", shift: true) == .success("F"))
        #expect(token("f", command: true) == .failure(.menuModifier))
        #expect(token("f", control: true) == .failure(.menuModifier))
        #expect(token(nil) == .failure(.unknownKey))
        #expect(token("я") == .failure(.unknownKey))
        #expect(KeyTokenRefusal.menuModifier.text == "⌘ and ⌃ shortcuts belong to the menus")
    }

    @Test func arrowTokenWithOption() {
        func token(_ code: UInt16, shift: Bool = false, option: Bool = false) -> Result<String, KeyTokenRefusal> {
            InputConf.keyToken(keyCode: code, latinCharacter: nil, shift: shift, option: option, command: false, control: false)
        }
        #expect(token(123, option: true) == .success("Alt+LEFT"))
        #expect(token(123, shift: true) == .success("Shift+LEFT"))
        #expect(token(123, shift: true, option: true) == .success("Shift+Alt+LEFT"))
        #expect(token(49) == .success("SPACE"))
        #expect(token(69) == .success("KP_ADD"))
        #expect(token(44, shift: true) == .success("?"))
        #expect(token(122) == .failure(.unknownKey))                     // F1
    }

    @Test func letterWithOptionKeepsTheLetter() {
        let token = InputConf.keyToken(keyCode: 3, latinCharacter: "f", shift: false, option: true, command: false, control: false)
        #expect(token == .success("Alt+f"))
    }

    @Test func everyRecordedTokenReadsBack() {
        for code in InputConf.keyNames.keys {
            for shift in [false, true] {
                for option in [false, true] {
                    guard case .success(let t) = InputConf.keyToken(keyCode: code, latinCharacter: nil, shift: shift,
                                                                     option: option, command: false, control: false) else {
                        Issue.record("code \(code) refused"); continue
                    }
                    #expect(InputConf.trigger(t) != nil, "\(t)")
                }
            }
        }
    }
}
