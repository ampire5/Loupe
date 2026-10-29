import Foundation
import Testing
import SlotModel
@testable import LoupeCore

struct ViewerSlotLayoutTests {
    @Test func overlayAvoidsStripWithoutShrinkingPhoto() {
        let outer = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let area = ViewerSlotLayout.area(in: outer, top: 40, bottom: 120)
        #expect(area == CGRect(x: 0, y: 120, width: 1000, height: 540))
        let overlay = SlotLayout.compute(.init(container: CGRect(origin: .zero, size: area.size), slots: [.right: (.overlay, 400)], order: [.right]))
        let insets = ViewerSlotLayout.pinnedInsets(layout: overlay, area: area)
        #expect(insets == .zero)
    }
    @Test func pinnedBottomReservesBandAndSlot() {
        let area = CGRect(x: 0, y: 120, width: 1000, height: 580)
        let pinned = SlotLayout.compute(.init(container: CGRect(origin: .zero, size: area.size), slots: [.bottom: (.pinned, 200)], order: [.bottom]))
        #expect(ViewerSlotLayout.pinnedInsets(layout: pinned, area: area).bottom == 320)
    }
    @Test func duplicateFolderConfigurationKeepsFirstSlotOnly() {
        var settings = FolderSlotSettings.defaults
        settings[.left] = settings[.right]
        let normalized = FolderSlotSettings.normalized(settings)
        #expect(normalized[.left]?.tabs == [SlotTabID(rawValue: "folders")])
        #expect(normalized[.right]?.tabs.isEmpty == true)
    }
    @Test func configRoundTripKeepsFolderTabAndHiddenDefaults() {
        var c = Config()
        #expect(c.slots[.right]?.tabs == [SlotTabID(rawValue: "folders")])
        #expect(c.slots[.right]?.shown == false)
        let value = "folders, pinned, dark, manual, 480, shown, tongue"
        #expect(c.set("slot-left", value) == .ok)
        #expect(c.text(forKey: "slot-left") == value)
    }
}
