import Testing
@testable import LoupeCore

@Test func folderAdjustSteps() {
    let k = "auto-color-strength"
    #expect(FolderAdjust.stepped(0.6, step: 0.05, times: 1, key: k) == (0.65, false))
    #expect(FolderAdjust.stepped(0.62, step: 0.05, times: 1, key: k) == (0.65, false))   // snaps to the step
    #expect(FolderAdjust.stepped(0.98, step: 0.05, times: 1, key: k) == (1.0, true))
    #expect(FolderAdjust.stepped(1.0, step: 0.05, times: 1, key: k) == (1.0, true))
    #expect(FolderAdjust.stepped(0.03, step: 0.05, times: -1, key: k) == (0.0, true))
    #expect(FolderAdjust.stepped(0.0, step: 0.05, times: -1, key: k) == (0.0, true))
    #expect(FolderAdjust.stepped(0.5, step: 0.05, times: -3, key: k) == (0.35, false))
    // Reaching a bound exactly is not a limit hit; a negative step reverses the direction.
    #expect(FolderAdjust.stepped(0.95, step: 0.05, times: 1, key: k) == (1.0, false))
    #expect(FolderAdjust.stepped(0.5, step: -0.05, times: 1, key: k) == (0.45, false))
    // Ten steps from 0 do not drift (0.1 * 10 is not 1.0 in floating point).
    var v = 0.0
    for _ in 0..<10 { v = FolderAdjust.stepped(v, step: 0.1, times: 1, key: "vibrance-amount").value }
    #expect(v == 1.0)
}

@Test func folderAdjustDetents() {
    for k in ["auto-color-strength", "vibrance-amount"] {
        #expect(FolderAdjust.detents == [0.25, 0.5, 0.75])
        #expect(FolderAdjust.crossesDetent(from: 0.45, to: 0.50, key: k))          // onto
        #expect(!FolderAdjust.crossesDetent(from: 0.50, to: 0.55, key: k))         // off it is not a crossing
        #expect(FolderAdjust.crossesDetent(from: 0.70, to: 0.80, key: k))          // across, a multi-step wheel
        #expect(FolderAdjust.crossesDetent(from: 0.80, to: 0.70, key: k))          // downwards too
        #expect(FolderAdjust.crossesDetent(from: 0.55, to: 0.50, key: k))
        #expect(!FolderAdjust.crossesDetent(from: 0.25, to: 0.20, key: k))
        #expect(FolderAdjust.crossesDetent(from: 0.20, to: 0.25, key: k))
        #expect(!FolderAdjust.crossesDetent(from: 0.60, to: 0.60, key: k))         // nothing moved
        #expect(!FolderAdjust.crossesDetent(from: 0.50, to: 0.50, key: k))
        #expect(!FolderAdjust.crossesDetent(from: 0.0, to: 0.20, key: k))
        #expect(!FolderAdjust.crossesDetent(from: 0.80, to: 1.0, key: k))
    }
    // Through `stepped`: the moved value (rounded to the step) is what counts, and the limit wins at a bound.
    let k = "vibrance-amount"
    let up = FolderAdjust.stepped(0.45, step: 0.05, times: 1, key: k)
    #expect(up.value == 0.5 && !up.hitLimit && FolderAdjust.crossesDetent(from: 0.45, to: up.value, key: k))
    for (from, n) in [(1.0, 1), (0.0, -1)] {
        let r = FolderAdjust.stepped(from, step: 0.05, times: n, key: k)
        #expect(r.hitLimit && !FolderAdjust.crossesDetent(from: from, to: r.value, key: k))
    }
}

@Test func folderAdjustText() {
    #expect(FolderAdjust.text(0.65) == "0.65" && FolderAdjust.text(1) == "1.00" && FolderAdjust.text(0) == "0.00")
    #expect(FolderAdjust.toast(key: "auto-color-strength", value: 0.65, enabled: true) == "Auto colour strength 0.65 · folder")
    #expect(FolderAdjust.toast(key: "vibrance-amount", value: 0.4, enabled: false) == "Vibrance amount 0.40 · folder (off)")
    #expect(Set(FolderAdjust.ranges.keys) == ["auto-color-strength", "vibrance-amount"])
}

@Test func folderAdjustReadsTheValueAndWhetherItsFeatureIsOn() {
    var config = Config()
    config.autoColorStrength = 0.65
    config.vibrance = true
    config.vibranceAmount = 0.4
    #expect(FolderAdjust.current("auto-color-strength", in: config)! == (0.65, false))
    #expect(FolderAdjust.current("vibrance-amount", in: config)! == (0.4, true))
    #expect(FolderAdjust.current("auto-color", in: config) == nil)
    // Every key `add` takes has a value to read.
    #expect(FolderAdjust.ranges.keys.allSatisfy { FolderAdjust.current($0, in: config) != nil })
}
