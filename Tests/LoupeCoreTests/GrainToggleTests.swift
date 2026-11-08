import Foundation
import Testing
@testable import LoupeCore

@Test func grainToggleRestoresChosenStyleAfterPreferencesReopen() throws {
    let suite = "LoupeTests.GrainToggle.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    var config = Config()
    config.grainStage = .after
    config.grain = .particles
    config.grainAmount = 1.2
    config.grainSize = 2.5
    GrainToggle.remember(config.grain, preferences: preferences)
    GrainToggle.toggle(&config, preferences: preferences)
    #expect(config.grain == .off)
    GrainToggle.remember(.off, preferences: preferences)
    let reopened = try #require(UserDefaults(suiteName: suite))
    GrainToggle.toggle(&config, preferences: reopened)
    #expect(config.grain == .particles)
    #expect(config.grainStage == .after)
    #expect(config.grainAmount == 1.2)
    #expect(config.grainSize == 2.5)
}

@Test func grainToggleUsesFineWithoutValidRememberedStyle() throws {
    let suite = "LoupeTests.GrainToggle.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    for stored in [nil, "off", "unknown"] as [String?] {
        preferences.set(stored, forKey: GrainToggle.lastStyleKey)
        var config = Config()
        GrainToggle.toggle(&config, preferences: preferences)
        #expect(config.grain == .fine)
    }
}

@Test func grainToggleRemembersLatestNonOffSelection() throws {
    let suite = "LoupeTests.GrainToggle.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    for style in GrainStyle.allCases where style != .off {
        GrainToggle.remember(style, preferences: preferences)
        GrainToggle.remember(.off, preferences: preferences)
        var config = Config()
        GrainToggle.toggle(&config, preferences: preferences)
        #expect(config.grain == style)
        GrainToggle.toggle(&config, preferences: preferences)
        #expect(config.grain == .off)
    }
}
