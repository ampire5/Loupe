import Testing
@testable import LoupeCore

@Test func grainStageConfiguration() {
    #expect(Config().text(forKey: "grain-stage") == "before")
    for stage in ["before", "after"] {
        let (config,warnings)=Config.parse("grain-stage=\(stage)")
        #expect(warnings.isEmpty)
        #expect(config.text(forKey:"grain-stage") == stage)
        #expect(GrainSettings(config:config).stage.rawValue == stage)
    }
    #expect(Config.parse("grain-stage=unknown").1.count == 1)
}

@Test func displayGrainConfiguration() {
    #expect(Config().text(forKey: "grain") == "off")
    #expect(Config().text(forKey: "grain-amount") == "0.65")
    #expect(Config().text(forKey: "grain-size") == "1")
    for style in ["off", "white", "fine", "soft", "av1", "particles"] {
        let (config, warnings) = Config.parse("grain=\(style)\ngrain-amount=2\ngrain-size=1.5")
        #expect(warnings.isEmpty)
        #expect(config.text(forKey: "grain") == style)
        #expect(config.text(forKey: "grain-amount") == "2")
        #expect(config.text(forKey: "grain-size") == "1.5")
    }
    for line in ["grain=adaptive", "grain-amount=-1", "grain-amount=4", "grain-amount=nan",
                 "grain-size=0", "grain-size=5", "grain-size=inf"] {
        #expect(Config.parse(line).1.count == 1)
    }
}
