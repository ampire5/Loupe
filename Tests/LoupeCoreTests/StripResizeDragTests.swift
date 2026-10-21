import Foundation
import Testing
@testable import LoupeCore

@Suite struct StripResizeDragTests {
    /// The grabbed top is the band's top: the height follows the cursor 1:1, back to the press point is back to the
    /// start height; past the range it goes on 1:1 (the caller clamps it).
    @Test func heightFollowsTheCursorOneToOne() {
        let drag = StripResizeDrag(startHeight: 68)
        #expect(drag.startHeight == 68)
        for d in stride(from: -200.0, through: 200, by: 7) { #expect(drag.height(forDrag: d) == 68 + d) }
        #expect(drag.height(forDrag: 0) == 68)
    }
}
