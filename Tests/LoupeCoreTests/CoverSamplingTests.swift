import Testing
@testable import LoupeCore

private func photos(_ n: Int) -> [String] { (0..<n).map { "p\($0).jpg" } }

@Test func evenlySpread() {
    #expect(CoverSampling.pick(photos(10), lastViewed: nil) == ["p0.jpg", "p3.jpg", "p6.jpg", "p9.jpg"])
}

@Test func fewerThanFour() {
    #expect(CoverSampling.pick(photos(2), lastViewed: nil) == ["p0.jpg", "p1.jpg"])
}

@Test func lastViewedFirst() {
    let picked = CoverSampling.pick(photos(10), lastViewed: "p6.jpg")
    #expect(picked.first == "p6.jpg")
    #expect(picked.count == 4)
    #expect(Set(picked).count == 4)
    #expect(CoverSampling.pick(photos(10), lastViewed: "p4.jpg").first == "p4.jpg")
}

@Test func noPhotosUsesSubfolders() {
    let dirs = (0..<6).map { "d\($0)" }
    #expect(CoverSampling.plan(names: ["a.mov", "b.txt"], directories: dirs, lastViewed: nil)
        == .subfolders(["d0", "d1", "d2", "d3"]))
}

@Test func noPhotosIsEmpty() {
    #expect(CoverSampling.plan(names: ["a.mov", "b.txt"], directories: [], lastViewed: nil) == .empty)
}

@Test func photosPlan() {
    #expect(CoverSampling.plan(names: ["a.JPG", "b.txt", "c.png"], directories: ["d"], lastViewed: nil)
        == .photos(["a.JPG", "c.png"]))
}

@Test func archiveEntriesAnyDepth() {
    let names = ["a/b/c/1.jpg", "a/2.PNG", "readme.txt", "x/y/3.heic", "x/4.webp", "x/y/z/5.gif"]
    let plan = CoverSampling.plan(names: names, directories: [], lastViewed: nil)
    // 5 photos: indexes 0, round(4/3)=1, round(8/3)=3, 4
    #expect(plan == .photos(["a/b/c/1.jpg", "a/2.PNG", "x/4.webp", "x/y/z/5.gif"]))
}
