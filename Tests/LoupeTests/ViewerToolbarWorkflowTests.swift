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

    @Test func switchingSourcesKeepsSharedControlsAndReplacesDistinctItemsWithTheSameIdentifier() {
        _ = NSApplication.shared
        let shared = NSToolbarItem(itemIdentifier: .init("test.shared"))
        let old = NSToolbarItem(itemIdentifier: .init("test.mode"))
        let new = NSToolbarItem(itemIdentifier: old.itemIdentifier)
        let viewer = TestToolbarSource(order: [old.itemIdentifier, .flexibleSpace, shared.itemIdentifier],
                                       items: [old, shared])
        let browser = TestToolbarSource(order: [.flexibleSpace, new.itemIdentifier, .flexibleSpace, shared.itemIdentifier],
                                        items: [new, shared])
        let host = WindowToolbarController()
        host.show(viewer.toolbar)
        let removals = ToolbarRemovals()
        NotificationCenter.default.addObserver(removals, selector: #selector(ToolbarRemovals.removed(_:)),
                                               name: NSToolbar.didRemoveItemNotification, object: host.toolbar)
        defer { NotificationCenter.default.removeObserver(removals) }

        for (source, expected) in [(browser, new), (viewer, old)] {
            let spacers = host.toolbar.items.filter { $0.itemIdentifier == .flexibleSpace }
            host.show(source.toolbar)
            #expect(host.toolbar.itemIdentifiers == source.order)
            #expect(host.toolbar.items.first { $0.itemIdentifier == expected.itemIdentifier } === expected)
            #expect(host.toolbar.items.contains { item in spacers.contains { $0 === item } })
        }
        #expect(removals.items.contains { $0 === old })
        #expect(removals.items.contains { $0 === new })
        #expect(!removals.items.contains { $0 === shared })
    }
}

@MainActor private final class TestToolbarSource: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: UUID().uuidString)
    let order: [NSToolbarItem.Identifier]
    private let items: [NSToolbarItem.Identifier: NSToolbarItem]

    init(order: [NSToolbarItem.Identifier], items: [NSToolbarItem]) {
        self.order = order
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.itemIdentifier, $0) })
        super.init()
        toolbar.delegate = self
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { order }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { order }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { items[identifier] }
}

@MainActor private final class ToolbarRemovals: NSObject {
    private(set) var items: [NSToolbarItem] = []

    @objc func removed(_ notification: Notification) {
        if let item = notification.userInfo?[NSToolbarUserInfoKey.itemKey.rawValue] as? NSToolbarItem {
            items.append(item)
        }
    }
}
