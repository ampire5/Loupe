import Testing
@testable import LoupeCore

/// Two gallery clicks in a row (Stash spec §2.2): the later one wins, the earlier one's late result is dropped.
@Test func laterPickWins() {
    var gate = StashPickGate()
    let first = gate.begin()
    let second = gate.begin()
    #expect(!gate.isCurrent(first) && gate.isCurrent(second))
    gate.cancel()
    #expect(!gate.isCurrent(second))
}
