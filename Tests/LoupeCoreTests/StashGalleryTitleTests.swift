import Testing
@testable import LoupeCore

/// `stash-title`: untitled galleries named after their file.
@Suite struct StashGalleryTitleTests {
    let zip = #"A:\Library\Travel\Summer_Trip_Lisbon_2024_Photos.zip"#

    @Test func tidiesAFileName() {
        #expect(StashGalleryTitle.display(title: "Summer_Trip_Lisbon_2024_Photos.zip", path: zip, tidy: true)
                == "Summer Trip Lisbon 2024 Photos")
        #expect(StashGalleryTitle.display(title: "My__set_v1.2", path: "/x/My__set_v1.2", tidy: true) == "My set v1.2")
    }

    @Test func keepsOwnTitlesAndFileMode() {
        #expect(StashGalleryTitle.display(title: "Real_title", path: zip, tidy: true) == "Real_title")
        #expect(StashGalleryTitle.display(title: "Summer_Trip_Lisbon_2024_Photos.zip", path: zip, tidy: false)
                == "Summer_Trip_Lisbon_2024_Photos.zip")
        #expect(StashGalleryTitle.display(title: "Gallery 4", path: nil, tidy: true) == "Gallery 4")
        #expect(StashGalleryTitle.display(title: "___.zip", path: "/x/___.zip", tidy: true) == "___.zip")
    }

    @Test func labelWithAndWithoutCount() {
        #expect(ListFolderNavigator.label(title: "A", index: 2, count: 1195) == "A · 3 / 1195")
        #expect(ListFolderNavigator.label(title: "A", index: 0, count: nil) == "A · 1")
    }
}
