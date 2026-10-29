import Foundation
import Testing
@testable import LoupeCore

struct FolderStripStateTests {
    let a = FolderStripID.folder(URL(fileURLWithPath: "/A"))
    let b = FolderStripID.folder(URL(fileURLWithPath: "/B"))
    @Test func browseDoesNotCommitAndSettleRequestsOnlyLatest() {
        var state = FolderStripState()
        state.synchronize(a)
        _ = state.browse(b)
        #expect(state.opened == a)
        #expect(state.browsed == b)
        let settled = state.settle(); #expect(settled == b)
        let repeated = state.settle(); #expect(repeated == nil)
    }
    @Test func lateAAfterBIsIgnored() {
        var state = FolderStripState()
        let old = state.browse(a)
        _ = state.settle()
        let new = state.browse(b)
        _ = state.settle()
        let stale = state.acceptOpened(a, generation: old); #expect(!stale)
        let accepted = state.acceptOpened(b, generation: new); #expect(accepted)
        #expect(state.opened == b)
    }
    @Test func cancelInvalidatesPendingAndRestoresOpened() {
        var state = FolderStripState(); state.synchronize(a)
        let token = state.browse(b); _ = state.settle()
        state.cancel()
        #expect(state.browsed == a)
        let stale = state.acceptOpened(b, generation: token); #expect(!stale)
    }
    @Test func externalOpenDoesNotRequestOpen() {
        var state = FolderStripState(); _ = state.browse(a)
        state.synchronize(b)
        let settled = state.settle(); #expect(settled == nil)
        #expect(state.opened == b && state.browsed == b)
    }
    @Test func clickInvalidatesOldInertiaRequest() {
        var state = FolderStripState(); let old = state.browse(a); _ = state.settle()
        let click = state.browse(b); let settled = state.settle(); #expect(settled == b)
        let stale = state.acceptOpened(a, generation: old); #expect(!stale)
        let accepted = state.acceptOpened(b, generation: click); #expect(accepted)
    }
}
