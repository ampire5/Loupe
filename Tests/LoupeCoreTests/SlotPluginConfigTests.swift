import Testing
@testable import LoupeCore

@Test func slotPluginEntriesAndAssignmentsAreOrderIndependent() {
    let (config, warnings) = Config.parse("""
        slot-left=plugin:alpha, overlay, glass, mouse-leaves, 400, hidden, at-once
        plugin=Alpha | https://alpha.example:8443/plugin
        plugin=Beta | https://beta.example/panel
        plugin=Alpha | https://alpha.example/replacement
        """)
    #expect(warnings.isEmpty)
    #expect(config.plugins.map(\.name) == ["Alpha", "Beta"])
    #expect(config.plugins.first?.url.absoluteString == "https://alpha.example:8443/plugin")
    #expect(config.slots[.left]?.tabs.map(\.rawValue) == ["plugin:alpha"])
}

@Test func slotPluginOnlyUsesConfiguredHTTPSOrigins() {
    let (config, warnings) = Config.parse("""
        plugin=Insecure | http://example.org/plugin
        plugin=Credentials | https://secret@example.org/plugin
        plugin=Valid | https://EXAMPLE.org:443/plugin
        """)
    #expect(warnings.count == 2)
    #expect(config.plugins.map(\.name) == ["Valid"])
}
