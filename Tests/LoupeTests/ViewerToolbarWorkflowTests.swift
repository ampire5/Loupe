import AppKit
import LoupeCore
import Testing
@testable import Loupe

@MainActor @Suite(.serialized) struct ViewerToolbarWorkflowTests {
    @Test func workflowReplacesOnlyTheModeGroupAndRestoresItAfterHome() throws {
        _ = NSApplication.shared
        var smartActions: [SmartZoomMode] = []
        let source = ViewerToolbarController(actions: .init(back: {}, step: { _ in }, zoom: { _ in },
            colour: { _ in }, setValue: { _, _ in }, stats: {}, strip: {}, info: {}, smartZoom: {}, statusAction: { if case .mode(let mode) = $0 { smartActions.append(mode) } }))
        let host = WindowToolbarController()
        source.onZoomModesChange = { old, new in host.replaceItem(old, with: new, source: source.nsToolbar) }
        host.show(source.nsToolbar)
        let back = try #require(host.toolbar.items.first { $0.itemIdentifier.rawValue == "viewer.back" })
        let manual = try #require(host.toolbar.items.first { $0.itemIdentifier.rawValue == "viewer.zoomModes" })
        var status = ImageStatus()
        status.photo = URL(fileURLWithPath: "/Demo/photo.jpg")
        status.zoomDetails = .init(mode: .frame, profile: "balanced", group: "Subject", scale: 1, keepingZoom: false)
        source.updateStatus(status, zoomMode: .fit)
        let smart = try #require(host.toolbar.items.first { $0.itemIdentifier.rawValue == "viewer.smartModes" } as? NSToolbarItemGroup)
        #expect(smart.subitems.map(\.label) == ["Auto", "Pan only"])
        #expect(smart.selectedIndex == 0)
        let action = try #require(smart.action)
        for index in 0..<2 {
            smart.selectedIndex = index
            #expect(NSApp.sendAction(action, to: smart.target, from: smart))
        }
        #expect(smartActions == [.frame, .pan])
        #expect(!host.toolbar.items.contains { $0 === manual })
        #expect(host.toolbar.items.contains { $0 === back })
        status.zoomDetails?.mode = .off
        source.updateStatus(status, zoomMode: .actual(1))
        #expect(host.toolbar.items.contains { $0 === manual })
        #expect((manual as? NSToolbarItemGroup)?.selectedIndex == 1)
        let home = NSToolbar(identifier: "workflow-test.home")
        host.show(home)
        status.zoomDetails?.mode = .pan
        source.updateStatus(status, zoomMode: .fill)
        #expect(host.toolbar.items.isEmpty)
        host.show(source.nsToolbar)
        #expect(host.toolbar.items.contains { $0 === smart })
        #expect(smart.selectedIndex == 1)
        #expect(host.toolbar.items.filter { ["viewer.zoomModes", "viewer.smartModes"].contains($0.itemIdentifier.rawValue) }.count == 1)
    }
}
