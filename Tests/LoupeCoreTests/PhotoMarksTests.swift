import Foundation
import Testing
@testable import LoupeCore

/// Which photos of a folder show the dot (not viewed yet) and the ⧉ chip (a page of a pair): photo-cards spec §3.
@Suite struct PhotoMarksTests {
    private let folder = URL(fileURLWithPath: "/Volumes/T/x")
    private var files: [URL] { (1...5).map { folder.appendingPathComponent("p\($0).jpg") } }
    private let visited = Date(timeIntervalSinceReferenceDate: 1_000)
    private var visit: FolderVisit { FolderVisit(index: 2, count: 5, visited: visited) }
    private func old(_: URL) -> Date? { Date(timeIntervalSinceReferenceDate: 500) }

    @Test func noPositionAllUnseen() {
        #expect(PhotoMarks.unseen(order: files, remembered: nil, visit: nil, modified: old) == Set(files))
    }

    @Test func afterRememberedUnseen() {
        #expect(PhotoMarks.unseen(order: files, remembered: "p3.jpg", visit: visit, modified: old)
                == [files[3], files[4]])
    }

    @Test func rememberedLastNone() {
        #expect(PhotoMarks.unseen(order: files, remembered: "p5.jpg", visit: visit, modified: old).isEmpty)
    }

    @Test func newerThanVisitUnseen() {
        let second = files[1]
        let dates: (URL) -> Date? = { $0 == second ? Date(timeIntervalSinceReferenceDate: 2_000) : old($0) }
        #expect(PhotoMarks.unseen(order: files, remembered: "p5.jpg", visit: visit, modified: dates) == [second])
    }

    @Test func goneFileByDates() {
        let fourth = files[3]
        let dates: (URL) -> Date? = { $0 == fourth ? Date(timeIntervalSinceReferenceDate: 2_000) : old($0) }
        #expect(PhotoMarks.unseen(order: files, remembered: "gone.jpg", visit: visit, modified: dates) == [fourth])
        // No visit either: nothing to go by, all unviewed.
        #expect(PhotoMarks.unseen(order: files, remembered: "gone.jpg", visit: nil, modified: dates) == Set(files))
    }

    private func rules(on: Bool = true, shift: Bool = false, landscapeAlone: Bool = true) -> SpreadRules {
        SpreadRules(on: on, options: SpreadOptions(shift: shift, rightToLeft: false, landscapeAlone: landscapeAlone))
    }

    /// Left at the spread of pages 3–4: the remembered page is one of them, the other was on screen too (review, 6).
    @Test func rememberedPartnerViewed() {
        let six = (1...6).map { folder.appendingPathComponent("p\($0).jpg") }
        let pairs = PhotoMarks.pairs(order: six, rules: rules(), aspects: [])
        #expect(pairs[six[2]] == six[3] && pairs[six[3]] == six[2])
        #expect(PhotoMarks.unseen(order: six, remembered: "p3.jpg", visit: visit, modified: old, partner: pairs[six[2]])
                == [six[4], six[5]])
    }

    @Test func pairedOff() {
        #expect(PhotoMarks.paired(order: files, rules: rules(on: false), aspects: []).isEmpty)
    }

    @Test func pairedAll() {
        let four = Array(files.prefix(4))
        #expect(PhotoMarks.paired(order: four, rules: rules(), aspects: [0.75, 0.75, 0.75, 0.75]) == Set(four))
        // An odd page out at the end stands alone.
        #expect(PhotoMarks.paired(order: files, rules: rules(), aspects: []) == Set(four))
    }

    @Test func pairedShift() {
        let four = Array(files.prefix(4))
        #expect(PhotoMarks.paired(order: four, rules: rules(shift: true), aspects: []) == [four[1], four[2]])
    }

    @Test func landscapeAlone() {
        let four = Array(files.prefix(4))
        #expect(PhotoMarks.paired(order: four, rules: rules(), aspects: [0.75, 1.5, 0.75, 0.75]) == [four[2], four[3]])
        // Without `landscapeAlone` the wide page pairs too.
        #expect(PhotoMarks.paired(order: four, rules: rules(landscapeAlone: false), aspects: [0.75, 1.5, 0.75, 0.75])
                == Set(four))
    }

    @Test func unknownAspectsPair() {
        let four = Array(files.prefix(4))
        #expect(PhotoMarks.paired(order: four, rules: rules(), aspects: [nil, nil, nil, nil]) == Set(four))
    }
}
