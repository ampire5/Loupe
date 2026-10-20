import Testing
@testable import LoupeCore

@Test func zoomRulesParseModeForms() {
    #expect(ZoomRules.parseMode("fit") == .fit)
    #expect(ZoomRules.parseMode("fit-width") == .fitWidth)
    #expect(ZoomRules.parseMode("fit-height") == .fitHeight)
    #expect(ZoomRules.parseMode("fill") == .fill)
    #expect(ZoomRules.parseMode("FILL") == .fill)
    #expect(ZoomRules.parseMode("100%") == .actual(1))
    #expect(ZoomRules.parseMode("150%") == .actual(1.5))
    #expect(ZoomRules.parseMode("12.5%") == .actual(0.125))
    #expect(ZoomRules.parseMode(" 200 % ") == .actual(2))
}

@Test func zoomRulesParseModeRejects() {
    for bad in ["", "110", "0%", "-5%", "%", "inf%", "nan%", "big", "free", "fit%", "1e999%"] {
        #expect(ZoomRules.parseMode(bad) == nil, "\(bad)")
    }
}

@Test func zoomRulesTextRoundTrip() {
    let modes: [ZoomMode] = [.fit, .fitWidth, .fitHeight, .fill, .actual(1), .actual(1.5), .actual(0.125), .actual(64)]
    for mode in modes {
        #expect(ZoomRules.parseMode(ZoomRules.text(of: mode)) == mode, "\(mode)")
    }
    #expect(ZoomRules.text(of: .actual(1)) == "100%")
    #expect(ZoomRules.text(of: .actual(1.5)) == "150%")
    #expect(ZoomRules.text(of: .actual(0.125)) == "12.5%")
    #expect(ZoomRules.text(of: .fitWidth) == "fit-width")
}

@Test func zoomRulesFromConfig() {
    #expect(ZoomRules(config: Config()) == ZoomRules(config: Config()))
    var c = Config()
    c.keepZoomPosition = false
    c.defaultZoomMode = .actual(2)
    c.fitUpscale = false
    let rules = ZoomRules(config: c)
    #expect(rules.keep == false && rules.defaultMode == .actual(2) && rules.fitUpscale == false)
    let d = ZoomRules(config: Config())
    #expect(d.keep && d.defaultMode == .fit && d.fitUpscale)
}

@Test func panIndicatorModeCycles() {
    #expect(PanIndicatorMode.auto.next == .always)
    #expect(PanIndicatorMode.always.next == .no)
    #expect(PanIndicatorMode.no.next == .auto)
    #expect(PanIndicatorMode.allCases.count == 3)
}
