import Testing
import Foundation
@testable import LoupeCore

@Suite struct FolderVisitTests {
    private let fm = FileManager.default
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func tempDir() -> URL {
        fm.temporaryDirectory.appendingPathComponent("loupe-visit-\(UUID().uuidString)")
    }

    private func folder(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private func summary(photos: Int, last: Date? = nil, datesKnown: Bool = false) -> FolderSummary {
        FolderSummary(photos: photos, folders: 0, last: last, datesKnown: datesKnown)
    }

    @Test func visitRoundTrips() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let p = FolderPositions(database: try StateDatabase(directory: dir))
        #expect(p.visit(in: folder("/photos/a")) == nil)
        p.record(folder: folder("/photos/a"), file: "a7.jpg")
        #expect(p.visit(in: folder("/photos/a")) == nil)
        p.recordVisit(folder: folder("/photos/a"), index: 6, count: 40, at: t0)
        #expect(p.visit(in: folder("/photos/a")) == FolderVisit(index: 6, count: 40, visited: t0))
        // Recording the position again keeps the visit.
        p.record(folder: folder("/photos/a"), file: "a8.jpg")
        #expect(p.visit(in: folder("/photos/a")) == FolderVisit(index: 6, count: 40, visited: t0))
        p.flush()
        let again = FolderPositions(database: try StateDatabase(directory: dir))
        #expect(again.visit(in: folder("/photos/a")) == FolderVisit(index: 6, count: 40, visited: t0))
        #expect(again.fileName(in: folder("/photos/a")) == "a8.jpg")
    }

    @Test func visitsShareThePositionWrite() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let p = FolderPositions(database: try StateDatabase(directory: dir), debounce: .seconds(60))
        p.record(folder: folder("/photos/a"), file: "a0.jpg")
        for i in 0..<50 { p.recordVisit(folder: folder("/photos/a"), index: i, count: 50, at: t0) }
        #expect(p.writes == 0)
        p.flush()
        #expect(p.writes == 1)
    }

    @Test func visitWithoutPositionIsIgnoredAndCapStillApplies() {
        let p = FolderPositions(database: nil, capacity: 2)
        p.recordVisit(folder: folder("/photos/x"), index: 0, count: 1, at: t0)
        #expect(p.visit(in: folder("/photos/x")) == nil)
        for n in 1...3 {
            p.record(folder: folder("/photos/f\(n)"), file: "a.jpg")
            p.recordVisit(folder: folder("/photos/f\(n)"), index: 0, count: 1, at: t0)
        }
        #expect(p.count == 2)
        #expect(p.visit(in: folder("/photos/f1")) == nil)
        #expect(p.visit(in: folder("/photos/f3")) != nil)
    }

    @Test func progressAndDone() {
        func v(_ i: Int, _ c: Int) -> FolderVisit { FolderVisit(index: i, count: c, visited: t0) }
        #expect(v(0, 4).progress() == 0.25)
        #expect(v(1, 4).progress() == 0.5)
        #expect(!v(2, 4).done)
        #expect(v(3, 4).progress() == 1 && v(3, 4).done)
        #expect(v(0, 0).progress() == 0 && !v(0, 0).done)
        #expect(v(0, 1).done)
    }

    @Test func newByDatesAndByCount() {
        let visit = FolderVisit(index: 2, count: 10, visited: t0)
        let later = t0.addingTimeInterval(60), earlier = t0.addingTimeInterval(-60)
        // With dates: those after the visit, whatever the counts say.
        #expect(FolderVisit.new(since: visit, summary: summary(photos: 10), dates: [earlier, later, later, t0]) == 2)
        #expect(FolderVisit.new(since: visit, summary: summary(photos: 10), dates: []) == 0)
        // Without: unchanged dates mean none even if the count grew (a share's names only: growth).
        #expect(FolderVisit.new(since: visit, summary: summary(photos: 15, last: earlier, datesKnown: true), dates: nil) == 0)
        #expect(FolderVisit.new(since: visit, summary: summary(photos: 15, last: t0, datesKnown: true), dates: nil) == 0)
        #expect(FolderVisit.new(since: visit, summary: summary(photos: 15, last: later, datesKnown: true), dates: nil) == 5)
        #expect(FolderVisit.new(since: visit, summary: summary(photos: 14), dates: nil) == 4)
    }

    @Test func deletedFilesNeverNegative() {
        let visit = FolderVisit(index: 299, count: 300, visited: t0)
        #expect(FolderVisit.new(since: visit, summary: summary(photos: 250), dates: nil) == 0)
        #expect(FolderVisit(index: 299, count: 250, visited: t0).progress() == 1)
        #expect(FolderVisit(index: 299, count: 250, visited: t0).done)
    }

    @Test func movedFolderKeepsVisit() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let p = FolderPositions(database: try StateDatabase(directory: dir))
        p.record(folder: folder("/photos/old"), file: "a.jpg")
        p.recordVisit(folder: folder("/photos/old"), index: 3, count: 9, at: t0)
        p.movePaths(from: folder("/photos/old"), to: folder("/photos/new"))
        #expect(p.visit(in: folder("/photos/old")) == nil)
        #expect(p.visit(in: folder("/photos/new")) == FolderVisit(index: 3, count: 9, visited: t0))
        p.flush()
        let again = FolderPositions(database: try StateDatabase(directory: dir))
        #expect(again.visit(in: folder("/photos/new")) == FolderVisit(index: 3, count: 9, visited: t0))
        #expect(again.visit(in: folder("/photos/old")) == nil)
    }
}
