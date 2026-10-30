import Foundation
import Testing
@testable import LoupeCore

@Suite struct FileViewHistoryTests {
    @Test func onlySuccessfulPresentationPersistsAndSurvivesCacheRemoval() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try StateDatabase(directory: dir)
        let history = FileViewHistory(database: database)
        let url = URL(fileURLWithPath: "/Examples/cat.jpg")
        let receipt = try #require(history.presentation(for: url, client: UUID(), retry: {}))
        #expect(await history.lastViewed([url]).isEmpty)
        receipt.presented(at: nil)
        #expect(await history.lastViewed([url]).isEmpty)
        let date = Date(timeIntervalSince1970: 1234)
        receipt.presented(at: date)
        receipt.presented(at: date.addingTimeInterval(5)) // colour/refinement must not bump the same visit
        history.flush()
        let cacheDirectory = dir.appendingPathComponent("cache")
        let cache = try ThumbnailDatabase(directory: cacheDirectory, thumbSize: 512)
        cache.close()
        ThumbnailDatabase.removeFiles(in: cacheDirectory)
        let reopened = FileViewHistory(database: try StateDatabase(directory: dir))
        #expect(await reopened.lastViewed([url])[url] == date)
        let newer = try #require(reopened.presentation(for: url, client: UUID(), retry: {}))
        newer.presented(at: date.addingTimeInterval(10))
        reopened.flush()
        #expect(await reopened.lastViewed([url])[url] == date.addingTimeInterval(10))
        let lateOld = try #require(reopened.presentation(for: url, client: UUID(), retry: {}))
        lateOld.presented(at: date)
        reopened.flush()
        #expect(await reopened.lastViewed([url])[url] == date.addingTimeInterval(10))
    }
    @Test func boundedAdmissionRetriesAndUnshownReceiptsReleaseTheirSlot() throws {
        let history = FileViewHistory(database: nil, capacity: 1)
        let url = URL(fileURLWithPath: "/Examples/cat.jpg")
        var first = history.presentation(for: url, client: UUID(), retry: {})
        #expect(first != nil)
        #expect(history.presentation(for: url, client: UUID(), retry: {}) == nil)
        first = nil
        #expect(history.presentation(for: url, client: UUID(), retry: {}) != nil)
    }
    @Test func localRenameMovesHistoryButLeavesSourceURLsAlone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = FileViewHistory(database: try StateDatabase(directory: dir))
        let old = URL(fileURLWithPath: "/Examples/cat.jpg"), new = URL(fileURLWithPath: "/Examples/dog.jpg")
        let source = URL(string: "photos://asset/example")!
        let date = Date(timeIntervalSince1970: 1234)
        for url in [old, source] {
            let receipt = try #require(history.presentation(for: url, client: UUID(), retry: {}))
            receipt.presented(at: date)
        }
        history.flush()
        let delayed = try #require(history.presentation(for: old, client: UUID(), retry: {}))
        history.movePaths(from: old, to: new)
        history.flush()
        delayed.presented(at: date.addingTimeInterval(1))
        history.flush()
        let values = await history.lastViewed([old, new, source])
        #expect(values[old] == nil)
        #expect(values[new] == date.addingTimeInterval(1))
        #expect(values[source] == date)
    }
}

@Suite struct FileViewHistoryAdmissionTests {
    @Test func spreadAdmissionIsAtomicAndHiddenPresentationsDoNotRecord() async throws {
        let history = FileViewHistory(database: nil, capacity: 2)
        let a = URL(fileURLWithPath: "/Examples/cat.jpg"), b = URL(fileURLWithPath: "/Examples/dog.jpg")
        var held = history.presentation(for: a, client: UUID(), retry: {})
        #expect(held != nil)
        #expect(history.presentations(for: [a, b], client: UUID(), retry: {}) == nil)
        held = nil
        let gate = FileViewVisibility()
        let date = Date(timeIntervalSince1970: 1234)
        gate.setVisible(true, at: date.addingTimeInterval(-1))
        let pair = try #require(history.presentations(for: [a, b], client: UUID(), visibility: gate, retry: {}))
        gate.setVisible(false, at: date.addingTimeInterval(1))
        pair[0].presented(at: date.addingTimeInterval(2))
        #expect(await history.lastViewed([a]).isEmpty)
        // A late callback for a frame that was actually visible still counts after the view is hidden.
        pair[0].presented(at: date)
        pair[1].presented(at: date)
        history.flush()
        #expect(await history.lastViewed([a, b]).count == 2)
    }
}

private final class HistoryNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date] = []
    func append(_ date: Date) { lock.withLock { dates.append(date) } }
    var values: [Date] { lock.withLock { dates } }
}
@MainActor @Suite struct FileViewHistoryNotificationTests {
    @Test func delayedOlderFrameCannotRegressLiveTimestamp() async throws {
        let history = FileViewHistory(database: nil)
        let url = URL(fileURLWithPath: "/Examples/cat.jpg")
        let probe = HistoryNotifications()
        let observer = NotificationCenter.default.addObserver(forName: FileViewHistory.didChange, object: history, queue: .main) { note in
            if let dates = note.userInfo?["dates"] as? [URL: Date], let date = dates[url] { probe.append(date) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let first = Date(timeIntervalSince1970: 1234), later = first.addingTimeInterval(10)
        for date in [first, later, first] {
            let receipt = try #require(history.presentation(for: url, client: UUID(), retry: {}))
            receipt.presented(at: date)
            history.flush()
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while probe.values.count < 3, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(probe.values == [first, later, later])
    }
}

@Suite struct FileViewRetryBudgetTests {
    @Test func presentationRetriesStopAtTheBudgetOrFirstConfirmedFrame() throws {
        let history = FileViewHistory(database: nil)
        let receipt = try #require(history.presentation(for: URL(fileURLWithPath: "/Examples/cat.jpg"), client: UUID(), retry: {}))
        for _ in 0..<16 { #expect(receipt.requestPresentationRetry()) }
        #expect(!receipt.requestPresentationRetry())
        receipt.presented(at: Date())
        #expect(!receipt.requestPresentationRetry())
        history.flush()
    }
}
