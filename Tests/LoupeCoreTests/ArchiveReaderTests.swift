import Foundation
import Testing
@testable import LoupeCore

/// Reading zip entries (Stash spec §2.4): the cached directory, ranged reads, inflate, the listing rules, and entries
/// served by `FileReader` through its pool.
@Suite struct ArchiveReaderTests {
    let a = ZipFixture.bytes(20_000), b = ZipFixture.bytes(7_000, seed: 3)

    func entryURL(_ zip: URL, _ inner: String) -> URL { ArchivePath.url(archive: zip, entry: inner)! }

    @Test func readsStoredEntry() throws {
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "caps/01.jpg", data: a, method: 0)]))
        #expect(try ArchiveReader().read(entryURL(zip, "caps/01.jpg")).data == a)
    }

    @Test func readsDeflatedEntry() throws {
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "x.jpg", data: b), .init(name: "y.jpg", data: a)]))
        let reader = ArchiveReader()
        #expect(try reader.read(entryURL(zip, "y.jpg")).data == a)
        #expect(try reader.read(entryURL(zip, "x.jpg")).data == b)
    }

    @Test func crcMismatchIsDamaged() throws {
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "x.jpg", data: a, crc: 1)]))
        #expect(throws: ArchiveError.damaged) { try ArchiveReader().read(entryURL(zip, "x.jpg")) }
    }

    @Test func encryptedEntryThrows() throws {
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "x.jpg", data: a, method: 0, encrypted: true)]))
        #expect(throws: ArchiveError.encrypted) { try ArchiveReader().read(entryURL(zip, "x.jpg")) }
    }

    @Test func bzip2Throws() throws {
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "x.jpg", data: a, method: 12)]))
        #expect(throws: ArchiveError.unsupportedMethod(12)) { try ArchiveReader().read(entryURL(zip, "x.jpg")) }
    }

    @Test func missingEntryThrows() throws {
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "x.jpg", data: a)]))
        #expect(throws: ArchiveError.entryNotFound) { try ArchiveReader().read(entryURL(zip, "nope.jpg")) }
    }

    @Test func stampIsArchiveMtimePlusEntrySize() throws {
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "x.jpg", data: b)]))
        let mtime = try #require(try zip.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let stamp = try ArchiveReader().stamp(entryURL(zip, "x.jpg"))
        #expect(stamp == FileStamp(modified: mtime, size: b.count))
        #expect(try ArchiveReader().read(entryURL(zip, "x.jpg")).stamp == stamp)
    }

    @Test func listingSkipsMacOSXAndDotUnderscore() throws {
        let one = Data([1])
        let zip = try ZipFixture.write(ZipFixture.make([
            .init(name: "__MACOSX/caps/._01.jpg", data: one), .init(name: "caps/._02.jpg", data: one),
            .init(name: "caps/03.jpg", data: one), .init(name: "notes.txt", data: one), .init(name: "caps/", data: Data()),
            .init(name: "odd\u{2215}name.jpg", data: one), .init(name: "Caps/04.JPG", data: one),
        ]))
        let names = try ArchiveReader().entries(of: zip).map(\.url.lastPathComponent)
        #expect(names == ["caps\u{2215}03.jpg", "Caps\u{2215}04.JPG"])
    }

    @Test func largeDirectoryNeedsSecondRead() throws {
        let entries = (0..<5000).map { ZipFixture.Entry(name: String(format: "caps/%05d.jpg", $0), data: Data([1]), method: 0) }
        let zip = try ZipFixture.write(ZipFixture.make(entries, comment: Data(repeating: 0x20, count: 60_000)))
        let listed = try ArchiveReader().entries(of: zip)
        #expect(listed.count == 5000 && listed.last?.url.lastPathComponent == "caps\u{2215}04999.jpg")
    }

    @Test func directoryCacheDropsAChangedArchive() throws {
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "x.jpg", data: a)]))
        let reader = ArchiveReader()
        #expect(try reader.entries(of: zip).count == 1)
        try ZipFixture.make([.init(name: "x.jpg", data: a), .init(name: "y.jpg", data: b)]).write(to: zip)
        #expect(try reader.entries(of: zip).count == 2)
    }

    @Test func fileReaderServesAnEntry() async throws {
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "caps/01.jpg", data: a)]))
        let reader = FileReader(isLocal: { _ in false })
        let url = entryURL(zip, "caps/01.jpg")
        let bytes = try await reader.read(url, priority: 0)
        #expect(bytes.data == a)
        #expect(try await reader.stamp(url, priority: 0) == bytes.stamp)
        #expect(try await reader.readPrefix(url, priority: ReadPriority(0)) { _ in true }.data == a)
    }

    @Test(.timeLimit(.minutes(1))) func entryReadGoesThroughThePool() async throws {
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "x.jpg", data: a)]))
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in 0..<8 { gate.signal() } }
        let reader = FileReader(threads: 1, timeout: .milliseconds(300), isLocal: { _ in false },
                                chunkReader: { _, _, _, _ in gate.wait(); return -1 })
        await #expect(throws: ReadError.notResponding) { try await reader.read(entryURL(zip, "x.jpg"), priority: 0) }
    }
}
