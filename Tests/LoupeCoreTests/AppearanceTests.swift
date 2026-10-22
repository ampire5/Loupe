import Testing
@testable import LoupeCore

@Test func appearanceKeySetsTheApp() {
    #expect(AppAppearance.dark.prefersDark == true)
    #expect(AppAppearance.light.prefersDark == false)
    #expect(AppAppearance.system.prefersDark == nil)
}
