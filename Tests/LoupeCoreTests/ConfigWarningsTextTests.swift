import Testing
@testable import LoupeCore

@Test func noWarningsNoText() {
    #expect(ConfigWarningsText.block(for: []) == nil)
}

@Test func oneWarningUnderAHeader() {
    let text = ConfigWarningsText.block(for: ["loupe.conf:129: bad option 'strip-magnify-reach=0.00'"])
    #expect(text == """
        Config: 1 problem, ignored — defaults used
        loupe.conf:129: bad option 'strip-magnify-reach=0.00'
        """)
}

@Test func warningsPastTheLimitAreCounted() {
    let warnings = (1...11).map { "loupe.conf:\($0): bad option 'x\($0)'" }
    let lines = (ConfigWarningsText.block(for: warnings) ?? "").split(separator: "\n").map(String.init)
    #expect(lines.count == 1 + 8 + 1)
    #expect(lines.first == "Config: 11 problems, ignored — defaults used")
    #expect(lines[8] == "loupe.conf:8: bad option 'x8'")
    #expect(lines.last == "…and 3 more")
    // Exactly at the limit nothing is left out.
    let exact = (ConfigWarningsText.block(for: Array(warnings.prefix(8))) ?? "").split(separator: "\n")
    #expect(exact.count == 9 && exact.last == "loupe.conf:8: bad option 'x8'")
}

/// input.conf's problems follow loupe.conf's under the one header, which names neither file (M4c spec §2.1).
@Test func bothFilesUnderOneHeader() {
    let warnings = ["loupe.conf:3: unknown key 'zoom'", "input.conf:12: unknown action \"fitt\""]
    let text = ConfigWarningsText.block(for: warnings)
    #expect(text == """
        Config: 2 problems, ignored — defaults used
        loupe.conf:3: unknown key 'zoom'
        input.conf:12: unknown action "fitt"
        """)
}
