import Foundation
import Testing
@testable import LoupeCore

/// Paths through an archive (Stash spec §2.4): `<archive>/<inner path with ∕ for />`.
@Suite struct ArchivePathTests {
    @Test func splitsAnEntry() throws {
        let s = try #require(ArchivePath.split(URL(fileURLWithPath: "/v/G.zip/caps\u{2215}01.jpg")))
        #expect(s.archive.path == "/v/G.zip" && s.entry == "caps/01.jpg")
    }

    @Test func plainFileIsNotAnEntry() {
        #expect(ArchivePath.split(URL(fileURLWithPath: "/v/caps/01.jpg")) == nil)
    }

    @Test func zipItselfIsNotAnEntry() {
        #expect(ArchivePath.split(URL(fileURLWithPath: "/v/G.zip")) == nil)
        #expect(ArchivePath.isArchive(URL(fileURLWithPath: "/v/G.zip")))
        #expect(!ArchivePath.isArchive(URL(fileURLWithPath: "/v/G.jpg")))
    }

    @Test func extensionIsCaseInsensitive() {
        #expect(ArchivePath.split(URL(fileURLWithPath: "/v/G.ZIP/01.jpg"))?.entry == "01.jpg")
    }

    @Test func urlRoundTrips() throws {
        let archive = URL(fileURLWithPath: "/v/G.zip")
        let url = try #require(ArchivePath.url(archive: archive, entry: "caps/sub/01.jpg"))
        #expect(url.lastPathComponent == "caps\u{2215}sub\u{2215}01.jpg" && url.deletingLastPathComponent().path == "/v/G.zip")
        #expect(ArchivePath.split(url)?.entry == "caps/sub/01.jpg")
    }

    @Test func nameWithDivisionSlashIsRefused() {
        #expect(ArchivePath.url(archive: URL(fileURLWithPath: "/v/G.zip"), entry: "a\u{2215}b.jpg") == nil)
    }

    @Test func displayName() {
        #expect(ArchivePath.displayName(URL(fileURLWithPath: "/v/G.zip/caps\u{2215}01.jpg")) == "G.zip › caps/01.jpg")
        #expect(ArchivePath.displayName(URL(fileURLWithPath: "/v/a/01.jpg")) == "01.jpg")
    }
}
