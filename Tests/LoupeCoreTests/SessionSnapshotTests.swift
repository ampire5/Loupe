import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

@Suite struct SessionSnapshotTests {
    static let sample = SessionSnapshot(windows: [
        .init(frame: CGRect(x: 10, y: 20, width: 800, height: 600), screen: "Studio Display", fullScreen: true,
              selected: 1, tabs: [
                .file(path: "/p/a/1.jpg", view: "fit"),
                .gallery(id: "7", list: Data(#"{"page":2}"#.utf8), index: 27, count: 812, file: "x\u{2215}3.jpg",
                         view: nil),
                .home(.stash),
              ]),
        .init(frame: CGRect(x: 0, y: 0, width: 400, height: 300), screen: nil, fullScreen: false, selected: 0,
              tabs: [.home(.recent)]),
    ])

    @Test func roundTrip() {
        #expect(SessionSnapshot.decode(Self.sample.encoded()) == Self.sample)
        #expect(Self.sample.tabCount == 4)
        #expect(!Self.sample.isOnlyHome)
    }

    @Test func onlyHome() {
        let s = SessionSnapshot(windows: [.init(frame: .zero, screen: nil, fullScreen: false, selected: 0,
                                                tabs: [.home(.recent), .home(.stash)])])
        #expect(s.isOnlyHome)
        #expect(SessionSnapshot(windows: []).isOnlyHome)
    }

    @Test func homeKeepsWhatIsUnderIt() {
        let photo = SessionSnapshot.Tab.file(path: "/p/a/1.jpg", view: "fit")
        #expect(SessionSnapshot.Tab.homeKeeping(.recent, folder: nil, under: nil) == .home(.recent))
        let over = SessionSnapshot.Tab.homeKeeping(.folders, folder: "/p/b", under: photo)
        #expect(over == .homeOver(.folders, folder: "/p/b", under: photo))
        let s = SessionSnapshot(windows: [.init(frame: .zero, screen: nil, fullScreen: false, selected: 0,
                                                tabs: [over, .homeKeeping(.recent, folder: "/p/c", under: nil)])])
        #expect(SessionSnapshot.decode(s.encoded()) == s)
        #expect(!s.isOnlyHome)
        #expect(WindowTitle.text(of: over) == "Folders")
    }

    @Test func homeOfAnEarlierLoupeDecodes() {
        let json = #"{"v":1,"windows":[{"frame":[[0,0],[10,10]],"fullScreen":false,"selected":0,"tabs":[{"home":{"_0":"recent"}}]}]}"#
        #expect(SessionSnapshot.decode(Data(json.utf8))?.windows.first?.tabs == [.home(.recent)])
    }

    @Test func newerVersionOrGarbageIsNil() {
        var newer = Self.sample
        newer.v = 2
        #expect(SessionSnapshot.decode(newer.encoded()) == nil)
        #expect(SessionSnapshot.decode(Data("not json".utf8)) == nil)
    }

    @Test func frameOnAScreenStays() {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 2560, height: 1440)]
        let f = CGRect(x: 2000, y: 100, width: 800, height: 600)
        #expect(SessionFrames.fit(f, screens: screens, main: screens[0]) == f)
    }

    @Test func frameOffScreenGoesToMainCentred() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let f = CGRect(x: 5000, y: 100, width: 800, height: 600)
        #expect(SessionFrames.fit(f, screens: [main], main: main) == CGRect(x: 560, y: 240, width: 800, height: 600))
        let big = CGRect(x: 5000, y: 0, width: 3000, height: 2000)
        #expect(SessionFrames.fit(big, screens: [main], main: main) == main)
    }
}
