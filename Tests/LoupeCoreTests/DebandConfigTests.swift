import Testing
@testable import LoupeCore

struct DebandConfigTests {
    @Test func globalDefaultsAndModeRoundTrips() {
        var config = Config()
        #expect(config.text(forKey: "deband") == "off")
        let defaults = ["deband-strength": "0.5", "deband-threshold": "9", "deband-radius": "24",
                        "deband-iterations": "1", "deband-texture-protection": "1"]
        for (key, value) in defaults { #expect(config.text(forKey: key) == value) }
        for mode in ["off", "single", "double", "adaptive", "reference", "window"] {
            #expect(config.set("deband", mode.uppercased()) == .ok)
            #expect(config.text(forKey: "deband") == mode)
        }
        #expect(config.set("deband", "unknown") == .badValue)
        #expect(EffectFolderKeys.keys(.deband).allSatisfy { Config.scalingFolderKeys.contains($0) })
    }

    @Test func boundedParametersRejectInvalidValuesWithoutMutation() {
        let ranges: [(String, [String], [String])] = [
            ("deband-strength", ["0", "0.5", "1"], ["-0.1", "1.1", "nan", "inf"]),
            ("deband-threshold", ["0.1", "9", "32"], ["0", "32.1", "nan", "inf"]),
            ("deband-radius", ["1", "24", "64"], ["0", "65", "nan", "inf"]),
            ("deband-iterations", ["1", "2", "4"], ["0", "5", "1.5", "nan"]),
            ("deband-texture-protection", ["0", "0.5", "1"], ["-0.1", "1.1", "nan", "inf"]),
        ]
        for (key, valid, invalid) in ranges {
            var config = Config()
            for value in valid { #expect(config.set(key, value) == .ok) }
            let previous = config.text(forKey: key)
            for value in invalid {
                #expect(config.set(key, value) == .badValue)
                #expect(config.text(forKey: key) == previous)
            }
        }
    }
}

@Test func debandingSnapshotCarriesGlobalValues() {
    let (config, warnings) = Config.parse("""
        deband=window
        deband-strength=0.75
        deband-threshold=12
        deband-radius=32
        deband-iterations=3
        deband-texture-protection=0.5
        """)
    #expect(warnings.isEmpty)
    let settings = DebandSettings(config: config)
    #expect(settings == DebandSettings(mode: .window, strength: 0.75, threshold: 12,
                                      radius: 32, iterations: 3, textureProtection: 0.5))
    #expect(settings.active)
    #expect(ResampleSettings(config: config).deband == settings)
    #expect(!ResampleSettings().deband.active)
}

@Test func debandingBypassesOffZeroAndNonfiniteInputs() {
    #expect(!DebandSettings().active)
    #expect(!DebandSettings(mode: .window, strength: 0).active)
    #expect(!DebandSettings(mode: .window, strength: -.infinity).active)
    #expect(!DebandSettings(mode: .window, strength: .nan).active)
    #expect(!DebandSettings(mode: .window, threshold: .nan).active)
    #expect(!DebandSettings(mode: .window, radius: .infinity).active)
    #expect(!DebandSettings(mode: .window, textureProtection: .nan).active)
    for mode in DebandMode.allCases where mode != .off {
        #expect(DebandSettings(mode: mode).active)
    }
}
