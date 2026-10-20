import Testing
import Foundation
@testable import LoupeCore

@Suite struct ThumbnailQueueTests {
    private func files(_ prefix: String, _ count: Int) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/photos/\(prefix)\($0).jpg") }
    }

    private func names(_ urls: [URL]) -> [String] {
        urls.map { $0.deletingPathExtension().lastPathComponent }
    }

    @Test func keyWindowVisibleFirst() {
        let f = files("a", 10)
        let request = ThumbnailRequest(files: f, current: 4, visible: [0, 2, 4, 6, 8], isKey: true)
        let order = names(ThumbnailQueue.order([request], skip: []))
        #expect(Array(order.prefix(5)) == ["a0", "a2", "a4", "a6", "a8"])
        // The rest follows outward from the current photo, without repeating the visible ones.
        #expect(Array(order.dropFirst(5)) == ["a5", "a3", "a7", "a1", "a9"])
    }

    @Test func outwardAlternates() {
        let f = files("a", 10)
        let request = ThumbnailRequest(files: f, current: 4, visible: [], isKey: true)
        #expect(names(ThumbnailQueue.order([request], skip: []))
                == ["a4", "a5", "a3", "a6", "a2", "a7", "a1", "a8", "a0", "a9"])
    }

    @Test func outwardRunsPastTheNearerEnd() {
        let f = files("a", 6)
        let request = ThumbnailRequest(files: f, current: 1, visible: [], isKey: true)
        #expect(names(ThumbnailQueue.order([request], skip: [])) == ["a1", "a2", "a0", "a3", "a4", "a5"])
    }

    @Test func otherWindowsAfterKey() {
        let a = files("a", 4), b = files("b", 4), c = files("c", 4)
        // The key window is not first in the list: it still goes first.
        let requests = [
            ThumbnailRequest(files: b, current: 0, visible: [0, 1], isKey: false),
            ThumbnailRequest(files: a, current: 2, visible: [2, 3], isKey: true),
            ThumbnailRequest(files: c, current: 3, visible: [3], isKey: false),
        ]
        #expect(names(ThumbnailQueue.order(requests, skip: []))
                == ["a2", "a3", "a1", "a0",
                    "b0", "b1", "c3",
                    "b2", "b3", "c2", "c1", "c0"])
    }

    @Test func nonKeyByRecency() {
        let a = files("a", 1), b = files("b", 1), c = files("c", 1), d = files("d", 1)
        // The windows key more recently come first among the others, whatever order they are given in.
        let requests = [
            ThumbnailRequest(files: b, current: 0, visible: [], isKey: false, lastActive: 1),
            ThumbnailRequest(files: c, current: 0, visible: [], isKey: false, lastActive: 5),
            ThumbnailRequest(files: a, current: 0, visible: [], isKey: true, lastActive: 6),
            ThumbnailRequest(files: d, current: 0, visible: [], isKey: false, lastActive: 3),
        ]
        #expect(names(ThumbnailQueue.order(requests, skip: [])) == ["a0", "c0", "d0", "b0"])
    }

    @Test func equalRecencyKeepsOrder() {
        let a = files("a", 1), b = files("b", 1), c = files("c", 1)
        let requests = [
            ThumbnailRequest(files: b, current: 0, visible: [], isKey: false, lastActive: 2),
            ThumbnailRequest(files: c, current: 0, visible: [], isKey: false, lastActive: 2),
            ThumbnailRequest(files: a, current: 0, visible: [], isKey: false, lastActive: 2),
        ]
        #expect(names(ThumbnailQueue.order(requests, skip: [])) == ["b0", "c0", "a0"])
    }

    @Test func duplicatesAcrossWindowsOnce() {
        let shared = files("s", 4)
        let requests = [
            ThumbnailRequest(files: shared, current: 0, visible: [0], isKey: true),
            ThumbnailRequest(files: shared, current: 3, visible: [3], isKey: false),
        ]
        #expect(names(ThumbnailQueue.order(requests, skip: [])) == ["s0", "s1", "s2", "s3"])
    }

    @Test func skipRemoved() {
        let f = files("a", 5)
        let request = ThumbnailRequest(files: f, current: 2, visible: [1, 2], isKey: true)
        let order = ThumbnailQueue.order([request], skip: [f[2], f[0]])
        #expect(names(order) == ["a1", "a3", "a4"])
    }

    @Test func emptyRequests() {
        #expect(ThumbnailQueue.order([], skip: []).isEmpty)
        #expect(ThumbnailQueue.order([ThumbnailRequest(files: [], current: 0, visible: [], isKey: true)],
                                     skip: []).isEmpty)
    }

    @Test func outOfRangeIndicesAreIgnored() {
        let f = files("a", 3)
        let outside = ThumbnailRequest(files: f, current: 7, visible: [-1, 2, 9, 0], isKey: true)
        #expect(names(ThumbnailQueue.order([outside], skip: [])) == ["a2", "a0"])
        let negative = ThumbnailRequest(files: f, current: -1, visible: [1], isKey: true)
        #expect(names(ThumbnailQueue.order([negative], skip: [])) == ["a1"])
    }

    @Test func largeFolderIsFast() {
        let requests = (0..<4).map {
            ThumbnailRequest(files: files("w\($0)_", 20_000), current: 10_000, visible: Array(0..<30), isKey: $0 == 0)
        }
        let start = ContinuousClock.now
        let order = ThumbnailQueue.order(requests, skip: [])
        #expect(order.count == 80_000)
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
