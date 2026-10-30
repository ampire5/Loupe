import AppKit
import Testing
@testable import Loupe

@MainActor @Suite(.serialized) struct ViewerToolbarBackTests {
    @Test func returnDestinationUpdatesTheRetainedNativeItem() throws {
        _ = NSApplication.shared
        let controller = ViewerToolbarController(actions: .init(back: {}, step: { _ in }, zoom: { _ in },
            colour: { _ in }, setValue: { _, _ in }, stats: {}, strip: {}, info: {}, smartZoom: {}))
        let identifier = NSToolbarItem.Identifier("viewer.back")
        let item = try #require(controller.toolbar(controller.nsToolbar, itemForItemIdentifier: identifier,
                                                   willBeInsertedIntoToolbar: true))
        let action = item.action
        for destination in ["Recent", "Folders", "Photos"] {
            controller.setBackDestination(destination)
            #expect(item.title == destination)
            #expect(item.label == "Back to \(destination)")
            #expect(item.toolTip == "Back to \(destination)")
            #expect(item.isEnabled)
            #expect(item.image != nil)
            #expect(item.action == action)
            #expect(controller.toolbar(controller.nsToolbar, itemForItemIdentifier: identifier,
                                        willBeInsertedIntoToolbar: true) === item)
        }
        controller.setBackDestination(nil)
        #expect(!item.isEnabled)
        #expect(item.title == "Back")
        #expect(item.label == "Back")
    }
}
