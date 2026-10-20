import Foundation
import HomeScreenModel
import Testing
@testable import LoupeCore

/// The final review's findings in LoupeCore, each pinned.
@Suite struct BrowserReviewTests {
    @Test func gateKeepsOnlyTheLatestPlace() {
        var gate = BrowserListingGate()
        let a = gate.begin("/a")
        #expect(gate.isCurrent(a))
        let places = gate.begin(nil)
        #expect(!gate.isCurrent(a) && gate.isCurrent(places))
        #expect(gate.path == nil)
        let b = gate.begin("/b")
        #expect(gate.isCurrent(b) && gate.path == "/b")
    }

    @Test func folderStepFollowsSort() {
        let d = URL(fileURLWithPath: "/x"), origin = URL(fileURLWithPath: "/w/1.jpg")
        let a = d.appendingPathComponent("a.jpg"), b = d.appendingPathComponent("b.jpg")
        let stamps = [a: FileStamp(modified: Date(timeIntervalSinceReferenceDate: 1), size: 1),
                      b: FileStamp(modified: Date(timeIntervalSinceReferenceDate: 2), size: 1)]
        var request = FolderRequest()
        let token = request.begin(from: origin)!
        let outcome = request.finish(token, result: .success(FolderTarget(folder: d, images: [a, b], stamps: stamps)),
                                     current: origin, sort: { _ in BrowserSort(text: "date-desc")! }) { _, _ in nil }
        guard case .enter(let list) = outcome else { Issue.record("not entered"); return }
        #expect(list.files == [b, a] && list.current == b)
    }
}
