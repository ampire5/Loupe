import Testing
@testable import LoupeCore

// MARK: L / ⇧L (M4b spec §4.4)

@Test func zoomKeysToggle() {
    var config = Config()
    #expect(config.keepZoomPosition)
    #expect(ZoomKeys.toggled(config) == "no")
    _ = config.set("keep-zoom-position", "no")
    #expect(ZoomKeys.toggled(config) == "yes")
    #expect(ZoomKeys.keepKey == "keep-zoom-position")
    #expect(Config.zoomFolderKeys.contains(ZoomKeys.keepKey))
}

@Test func zoomCarryKeyToggles() {
    var config = Config()
    #expect(config.keepZoomAs == .share)
    #expect(ZoomKeys.toggledCarry(config) == .scale)
    _ = config.set("keep-zoom-as", "scale")
    #expect(ZoomKeys.toggledCarry(config) == .share)
    #expect(Config.zoomFolderKeys.contains(ZoomKeys.carryKey))
    #expect(ZoomKeys.toast(carry: .scale) == "Zoom keeps: scale · folder")
}

@Test func zoomKeysToasts() {
    #expect(ZoomKeys.toast(keep: true) == "Keep zoom: on · folder")
    #expect(ZoomKeys.toast(keep: false) == "Keep zoom: off · folder")
    #expect(ZoomKeys.keepSaved == "Keep zoom saved as default")
}
