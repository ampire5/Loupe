import Foundation
import Testing
import HomeScreenModel
@testable import LoupeCore

struct FolderStripSourceTests {
    private let root = URL(fileURLWithPath: "/photos", isDirectory: true)
    private func entry(_ name: String, directory: Bool = true, package: Bool = false) -> DirectoryEntry {
        DirectoryEntry(url: root.appendingPathComponent(name), isDirectory: directory, isPackage: package)
    }
    @Test func visibleSiblingsKeepEmptyFoldersAndUnknownCounts() async throws {
        let items = [entry("B"), entry("A"), entry(".hidden"), entry("App.app", package: true), entry("book.zip", directory: false)]
        let source = FolderStripListing(archives: false, list: { _ in items })
        let rows = try await source.rows(around: .folder(root.appendingPathComponent("A")))
        #expect(rows.map(\.title) == ["A", "B"])
        #expect(rows.allSatisfy { $0.photoCount == nil && $0.depth == 0 })
    }
    @Test func archivesFollowSetting() async throws {
        let items = [entry("book.zip", directory: false)]
        let yes = FolderStripListing(archives: true, list: { _ in items })
        let no = FolderStripListing(archives: false, list: { _ in items })
        #expect(try await yes.rows(around: .folder(root.appendingPathComponent("book.zip"))).count == 1)
        #expect(try await no.rows(around: .folder(root.appendingPathComponent("book.zip"))).isEmpty)
    }
    @Test func emptyTreeTerminatesAndFindsFirstReadablePhoto() async throws {
        let base = root
        let source = FolderStripListing(list: { folder in
            switch folder.lastPathComponent {
            case "photos": return [DirectoryEntry(url: base.appendingPathComponent("A"), isDirectory: true, isPackage: false), DirectoryEntry(url: base.appendingPathComponent("B"), isDirectory: true, isPackage: false)]
            case "A": return []
            case "B": return [DirectoryEntry(url: folder.appendingPathComponent("1.jpg"), isDirectory: false, isPackage: false)]
            default: return []
            }
        })
        let target = try await source.target(for: .folder(root))
        #expect(target?.folder.lastPathComponent == "B")
        #expect(target?.images.first?.lastPathComponent == "1.jpg")
        #expect(try await source.target(for: .folder(root.appendingPathComponent("A"))) == nil)
    }
    @Test func repeatedDirectoryCycleTerminates() async throws {
        let base = root
        let source = FolderStripListing(list: { _ in [DirectoryEntry(url: base, isDirectory: true, isPackage: false)] })
        #expect(try await source.target(for: .folder(root)) == nil)
    }
    @Test func cancelledSearchDoesNotStartAnotherListing() async {
        let source = FolderStripListing(list: { _ in try Task.checkCancellation(); return [] })
        let task = Task { try await source.target(for: .folder(root)) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Wrong error: \(error)") }
    }
    @Test func symbolicDirectoryLinkIsNotFollowed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("loop"), withDestinationURL: directory)
        let entries = try await FolderStripListing.diskEntries(directory)
        #expect(entries.isEmpty)
    }
    @Test func pagedGalleryRetainsServerOrderAndStableIdentity() async throws {
        let source = FolderStripGallerySource(rows: { _ in
            [FolderStripEntry(id: .gallery("9"), title: "Z"), FolderStripEntry(id: .gallery("2"), title: "A")]
        }, target: { _ in nil })
        #expect(try await source.rows(around: .gallery("9")).map(\.id) == [.gallery("9"), .gallery("2")])
        #expect(try await source.children(of: .gallery("9")).isEmpty)
    }
}
