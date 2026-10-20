import Testing
import Foundation
@testable import LoupeCore

private func entry(_ name: String, in parent: URL, directory: Bool = true, package: Bool = false) -> DirectoryEntry {
    DirectoryEntry(url: parent.appendingPathComponent(name), isDirectory: directory, isPackage: package)
}

private let parent = URL(fileURLWithPath: "/photos")

@Test func siblingsAreNaturallySorted() {
    let s = FolderSiblings(entries: ["10", "2", "b", "A", "1"].map { entry($0, in: parent) })
    #expect(s.folders.map(\.lastPathComponent) == ["1", "2", "10", "A", "b"])
}

@Test func hiddenPackagesAndFilesAreSkipped() {
    let s = FolderSiblings(entries: [
        entry("a", in: parent), entry(".hidden", in: parent), entry("Some.app", in: parent, package: true),
        entry("notes.txt", in: parent, directory: false), entry("b", in: parent),
    ])
    #expect(s.folders.map(\.lastPathComponent) == ["a", "b"])
}

@Test func candidatesAreNearestFirstAndStopAtEnds() {
    let s = FolderSiblings(entries: ["1", "2", "3", "4"].map { entry($0, in: parent) })
    let two = parent.appendingPathComponent("2")
    #expect(s.candidates(from: two, step: 1).map(\.lastPathComponent) == ["3", "4"])
    #expect(s.candidates(from: two, step: -1).map(\.lastPathComponent) == ["1"])
    #expect(s.candidates(from: parent.appendingPathComponent("4"), step: 1).isEmpty)
    #expect(s.candidates(from: parent.appendingPathComponent("1"), step: -1).isEmpty)
}

@Test func candidatesFromAFolderNotListedUseItsNaturalPlace() {   // e.g. the current folder is hidden
    let s = FolderSiblings(entries: ["1", "3", "10"].map { entry($0, in: parent) })
    let two = parent.appendingPathComponent("2")
    #expect(s.candidates(from: two, step: 1).map(\.lastPathComponent) == ["3", "10"])
    #expect(s.candidates(from: two, step: -1).map(\.lastPathComponent) == ["1"])
}

// MARK: FolderNavigator (real temp directories)

private func makeTree(_ layout: [String: [String]]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-siblings-\(UUID().uuidString)")
    for (folder, files) in layout {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { try Data([0]).write(to: dir.appendingPathComponent(f)) }
    }
    return root.standardizedFileURL.resolvingSymlinksInPath()
}

@Test func navigatorSkipsEmptyFoldersAndReturnsTheImages() async throws {
    let root = try makeTree(["1": ["a.jpg"], "2": ["notes.txt"], "3": [], "10": ["z.PNG", "y.heic", "n.txt"], ".hid": ["h.jpg"]])
    defer { try? FileManager.default.removeItem(at: root) }
    let nav = FolderNavigator()
    let next = try await nav.neighbour(of: root.appendingPathComponent("1"), step: 1)
    #expect(next?.folder == root.appendingPathComponent("10"))
    #expect(Set(next?.images.map(\.lastPathComponent) ?? []) == ["z.PNG", "y.heic"])
    let back = try await nav.neighbour(of: root.appendingPathComponent("10"), step: -1)
    #expect(back?.folder == root.appendingPathComponent("1"))
}

@Test func navigatorReturnsNilAtTheEnds() async throws {
    let root = try makeTree(["1": ["a.jpg"], "2": ["b.jpg"]])
    defer { try? FileManager.default.removeItem(at: root) }
    let nav = FolderNavigator()
    #expect(try await nav.neighbour(of: root.appendingPathComponent("2"), step: 1) == nil)
    #expect(try await nav.neighbour(of: root.appendingPathComponent("1"), step: -1) == nil)
}

@Test func navigatorSkipsPackages() async throws {
    let root = try makeTree(["1": ["a.jpg"], "Thing.app": ["b.jpg"], "3": ["c.jpg"]])
    defer { try? FileManager.default.removeItem(at: root) }
    // ".app" directories are packages for LaunchServices even without an Info.plist.
    let next = try await FolderNavigator().neighbour(of: root.appendingPathComponent("1"), step: 1)
    #expect(next?.folder == root.appendingPathComponent("3"))
}

@Test func navigatorFailsWhenTheParentCannotBeListed() async {
    let nav = FolderNavigator()
    await #expect(throws: FolderNavigationError.unreadable) {
        _ = try await nav.neighbour(of: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x"), step: 1)
    }
}

@Test func navigatorTimesOutOnAHungListing() async {
    let nav = FolderNavigator(timeout: .milliseconds(100)) { _ in
        Thread.sleep(forTimeInterval: 1)
        return []
    }
    await #expect(throws: FolderNavigationError.timedOut) {
        _ = try await nav.neighbour(of: URL(fileURLWithPath: "/p/x"), step: 1)
    }
}

/// The timing half of the above. It is taken on the timer's own thread: an `await` here would also wait for
/// a free Swift-concurrency pool thread, which other tests' blocking work can hold for a second or more.
@Test func blockingCallGivesUpAtTheTimeoutNotWhenTheWorkEnds() {
    let done = DispatchSemaphore(value: 0)
    let outcome = Box<(Result<Int, Error>, ContinuousClock.Instant)?>(nil)
    let start = ContinuousClock.now
    BlockingCall.start(timeout: .milliseconds(100), { () -> Int in
        Thread.sleep(forTimeInterval: 1)
        return 1
    }, completion: { result in
        outcome.set((result, ContinuousClock.now))
        done.signal()
    })
    #expect(done.wait(timeout: .now() + 5) == .success)
    guard let (result, at) = outcome.get() else { return }
    #expect(throws: FolderNavigationError.timedOut) { try result.get() }
    #expect(at - start < .milliseconds(800))
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.withLock { value = new } }
    func get() -> T { lock.withLock { value } }
}

@Test func navigatorCachesTheParentListing() async throws {
    let root = try makeTree(["1": ["a.jpg"], "2": ["b.jpg"]])
    defer { try? FileManager.default.removeItem(at: root) }
    let calls = Counter()
    let nav = FolderNavigator { url in
        calls.increment(url)
        return try FolderSiblings.listEntries(url)
    }
    _ = try await nav.neighbour(of: root.appendingPathComponent("1"), step: 1)
    _ = try await nav.neighbour(of: root.appendingPathComponent("2"), step: -1)
    #expect(calls.count(of: root) == 1)
}

@Test func hungCandidateIsSkippedAndTheNextOneTried() async throws {
    let root = try makeTree(["1": ["a.jpg"], "2": ["b.jpg"], "3": ["c.jpg"]])
    defer { try? FileManager.default.removeItem(at: root) }
    let nav = FolderNavigator(timeout: .milliseconds(150)) { url in
        if url.lastPathComponent == "2" { Thread.sleep(forTimeInterval: 1) }
        return try FolderSiblings.listEntries(url)
    }
    let next = try await nav.neighbour(of: root.appendingPathComponent("1"), step: 1)
    #expect(next?.folder == root.appendingPathComponent("3"))
}

@Test func invalidateForgetsCachesSoNewFoldersAppear() async throws {
    let root = try makeTree(["1": ["a.jpg"], "2": []])
    defer { try? FileManager.default.removeItem(at: root) }
    let nav = FolderNavigator()
    #expect(try await nav.neighbour(of: root.appendingPathComponent("1"), step: 1) == nil)   // 2 is empty
    try Data([0]).write(to: root.appendingPathComponent("2/b.jpg"))
    #expect(try await nav.neighbour(of: root.appendingPathComponent("1"), step: 1) == nil)   // remembered empty
    await nav.invalidate()
    #expect(try await nav.neighbour(of: root.appendingPathComponent("1"), step: 1)?.folder == root.appendingPathComponent("2"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("3"), withIntermediateDirectories: true)
    try Data([0]).write(to: root.appendingPathComponent("3/c.jpg"))
    await nav.invalidate()
    #expect(try await nav.neighbour(of: root.appendingPathComponent("2"), step: 1)?.folder == root.appendingPathComponent("3"))
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [URL: Int] = [:]
    func increment(_ url: URL) { lock.withLock { counts[url.standardizedFileURL, default: 0] += 1 } }
    func count(of url: URL) -> Int { lock.withLock { counts[url.standardizedFileURL, default: 0] } }
}
