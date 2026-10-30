import Testing
@testable import LoupeCore

@Test func choicesStepBothWaysAndHandleMissingGroups() {
    #expect(ChoiceCycle.index(current: 0, count: 3, direction: -1) == 2)
    #expect(ChoiceCycle.index(current: 2, count: 3, direction: 1) == 0)
    #expect(ChoiceCycle.index(current: nil, count: 3, direction: -1) == 2)
    #expect(ChoiceCycle.index(current: nil, count: 3, direction: 1) == 0)
    #expect(ChoiceCycle.index(current: 0, count: 0, direction: 1) == nil)
    #expect(ChoiceCycle.index(current: 0, count: 3, direction: 0) == nil)
    #expect(ChoiceCycle.index(current: 0, count: 1, direction: -1) == 0)
}
