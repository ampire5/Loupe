import Darwin
import Foundation
import Testing
@testable import LoupeCore

/// A fake `open` whose calls park until the test lets them go, one by one or all; records paths and closes.
private final class FakeOpens: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var closes: [Int32] = []
    private var released = 0
    private let wake = NSCondition()
    private var fds: [String: Int32] = [:]
    private var nextFD: Int32 = 100

    var paths: [String] { lock.withLock { calls } }
    var closed: [Int32] { lock.withLock { closes } }

    /// Lets the next `n` parked (or future) opens return.
    func release(_ n: Int = 1) {
        wake.lock()
        released += n
        wake.broadcast()
        wake.unlock()
    }

    func open(_ path: String) -> FolderOpener.Outcome {
        lock.withLock { calls.append(path) }
        wake.lock()
        while released == 0 { wake.wait() }
        released -= 1
        wake.unlock()
        if path.hasSuffix("/missing") { return .failed(errno: ENOENT) }
        return .opened(lock.withLock { nextFD += 1; return nextFD })
    }

    func close(_ fd: Int32) { lock.withLock { closes.append(fd) } }
}

@MainActor @Suite struct FolderOpenerTests {
    private let a = URL(fileURLWithPath: "/Volumes/share/a")
    private let b = URL(fileURLWithPath: "/Volumes/share/b")

    private func opener(_ fake: FakeOpens) -> FolderOpener {
        FolderOpener(open: { fake.open($0) }, close: { fake.close($0) })
    }

    /// Polls `condition` every 2 ms (which lets the main queue deliver) until it holds or 5 s pass.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    @Test func aHungOpenDoesNotHoldTheCaller() async {
        let fake = FakeOpens()
        let opener = opener(fake)
        var got: [FolderOpener.Outcome] = []
        opener.open(a) { got.append($0) }                      // returns at once although the open is parked
        #expect(await eventually { fake.paths == [a.path] })
        #expect(got.isEmpty && opener.isOpening)
        fake.release()
        #expect(await eventually { got == [.opened(101)] })
        #expect(!opener.isOpening && fake.closed.isEmpty)
    }

    @Test func aFailureIsDelivered() async {
        let fake = FakeOpens()
        let opener = opener(fake)
        var got: [FolderOpener.Outcome] = []
        opener.open(a.appendingPathComponent("missing")) { got.append($0) }
        fake.release()
        #expect(await eventually { got == [.failed(errno: ENOENT)] })
    }

    /// The same folder again while its open is out: no second open alongside (a hung share would pile up threads),
    /// but a fresh one once it returns, since the path may hold a new vnode by now. Only that one is delivered.
    @Test func theSameFolderAgainOpensAnewAfterTheOneOut() async {
        let fake = FakeOpens()
        let opener = opener(fake)
        var got: [FolderOpener.Outcome] = []
        opener.open(a) { _ in Issue.record("superseded open delivered") }
        opener.open(a) { got.append($0) }
        #expect(await eventually { fake.paths.count == 1 })
        fake.release()
        #expect(await eventually { fake.paths == [a.path, a.path] })
        #expect(await eventually { fake.closed == [101] })     // the first descriptor, closed here
        fake.release()
        #expect(await eventually { got == [.opened(102)] })
    }

    /// Another folder while the first one's open hangs: it opens at once, and the first one's late descriptor is
    /// closed, never delivered.
    @Test func anotherFolderDoesNotWaitAndTheOldResultIsClosed() async {
        let fake = FakeOpens()
        let opener = opener(fake)
        var got: [FolderOpener.Outcome] = []
        opener.open(a) { _ in Issue.record("folder left delivered") }
        #expect(await eventually { fake.paths == [a.path] })
        opener.open(b) { got.append($0) }
        #expect(await eventually { fake.paths == [a.path, b.path] })
        fake.release(2)
        #expect(await eventually { got.count == 1 && fake.closed.count == 1 })
        #expect(got != [.opened(fake.closed[0])])
    }

    @Test func opensARealFolderForEvents() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-opener-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let opener = FolderOpener()
        var got: FolderOpener.Outcome?
        opener.open(dir) { got = $0 }
        #expect(await eventually { got != nil })
        guard case .opened(let fd) = got else { Issue.record("not opened: \(String(describing: got))"); return }
        #expect(fd >= 0)
        Darwin.close(fd)
        opener.open(dir.appendingPathComponent("gone")) { got = $0 }
        #expect(await eventually { got == .failed(errno: ENOENT) })
    }

    @Test func cancelClosesWhatArrivesLater() async {
        let fake = FakeOpens()
        let opener = opener(fake)
        opener.open(a) { _ in Issue.record("cancelled open delivered") }
        #expect(await eventually { fake.paths == [a.path] })
        opener.cancel()
        fake.release()
        #expect(await eventually { fake.closed == [101] })
    }
}
