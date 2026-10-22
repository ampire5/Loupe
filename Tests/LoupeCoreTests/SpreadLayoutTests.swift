import CoreGraphics
import Testing
@testable import LoupeCore

@Test func equalHeights() {
    let l = SpreadLayout(first: CGSize(width: 1000, height: 1500), second: CGSize(width: 500, height: 750), rightToLeft: false)
    #expect(l.virtualSize == CGSize(width: 2000, height: 1500))
    #expect(l.rects == [CGRect(x: 0, y: 0, width: 1000, height: 1500), CGRect(x: 1000, y: 0, width: 1000, height: 1500)])
    #expect(l.order == [0, 1])
}

@Test func rightToLeftSwapsSides() {
    let l = SpreadLayout(first: CGSize(width: 1000, height: 1500), second: CGSize(width: 500, height: 750), rightToLeft: true)
    #expect(l.order == [1, 0])
    #expect(l.rects.map(\.minX) == [0, 1000])
    #expect(l.virtualSize == CGSize(width: 2000, height: 1500))
}

@Test func singlePageLayout() {
    let l = SpreadLayout(first: CGSize(width: 800, height: 1200), second: nil, rightToLeft: true)
    #expect(l.virtualSize == CGSize(width: 800, height: 1200))
    #expect(l.rects == [CGRect(x: 0, y: 0, width: 800, height: 1200)])
    #expect(l.order == [0])
}

@Test func pageUnderPoint() {
    let first = CGSize(width: 1000, height: 1500), second = CGSize(width: 500, height: 750)
    let ltr = SpreadLayout(first: first, second: second, rightToLeft: false)
    #expect(ltr.page(at: CGPoint(x: 10, y: 10)) == 0)
    #expect(ltr.page(at: CGPoint(x: 1500, y: 10)) == 1)
    #expect(ltr.page(at: CGPoint(x: 2500, y: 10)) == nil)
    let rtl = SpreadLayout(first: first, second: second, rightToLeft: true)
    #expect(rtl.page(at: CGPoint(x: 10, y: 10)) == 1)
    #expect(rtl.page(at: CGPoint(x: 1500, y: 10)) == 0)
}

@Test func narrowViewShowsOnePage() {
    #expect(!SpreadLayout.showsTwo(viewSize: CGSize(width: 800, height: 1000)))
    #expect(SpreadLayout.showsTwo(viewSize: CGSize(width: 1000, height: 800)))
    #expect(SpreadLayout.showsTwo(viewSize: CGSize(width: 1000, height: 1000)))
}

@Test func zeroSizePagesStayFinite() {
    func finite(_ l: SpreadLayout) -> Bool {
        let v = [l.virtualSize.width, l.virtualSize.height] + l.rects.flatMap { [$0.minX, $0.minY, $0.width, $0.height] }
        return v.allSatisfy { $0.isFinite }
    }
    #expect(finite(SpreadLayout(first: .zero, second: .zero, rightToLeft: false)))
    #expect(finite(SpreadLayout(first: CGSize(width: 800, height: 0), second: CGSize(width: 500, height: 750), rightToLeft: true)))
    #expect(finite(SpreadLayout(first: CGSize(width: 500, height: 750), second: CGSize(width: 800, height: 0), rightToLeft: false)))
}
