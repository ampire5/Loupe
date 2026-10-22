import Testing
import Foundation
@testable import LoupeCore

private let root = URL(fileURLWithPath: "/photos/trip")

private func year(_ y: Int) -> Date { Date(timeIntervalSince1970: Double(y - 1970) * 365.25 * 86400) }

private func photo(_ name: String, _ date: Date, size: Int = 1000) -> DirectoryEntry {
    DirectoryEntry(url: root.appendingPathComponent(name), isDirectory: false, isPackage: false,
                   stamp: FileStamp(modified: date, size: size))
}

private func dir(_ name: String, package: Bool = false) -> DirectoryEntry {
    DirectoryEntry(url: root.appendingPathComponent(name), isDirectory: true, isPackage: package)
}

@Test func countsAndSpan() {
    let s = FolderSummary.of(entries: [
        photo("a.jpg", year(2019), size: 100), photo("b.JPG", year(2021), size: 200), photo("c.png", year(2023), size: 300),
        photo("notes.txt", year(2024)), photo(".hidden.jpg", year(2025)),
        dir("x"), dir("y"), dir(".git"), dir("Some.app", package: true),
    ])
    #expect(s.photos == 3)
    #expect(s.folders == 2)
    #expect(s.first == year(2019))
    #expect(s.last == year(2023))
    #expect(s.bytes == 600)
    #expect(s.datesKnown)
}

@Test func histogramShares() {
    let dates = (0..<8).map { year(2000 + $0 * 3) }
    let s = FolderSummary.of(entries: dates.enumerated().map { photo("\($0.offset).jpg", $0.element) })
    #expect(s.histogram.count == FolderSummary.histogramBins)
    let sum = s.histogram.reduce(0) { $0 + Int($1) }
    #expect(abs(sum - 255) <= FolderSummary.histogramBins)
    #expect(s.histogram.contains(0))
    #expect(s.histogram.first! > 0 && s.histogram.last! > 0)
}

@Test func oneDateAndNoPhotos() {
    let one = FolderSummary.of(entries: [photo("a.jpg", year(2020)), photo("b.jpg", year(2020))])
    #expect(one.histogram == [255] + [UInt8](repeating: 0, count: 11))
    let none = FolderSummary.of(entries: [dir("x")])
    #expect(none.histogram.isEmpty)
    #expect(none.first == nil && none.last == nil)
    #expect(none.photos == 0 && none.folders == 1)
}

@Test func namesOnlyHasNoDates() {
    let s = FolderSummary.of(names: CoverNames(files: ["a.jpg", "b.jpg"], folders: ["x"]), folderModified: year(2022))
    #expect(!s.datesKnown)
    #expect(s.bytes == nil)
    #expect(s.first == nil && s.last == nil && s.histogram.isEmpty)
    #expect(s.photos == 2 && s.folders == 1)
    #expect(s.folderModified == year(2022))
}

@Test func archiveHasNoHistogram() {
    let s = FolderSummary.ofArchive(photos: 40, bytes: 5_000, modified: year(2020))
    #expect(s.histogram.isEmpty)
    #expect(s.photos == 40 && s.folders == 0 && s.bytes == 5_000)
    #expect(s.first == year(2020) && s.last == year(2020))
}

@Test func insideSumsKnown() {
    let a = FolderSummary(photos: 5, folders: 0)
    let b = FolderSummary(photos: 7, folders: 1)
    let r = FolderSummary(photos: 1, folders: 0).inside([a, nil, b])
    #expect(r.photos == 12)
    #expect(r.incomplete)
    let all = FolderSummary(photos: 1, folders: 0).inside([a, b])
    #expect(all.photos == 12 && !all.incomplete)
}
