import CoreGraphics
import LoupeCore
import Testing

@Test func lightTapsAndPhysicalClicksDoNotShareADoubleClickPair() {
    var gestures = PrimaryClickGestures()
    let point = CGPoint(x: 0.5, y: 0.5)
    for time in [1.0, 1.2] {
        #expect(gestures.touches([point], at: time, interval: 0.4) == false)
        #expect(gestures.touches([], at: time + 0.05, interval: 0.4) == (time == 1.2))
        gestures.mouseDown(at: point, time: time + 0.06, touching: false)
        #expect(gestures.mouseUp(at: point, interval: 0.4) == false)
    }
    for time in [2.0, 2.2] {
        #expect(gestures.touches([point], at: time, interval: 0.4) == false)
        gestures.mouseDown(at: point, time: time, touching: true)
        #expect(gestures.pressure(stage: 1) == false)
        #expect(gestures.pressure(stage: 0) == false)
        #expect(gestures.mouseUp(at: point, interval: 0.4) == (time == 2.2))
        #expect(gestures.touches([], at: time + 0.05, interval: 0.4) == false)
    }
}

@Test func twoFastForceClicksNeverOpenTheFolderBrowser() {
    var gestures = PrimaryClickGestures()
    let point = CGPoint(x: 20, y: 10)
    for time in [1.0, 1.2] {
        // Exercise either order of the pressure and mouse streams.
        if time == 1 { gestures.mouseDown(at: point, time: time, touching: true) }
        #expect(gestures.pressure(stage: 1) == false)
        #expect(gestures.pressure(stage: 2) == true)
        if time != 1 { gestures.mouseDown(at: point, time: time, touching: true) }
        #expect(gestures.pressure(stage: 1) == false)
        #expect(gestures.pressure(stage: 2) == false)
        #expect(gestures.pressure(stage: 0) == false)
        #expect(gestures.mouseUp(at: point, interval: 0.4) == false)
    }
    gestures.mouseDown(at: point, time: 1.4, touching: false)
    #expect(gestures.mouseUp(at: point, interval: 0.4) == false)
    gestures.mouseDown(at: point, time: 1.6, touching: false)
    #expect(gestures.mouseUp(at: point, interval: 0.4) == true)
}
