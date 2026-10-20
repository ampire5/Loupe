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

@Test func zoomKeysToasts() {
    #expect(ZoomKeys.toast(keep: true) == "Keep zoom: on · folder")
    #expect(ZoomKeys.toast(keep: false) == "Keep zoom: off · folder")
    #expect(ZoomKeys.keepSaved == "Keep zoom saved as default")
}
