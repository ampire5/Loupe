import Testing
@testable import LoupeCore

@Test func medianOdd() { var s = Samples(); [5, 1, 3].forEach { s.add($0) }; #expect(s.median == 3) }
@Test func medianEven() { var s = Samples(); [4, 1, 3, 2].forEach { s.add($0) }; #expect(s.median == 2.5) }
@Test func p90NearestRank() { var s = Samples(); (1...10).forEach { s.add(Double($0)) }; #expect(s.percentile(90) == 9) }
@Test func emptyHasNoMedian() { #expect(Samples().median == nil) }
