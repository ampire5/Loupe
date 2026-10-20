import Testing
@testable import LoupeCore

/// The viewer's keys that work in its window whatever it shows (Home, a page with no photo): full screen only.
@Suite struct WindowKeysTests {
    private func lookup(_ keys: KeyMap, _ code: UInt16, _ character: String? = nil, _ modifiers: KeyModifiers = [],
                        repeat isRepeat: Bool = false) -> KeyMap.Lookup {
        keys.windowLookup(keyCode: code, character: character, modifiers: modifiers, isRepeat: isRepeat)
    }

    @Test func fullScreenKeyWorksOffThePhoto() {
        #expect(lookup(.standard, 3, "f") == .action(.action(.toggleFullScreen)))
        #expect(lookup(.standard, 3, "f", repeat: true) == .ignoredRepeat)
    }

    /// Any other key, bound or not, stays with what is on screen (Home's arrows, typing a name, its own Tab).
    @Test func otherKeysAreNotTheWindows() {
        #expect(lookup(.standard, 17, "t") == .unbound)                 // toggle strip
        #expect(lookup(.standard, 44, "?", .shift) == .unbound)         // cheat sheet
        #expect(lookup(.standard, 124) == .unbound)                     // next photo
        #expect(lookup(.standard, 53) == .unbound)                      // Esc
        #expect(lookup(.standard, 0, "a") == .unbound)
    }

    /// input.conf moves full screen: the new key works off the photo, the unbound F types again.
    @Test func followsInputConf() {
        let parsed = InputConf.parse("f ignore\ng toggle-full-screen\n")
        #expect(parsed.warnings.isEmpty, "\(parsed.warnings)")
        let keys = InputMap(lines: parsed.lines).keys
        #expect(lookup(keys, 3, "f") == .unbound)
        #expect(lookup(keys, 5, "g") == .action(.action(.toggleFullScreen)))
    }
}
