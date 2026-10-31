import Foundation
import LoupeCore
import Testing
@testable import Loupe

@Suite(.serialized) @MainActor struct ViewerMetadataLoaderTests {
    private let a = URL(fileURLWithPath: "/example/a.jpg")
    private let b = URL(fileURLWithPath: "/example/b.jpg")

    @Test func publishesSizeBeforeMetadataAndDoesNotRereadTheSameSelection() async {
        let probe = MetadataProbe()
        let loader = ViewerMetadataLoader(pendingDelay: .seconds(60), stamp: { _ in (42, nil) },
                                           read: { url, _ in await probe.read(url) })
        var changes: [Bool] = []
        loader.onChange = { changes.append($0) }
        loader.select(a)
        #expect(await wait { await probe.count == 1 })
        #expect(loader.url == a)
        #expect(loader.size == 42)
        #expect(loader.metadata == nil)
        #expect(changes == [false])
        loader.select(a)
        await probe.finish(0, camera: "Camera A")
        #expect(await wait { loader.metadata?.camera == "Camera A" })
        #expect(changes == [false, true])
        #expect(await probe.count == 1)
        #expect(!loader.isPending)
        loader.stop()
    }

    @Test func pendingAppearsOnlyWhileReadingAndClearsOnCompletion() async {
        let probe = MetadataProbe()
        let loader = ViewerMetadataLoader(pendingDelay: .zero, stamp: { _ in (42, nil) },
                                           read: { url, _ in await probe.read(url) })
        loader.select(a)
        #expect(await wait { let count = await probe.count; return loader.isPending && count == 1 })
        await probe.finish(0, camera: "Ready")
        #expect(await wait { loader.metadata != nil })
        #expect(!loader.isPending)
        loader.stop()
    }

    @Test func quickCompletionCancelsDelayedPending() async {
        let loader = ViewerMetadataLoader(pendingDelay: .milliseconds(20), stamp: { _ in (42, nil) },
                                           read: { _, _ in Self.metadata("Ready") })
        var pendingWasShown = false
        loader.onChange = { _ in pendingWasShown = pendingWasShown || loader.isPending }
        loader.select(a)
        #expect(await wait { loader.metadata != nil })
        try? await Task.sleep(for: .milliseconds(40))
        #expect(!pendingWasShown)
        #expect(!loader.isPending)
        loader.onChange = nil
        loader.stop()
    }

    @Test func returningToTheSameURLCannotPublishAnOldRequest() async {
        let probe = MetadataProbe()
        let loader = ViewerMetadataLoader(pendingDelay: .seconds(60), stamp: { _ in (42, nil) },
                                           read: { url, _ in await probe.read(url) })
        loader.select(a)
        #expect(await wait { await probe.count == 1 })
        loader.select(b)
        #expect(await wait { await probe.count == 2 })
        loader.select(a)
        #expect(await wait { await probe.count == 3 })
        await probe.finish(2, camera: "New A")
        #expect(await wait { loader.metadata?.camera == "New A" })
        var changes = 0
        loader.onChange = { _ in changes += 1 }
        await probe.finish(0, camera: "Old A")
        await probe.finish(1, camera: "B")
        // Drain the resumed read tasks before checking that neither published.
        for _ in 0..<20 { await Task.yield() }
        #expect(loader.metadata?.camera == "New A")
        #expect(changes == 0)
        loader.stop()
    }

    @Test func stoppingClearsStateAndRejectsLateResultAndPending() async {
        let probe = MetadataProbe()
        let loader = ViewerMetadataLoader(pendingDelay: .milliseconds(20), stamp: { _ in (42, nil) },
                                           read: { url, _ in await probe.read(url) })
        loader.select(a)
        #expect(await wait { await probe.count == 1 })
        loader.stop()
        var changes = 0
        loader.onChange = { _ in changes += 1 }
        await probe.finish(0, camera: "Late")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(loader.url == nil)
        #expect(loader.size == nil)
        #expect(loader.metadata == nil)
        #expect(!loader.isPending)
        #expect(changes == 0)
    }

    @Test func stopDuringStatCannotPublishSizeOrStartMetadata() async {
        let stamp = StampProbe()
        let probe = MetadataProbe()
        let loader = ViewerMetadataLoader(stamp: { _ in await stamp.read() },
                                           read: { url, _ in await probe.read(url) })
        loader.select(a)
        #expect(await wait { await stamp.started })
        loader.stop()
        await stamp.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(loader.size == nil)
        #expect(await probe.count == 0)
    }

    @Test func nonFileAndNilSelectionsDoNotStartReads() async {
        let probe = MetadataProbe()
        let loader = ViewerMetadataLoader(stamp: { _ in Issue.record("Unexpected stat"); return (nil, nil) },
                                           read: { url, _ in await probe.read(url) })
        loader.select(URL(string: "photos://asset/example")!)
        loader.select(nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(await probe.count == 0)
        #expect(loader.url == nil)
        #expect(!loader.isPending)
    }

    private func wait(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    nonisolated private static func metadata(_ camera: String) -> PhotoMetadata {
        var result = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        result.camera = camera
        return result
    }
}

private actor MetadataProbe {
    private var continuations: [Int: CheckedContinuation<PhotoMetadata, Never>] = [:]
    private(set) var count = 0
    func read(_ url: URL) async -> PhotoMetadata {
        let id = count
        count += 1
        return await withCheckedContinuation { continuations[id] = $0 }
    }
    func finish(_ id: Int, camera: String) {
        var result = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        result.camera = camera
        continuations.removeValue(forKey: id)?.resume(returning: result)
    }
}

private actor StampProbe {
    private var continuation: CheckedContinuation<(size: Int?, modified: Date?), Never>?
    private(set) var started = false
    func read() async -> (size: Int?, modified: Date?) {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: (42, nil)); continuation = nil }
}
