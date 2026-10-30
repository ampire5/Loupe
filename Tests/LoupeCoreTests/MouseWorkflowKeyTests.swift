import Testing
@testable import LoupeCore

@Test func workflowKeysGoBothWaysWithoutAnAccidentalSave() {
    let m = KeyMap.standard
    #expect(m.action(keyCode: 45, character: "n", modifiers: .shift, isRepeat: false) == .previousTarget)
    #expect(m.action(keyCode: 46, character: "m", modifiers: .shift, isRepeat: false) == .previousDetectorMode)
    #expect(m.action(keyCode: 46, character: "m", modifiers: [.option, .shift], isRepeat: false) == .saveDetectorSize)
    #expect(m.action(keyCode: 11, character: "b", modifiers: [], isRepeat: false) == .toggleToolbarPin)
    #expect(m.action(keyCode: 11, character: "b", modifiers: [], isRepeat: true) == nil)
}
