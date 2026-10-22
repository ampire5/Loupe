import Testing
import LoupeCore

/// Which scroll the strip takes: precise scrolling with no folder-gesture button held. A notched wheel steps photos
/// as everywhere, a held button is the folder gesture's (unless the strip's own press holds it), and precise
/// scrolling during the strip's own press does nothing.
@Test func scrollRoutes() {
    #expect(StripRoute.route(precise: false, held: [], folderGesture: true, pressed: false, spent: false) == .owner)
    #expect(StripRoute.route(precise: false, held: .right, folderGesture: true, pressed: false, spent: false) == .owner)
    #expect(StripRoute.route(precise: false, held: [], folderGesture: true, pressed: true, spent: false) == .owner)
    #expect(StripRoute.route(precise: true, held: [], folderGesture: true, pressed: false, spent: false) == .strip)
    #expect(StripRoute.route(precise: true, held: .left, folderGesture: true, pressed: false, spent: false) == .owner)
    #expect(StripRoute.route(precise: true, held: .right, folderGesture: true, pressed: false, spent: false) == .owner)
    #expect(StripRoute.route(precise: true, held: .left, folderGesture: false, pressed: false, spent: false) == .strip)
    #expect(StripRoute.route(precise: true, held: .left, folderGesture: true, pressed: true, spent: false) == .ignore)
    #expect(StripRoute.route(precise: true, held: [], folderGesture: true, pressed: true, spent: false) == .ignore)
}

/// The rest of a gesture the viewer's guard has spent (a folder step fired and the click was let go while the
/// fingers swipe or coast on, a three-finger swipe) must not scrub the new folder. The guard is asked only for the
/// strip's own scroll: asking feeds it, and the wheel, a held button and a press go elsewhere first.
@Test func spentGestureIsIgnored() {
    #expect(StripRoute.route(precise: true, held: [], folderGesture: true, pressed: false, spent: true) == .ignore)
    #expect(StripRoute.route(precise: true, held: .left, folderGesture: false, pressed: false, spent: true) == .ignore)
    var asked = 0
    func spent() -> Bool {
        asked += 1
        return true
    }
    _ = StripRoute.route(precise: false, held: [], folderGesture: true, pressed: false, spent: spent())
    _ = StripRoute.route(precise: true, held: .left, folderGesture: true, pressed: false, spent: spent())
    _ = StripRoute.route(precise: true, held: [], folderGesture: true, pressed: true, spent: spent())
    #expect(asked == 0)
    _ = StripRoute.route(precise: true, held: [], folderGesture: true, pressed: false, spent: spent())
    #expect(asked == 1)
}
