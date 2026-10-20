import Testing
@testable import LoupeCore

private final class Driver {
    private var gate = TagGate<String>()
    func decide(_ tag: String) -> TagGate<String>.Decision { gate.decide(required: tag) }
}

@Test func theFirstFrameRetagsAndDefers() {
    #expect(Driver().decide("P3") == .retagAndDefer)
}

@Test func theFrameAfterARetagDraws() {
    let g = Driver()
    #expect(g.decide("sRGB") == .retagAndDefer)
    #expect(g.decide("sRGB") == .draw)
    #expect(g.decide("sRGB") == .draw)
}

@Test func aNewColourSpaceDefersOnceThenDraws() {
    let g = Driver()
    #expect(g.decide("P3") == .retagAndDefer)
    #expect(g.decide("P3") == .draw)
    #expect(g.decide("AdobeRGB") == .retagAndDefer)
    #expect(g.decide("AdobeRGB") == .draw)
    #expect(g.decide("P3") == .retagAndDefer)
}
