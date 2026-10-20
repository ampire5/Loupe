import LoupeCore
import Testing

@Test func stepWaitParses() {
    for wait in StepWait.allCases {
        #expect(StepWait(text: wait.rawValue) == wait)
        #expect(StepWait(text: wait.rawValue.uppercased()) == wait)
    }
    #expect(StepWait(text: "Coarse") == .coarse)
    #expect(StepWait(text: "blurry") == nil)
    #expect(StepWait(text: "") == nil)
}

// Levels: 0 is full resolution; the scale needs level 2 in these cases.

@Test func shownQualityOfEveryBranch() {
    // A failure is on screen: nothing better will come, so no wait holds on to it.
    #expect(ShownQuality.of(finestResident: nil, neededLevel: 2, seededOnly: false, failed: true) == .sharp)
    #expect(ShownQuality.of(finestResident: 5, neededLevel: 2, seededOnly: true, failed: true) == .sharp)
    #expect(ShownQuality.of(finestResident: nil, neededLevel: 2, seededOnly: false, failed: false) == nil)
    #expect(ShownQuality.of(finestResident: 1, neededLevel: 2, seededOnly: true, failed: false) == .thumb)
    #expect(ShownQuality.of(finestResident: 2, neededLevel: 2, seededOnly: false, failed: false) == .sharp)
    #expect(ShownQuality.of(finestResident: 3, neededLevel: 2, seededOnly: false, failed: false) == .coarse)
    #expect(ShownQuality.of(finestResident: 6, neededLevel: 2, seededOnly: false, failed: false) == .coarse)
    #expect(ShownQuality.of(finestResident: 0, neededLevel: 2, seededOnly: false, failed: false) == .sharp)
}

@Test func shownQualityIsOrdered() {
    #expect(ShownQuality.thumb < .coarse && ShownQuality.coarse < .sharp)
}

@Test func stepWaitSatisfiedTable() {
    let qualities: [ShownQuality?] = [nil, .thumb, .coarse, .sharp]
    let expected: [StepWait: [Bool]] = [
        .thumb: [false, true, true, true],
        .coarse: [false, false, true, true],
        .sharp: [false, false, false, true],
        .any: [true, true, true, true],
    ]
    for wait in StepWait.allCases {
        for (quality, satisfied) in zip(qualities, expected[wait]!) {
            #expect(wait.isSatisfied(by: quality) == satisfied, "\(wait) \(String(describing: quality))")
        }
    }
}
