import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

@Suite struct SessionRestorePlanTests {
    private func window(_ tabs: [SessionSnapshot.Tab], selected: Int) -> SessionSnapshot.Window {
        .init(frame: CGRect(x: 0, y: 0, width: 800, height: 600), screen: nil, fullScreen: false, selected: selected,
              tabs: tabs)
    }

    /// Two windows of three tabs: only the selected tab of each opens at once.
    @Test func selectedOpenOthersLazy() {
        let a: SessionSnapshot.Tab = .file(path: "/a/1.jpg", view: nil)
        let b: SessionSnapshot.Tab = .file(path: "/b/1.jpg", view: "fit")
        let g: SessionSnapshot.Tab = .gallery(id: "7", list: nil, index: nil, count: nil, file: nil, view: nil)
        let s = SessionSnapshot(windows: [window([a, b, g], selected: 1), window([g, .home(.stash), a], selected: 0)])
        let steps = SessionRestorePlan.steps(s) { _ in true }
        #expect(steps.map(\.tabs) == [[.lazy(a), .open(b), .lazy(g)], [.open(g), .home(.stash, notAvailable: nil, keeps: nil), .lazy(a)]])
        #expect(steps.map(\.selected) == [1, 0])
    }

    /// Review Focus 4 (plan side): a file that is gone puts its tab on Home with its name for the toast; the others open
    /// as saved; a gallery is always tried (Stash resolves it); an unknown answer (a slow share) is tried too.
    @Test func missingFileTabFallsBackToHome() {
        let gone: SessionSnapshot.Tab = .file(path: "/a/Gone.jpg", view: nil)
        let here: SessionSnapshot.Tab = .file(path: "/a/1.jpg", view: nil)
        let slow: SessionSnapshot.Tab = .file(path: "/smb/2.jpg", view: nil)
        let g: SessionSnapshot.Tab = .gallery(id: "7", list: nil, index: nil, count: nil, file: nil, view: nil)
        let s = SessionSnapshot(windows: [window([gone, here, slow, g], selected: 0)])
        let steps = SessionRestorePlan.steps(s) { path in
            path == "/a/Gone.jpg" ? false : path == "/smb/2.jpg" ? nil : true
        }
        #expect(steps[0].tabs == [.home(.recent, notAvailable: "Gone.jpg", keeps: gone), .lazy(here), .lazy(slow), .lazy(g)])
    }

    @Test func selectedOutOfRangeIsClamped() {
        let a: SessionSnapshot.Tab = .file(path: "/a/1.jpg", view: nil)
        let steps = SessionRestorePlan.steps(SessionSnapshot(windows: [window([a], selected: 5)])) { _ in true }
        #expect(steps[0].selected == 0 && steps[0].tabs == [.open(a)])
    }
}
