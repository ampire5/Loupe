import Testing
@testable import LoupeCore

/// A names-only part never replaces a complete listing of the same place: Home's return to a folder delivers the
/// kept listing first, and the share's names-only pass of its relist must not wipe its stamps (as the kit's browser
/// ignores it on screen).
@Suite struct BrowserListingGateTests {
    @Test func namesOnlyAfterCompleteIsHeldBack() {
        var gate = BrowserListingGate()
        let token = gate.begin("/Volumes/S/a")
        let names = gate.admits(complete: false, token: token)
        let complete = gate.admits(complete: true, token: token)
        let relistNames = gate.admits(complete: false, token: token)   // the relist's names-only part
        let relistComplete = gate.admits(complete: true, token: token) // the relist's complete one
        #expect(names && complete && relistComplete)
        #expect(!relistNames)
    }

    @Test func aNewPlaceStartsWithoutAComplete() {
        var gate = BrowserListingGate()
        let first = gate.begin("/Volumes/S/a")
        _ = gate.admits(complete: true, token: first)
        let second = gate.begin("/Volumes/S/a")
        let names = gate.admits(complete: false, token: second)
        let older = gate.admits(complete: true, token: first)          // an older place's listing is never admitted
        #expect(names)
        #expect(!older)
    }
}
