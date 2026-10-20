import Foundation
import Testing
@testable import LoupeCore

/// Folder steps through a list (Stash spec §2.3): the next item's folder with its label, items that cannot be opened
/// skipped with a note, the end reported.
@Suite struct ListFolderNavigatorTests {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ s: String) { lock.withLock { lines.append(s) } }
        var all: [String] { lock.withLock { lines } }
    }

    /// Items "a", "b", "c" at 0, 1, 2 of 3, from `start`; `bad` paths fail to resolve, `empty` ones have no photos.
    func navigator(start: Int, names: [String] = ["a", "b", "c"], bad: Set<String> = [], empty: Set<String> = [],
                   log: Log) -> ListFolderNavigator {
        ListFolderNavigator(
            start: start,
            next: { index, step in
                let i = index + (step > 0 ? 1 : -1)
                guard names.indices.contains(i) else { return .end }
                return .item(title: names[i].uppercased(), path: names[i], index: i, count: names.count, id: "#" + names[i])
            },
            resolve: { path in
                bad.contains(path) ? .failure(ArchiveError.damaged) : .success(URL(fileURLWithPath: "/g/\(path)"))
            },
            contents: { url in
                empty.contains(url.lastPathComponent) ? nil
                    : FolderTarget(folder: url, images: [url.appendingPathComponent("1.jpg")])
            },
            onEnd: { log.add("end") },
            onSkip: { log.add($0) })
    }

    let here = URL(fileURLWithPath: "/g/a")

    @Test func stepsToTheNextItemWithLabel() async throws {
        let log = Log()
        let t = try #require(try await navigator(start: 0, log: log).neighbour(of: here, step: 1))
        #expect(t.folder.path == "/g/b" && t.label == "B · 2 / 3" && t.listID == "#b" && log.all.isEmpty)
    }

    @Test func skipsAnUnresolvableItem() async throws {
        let log = Log()
        let t = try #require(try await navigator(start: 0, bad: ["b"], log: log).neighbour(of: here, step: 1))
        #expect(t.folder.path == "/g/c" && t.listID == "#c" && log.all == ["Skipped B: Damaged archive"])
    }

    @Test func skipsAnItemWithoutPhotos() async throws {
        let log = Log()
        let t = try #require(try await navigator(start: 0, empty: ["b"], log: log).neighbour(of: here, step: 1))
        #expect(t.folder.path == "/g/c" && log.all == ["Skipped B: no photos"])
    }

    @Test func endCallsOnEnd() async throws {
        let log = Log()
        #expect(try await navigator(start: 2, log: log).neighbour(of: here, step: 1) == nil)
        #expect(log.all == ["end"])
    }

    @Test func previousStep() async throws {
        let log = Log()
        let t = try #require(try await navigator(start: 2, log: log).neighbour(of: here, step: -1))
        #expect(t.label == "B · 2 / 3")
    }

    @Test func aStepThatFindsNothingDoesNotMoveTheList() async throws {
        let log = Log()
        let nav = navigator(start: 0, bad: ["b", "c"], log: log)
        #expect(try await nav.neighbour(of: here, step: 1) == nil)
        #expect(log.all == ["Skipped B: Damaged archive", "Skipped C: Damaged archive", "end"])
        #expect(await nav.position == 0)
    }

    @Test func manyUnopenableItemsStopTheStep() async throws {
        let log = Log()
        let names = (0..<50).map { "g\($0)" }
        let nav = navigator(start: 0, names: names, bad: Set(names), log: log)
        #expect(try await nav.neighbour(of: here, step: 1) == nil)
        #expect(log.all.count == ListFolderNavigator.skipLimit + 1)
        #expect(log.all.last == "Stopped: \(ListFolderNavigator.skipLimit) galleries in a row could not be opened")
        #expect(await nav.position == 0)
    }

    @Test func aCancelledStepStops() async throws {
        let log = Log()
        let nav = navigator(start: 0, bad: ["b"], log: log)
        let task = Task { try await nav.neighbour(of: here, step: 1) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func positionFollowsTheTargetFound() async throws {
        let log = Log()
        let nav = navigator(start: 0, log: log)
        _ = try await nav.neighbour(of: here, step: 1)
        #expect(await nav.position == 1)
        let t = try #require(try await nav.neighbour(of: here, step: 1))
        #expect(t.label == "C · 3 / 3")
    }
}
