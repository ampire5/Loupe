import Testing
import Foundation
@testable import LoupeCore

private final class CountingReader: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [URL] = []
    func read(_ url: URL) -> PhotoMetadata {
        lock.lock(); reads.append(url); lock.unlock()
        var m = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        m.camera = url.lastPathComponent
        return m
    }
    func count(_ url: URL? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        return url.map { u in reads.filter { $0 == u }.count } ?? reads.count
    }
}

private func file(_ i: Int) -> URL { URL(fileURLWithPath: "/tmp/photos/\(i).jpg") }

@Test func cacheReadsOncePerPathSizeAndDate() async {
    let counter = CountingReader()
    let cache = PhotoMetadataCache(reader: { counter.read($0) })
    let date = Date(timeIntervalSince1970: 1_000)
    let a = await cache.metadata(for: file(1), size: 10, modified: date)
    let b = await cache.metadata(for: file(1), size: 10, modified: date)
    #expect(a == b && a.camera == "1.jpg")
    #expect(counter.count() == 1)
    // A changed date, a changed size and another file are other entries.
    _ = await cache.metadata(for: file(1), size: 10, modified: date.addingTimeInterval(1))
    _ = await cache.metadata(for: file(1), size: 11, modified: date)
    _ = await cache.metadata(for: file(2), size: 10, modified: date)
    #expect(counter.count() == 4)
    _ = await cache.metadata(for: file(1), size: 10, modified: nil)
    _ = await cache.metadata(for: file(1), size: 10, modified: nil)
    #expect(counter.count() == 5)
}

@Test func cacheEvictsTheLeastRecentlyUsedBeyondCapacity() async {
    let counter = CountingReader()
    let cache = PhotoMetadataCache(reader: { counter.read($0) })
    for i in 1...64 { _ = await cache.metadata(for: file(i), size: 1, modified: nil) }
    #expect(counter.count() == 64)
    _ = await cache.metadata(for: file(1), size: 1, modified: nil)      // touch the oldest: now 2 is the oldest
    #expect(counter.count() == 64)
    _ = await cache.metadata(for: file(65), size: 1, modified: nil)     // the 65th entry
    #expect(counter.count() == 65)
    _ = await cache.metadata(for: file(1), size: 1, modified: nil)
    #expect(counter.count() == 65)                                      // 1 survived
    _ = await cache.metadata(for: file(2), size: 1, modified: nil)
    #expect(counter.count(file(2)) == 2)                                // 2 was evicted
}

@Test func cacheJoinsConcurrentReadsOfOneFile() async {
    let counter = CountingReader()
    let cache = PhotoMetadataCache(reader: { url in
        Thread.sleep(forTimeInterval: 0.1)
        return counter.read(url)
    })
    async let a = cache.metadata(for: file(1), size: 1, modified: nil)
    async let b = cache.metadata(for: file(1), size: 1, modified: nil)
    _ = await (a, b)
    #expect(counter.count() == 1)
}

@Test func cacheDoesNotKeepAFailedRead() async {
    // A share hiccup: the first read fails, the next one succeeds and is what gets cached.
    final class Flaky: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        func read(_ url: URL) -> PhotoMetadata {
            lock.lock(); reads += 1; let n = reads; lock.unlock()
            var m = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
            if n == 1 { m.error = "Not a readable image file" } else { m.camera = url.lastPathComponent }
            return m
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    }
    let flaky = Flaky()
    let cache = PhotoMetadataCache(reader: { flaky.read($0) })
    let first = await cache.metadata(for: file(1), size: 5, modified: nil)
    #expect(first.error != nil)
    let second = await cache.metadata(for: file(1), size: 5, modified: nil)
    #expect(second.error == nil && second.camera == "1.jpg")
    #expect(flaky.count == 2)
    _ = await cache.metadata(for: file(1), size: 5, modified: nil)
    #expect(flaky.count == 2)                                   // the good result is kept
}
