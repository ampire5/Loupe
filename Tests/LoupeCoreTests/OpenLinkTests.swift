import Foundation
import Testing
@testable import LoupeCore

@Suite struct OpenLinkTests {
    @Test func decodesAbsoluteFileAndFolderPaths() throws {
        let file = try #require(URL(string: "loupe://open?path=%2FVolumes%2FPhoto%20Share%2F%C3%89t%C3%A9%20%26%201%25.jpg"))
        #expect(OpenLink.fileURL(for: file)?.path == "/Volumes/Photo Share/Été & 1%.jpg")
        let folder = try #require(URL(string: "loupe://open?path=%2FVolumes%2FPhoto%20Share"))
        #expect(OpenLink.fileURL(for: folder)?.path == "/Volumes/Photo Share")
        let direct = URL(fileURLWithPath: "/tmp/direct.jpg")
        #expect(OpenLink.fileURL(for: direct) == direct)
    }

    @Test(arguments: [
        "https://open?path=%2Ftmp", "loupe://browse?path=%2Ftmp", "loupe://open",
        "loupe://open?path=relative.jpg", "loupe://open?path=%2Ftmp%00.jpg",
        "loupe://open?path=%2Ftmp&path=%2Fother", "loupe://open?path=%2Ftmp#extra",
    ]) func rejectsMalformedLinks(_ link: String) throws {
        let url = try #require(URL(string: link))
        #expect(OpenLink.fileURL(for: url) == nil)
    }
}
