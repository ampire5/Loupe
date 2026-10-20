import Foundation
import Testing
@testable import LoupeCore

@Suite struct CopyPathTests {
    @Test func aFileIsItsPath() {
        #expect(ArchivePath.copyText(URL(fileURLWithPath: "/Volumes/Media/a b/1.jpg")) == "/Volumes/Media/a b/1.jpg")
    }

    @Test func anArchiveEntryIsTheArchiveAndItsInnerPath() {
        let url = ArchivePath.url(archive: URL(fileURLWithPath: "/v/set.zip"), entry: "sub/2.jpg")!
        #expect(ArchivePath.copyText(url) == "/v/set.zip/sub/2.jpg")
    }
}

@Suite struct HomeBackTests {
    @Test func aPhotoOpenedFromOutsideGoesBackToRecent() {
        #expect(HomeBack.target(returnsTo: nil, showingHome: false, hasPhoto: true, stashAvailable: false) == .recent)
    }

    @Test func theTabItWasOpenedFromWins() {
        #expect(HomeBack.target(returnsTo: .stash, showingHome: false, hasPhoto: true, stashAvailable: true) == .stash)
        #expect(HomeBack.target(returnsTo: .recent, showingHome: false, hasPhoto: true, stashAvailable: true) == .recent)
    }

    @Test func backToFolders() {
        #expect(HomeBack.target(returnsTo: .folders, showingHome: false, hasPhoto: true, stashAvailable: false) == .folders)
    }

    @Test func stashGoneFallsBackToRecent() {
        #expect(HomeBack.target(returnsTo: .stash, showingHome: false, hasPhoto: true, stashAvailable: false) == .recent)
    }

    @Test func nothingWhileOnHomeOrWithNoPhoto() {
        #expect(HomeBack.target(returnsTo: .recent, showingHome: true, hasPhoto: true, stashAvailable: true) == nil)
        #expect(HomeBack.target(returnsTo: nil, showingHome: false, hasPhoto: false, stashAvailable: true) == nil)
    }
}

@Test func backToFoldersShowsThePhotosFolder() {
    #expect(HomeBack.showsCurrentPhoto(.folders))
    #expect(!HomeBack.showsCurrentPhoto(.recent) && !HomeBack.showsCurrentPhoto(.stash))
}

/// The ‹ button shows only as the pointer comes near it (a reveal zone with hysteresis): in within 80 pt of it, out
/// beyond 120 pt, so it does not flicker on the edge; the strip and other movement do not show it.
@Test func backButtonRevealsNearTheCorner() {
    let button = CGRect(x: 16, y: 16, width: 100, height: 32)
    func next(_ shown: Bool, _ x: CGFloat, _ y: CGFloat, canGoBack: Bool = true) -> Bool {
        BackButtonPolicy.isShown(wasShown: shown, pointer: CGPoint(x: x, y: y), button: button, canGoBack: canGoBack)
    }
    #expect(next(false, 60, 30))            // on it
    #expect(next(false, 180, 30))           // 64 pt right of it
    #expect(!next(false, 230, 30))          // 114 pt: not yet
    #expect(next(true, 230, 30))            // but kept once shown
    #expect(!next(true, 250, 30))           // 134 pt: gone
    #expect(!next(true, 60, 30, canGoBack: false))
    #expect(!BackButtonPolicy.isShown(wasShown: true, pointer: nil, button: button, canGoBack: true))   // left the window
}
