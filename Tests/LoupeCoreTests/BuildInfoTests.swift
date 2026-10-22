import Testing
@testable import LoupeCore

@Suite struct BuildInfoTests {
    private let stamped: [String: Any] = [
        "CFBundleShortVersionString": "0.1", "LoupeBuildCommit": "cb8586f+dirty", "LoupeBuildBranch": "night-lts",
        "LoupeBuildDate": "2026-10-22 14:05 +0300", "LoupeBuildLabel": "L7",
    ]

    @Test func stampedBuildNamesItself() {
        let info = BuildInfo(info: stamped)
        #expect(info.version == "0.1")
        #expect(info.line == "cb8586f+dirty · night-lts · 2026-10-22 14:05 +0300")
        #expect(info.short == "L7")
        #expect(info.credits == "Build L7\ncb8586f+dirty · night-lts · 2026-10-22 14:05 +0300")
    }

    @Test func noLabelShowsTheCommit() {
        var dict = stamped
        dict["LoupeBuildLabel"] = ""
        let info = BuildInfo(info: dict)
        #expect(info.label == nil)
        #expect(info.short == "cb8586f+dirty")
        #expect(info.credits == "cb8586f+dirty · night-lts · 2026-10-22 14:05 +0300")
    }

    @Test func unstampedBuildIsUnknown() {
        let info = BuildInfo(info: [:])
        #expect(info.version == "unknown")
        #expect(info.line == "unknown · unknown · unknown")
        #expect(info.short == "unknown")
    }
}
