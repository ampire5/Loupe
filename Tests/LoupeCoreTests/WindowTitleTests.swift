import Foundation
import Testing
@testable import LoupeCore

@Suite struct WindowTitleTests {
    private let photo = URL(fileURLWithPath: "/Volumes/T/x/IMG_1.jpg")

    @Test func homeTabWinsOverThePhotoBehindIt() {
        #expect(WindowTitle.text(home: .recent, file: photo) == "Recent")
        #expect(WindowTitle.text(home: .folders, file: photo) == "Folders")
        #expect(WindowTitle.text(home: .stash, file: nil) == "Stash")
    }

    @Test func viewerShowsTheFileName() {
        #expect(WindowTitle.text(home: nil, file: photo) == "IMG_1.jpg")
        #expect(WindowTitle.text(home: nil, file: nil) == "Loupe")
    }

    @Test func restoredTabNotYetShown() {
        #expect(WindowTitle.text(of: .home(.folders)) == "Folders")
        #expect(WindowTitle.text(of: .file(path: photo.path, view: nil)) == "IMG_1.jpg")
    }
}

@Test func titleTwoNames() {
    let a = URL(fileURLWithPath: "/x/a.jpg"), b = URL(fileURLWithPath: "/x/b.jpg")
    #expect(WindowTitle.text(home: nil, file: a, companion: b) == "a.jpg · b.jpg")
    #expect(WindowTitle.text(home: .recent, file: a, companion: b) == "Recent")
    #expect(WindowTitle.text(home: nil, file: a, companion: nil) == "a.jpg")
}
