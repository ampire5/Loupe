import Foundation
import Testing
@testable import LoupeCore

/// The zip central directory (Stash spec §2.4): EOCD, ZIP64, names, flags.
@Suite struct ZipDirectoryTests {
    func directory(_ zip: Data) throws -> ZipDirectory {
        let tail = zip.suffix(min(zip.count, ZipDirectory.tailLength))
        let place = try ZipDirectory.locate(tail: Data(tail), fileSize: zip.count)
        return try ZipDirectory.parse(zip.subdata(in: place.offset..<(place.offset + place.size)))
    }

    @Test func parsesStoredAndDeflate() throws {
        let a = ZipFixture.bytes(5000), b = ZipFixture.bytes(3000, seed: 2)
        let zip = ZipFixture.make([.init(name: "caps/01.jpg", data: a, method: 0),
                                   .init(name: "caps/02.jpg", data: b, method: 8)])
        let d = try directory(zip)
        #expect(d.entries.map(\.name) == ["caps/01.jpg", "caps/02.jpg"])
        #expect(d.entries.map(\.method) == [0, 8])
        #expect(d.entries[0].size == 5000 && d.entries[0].compressedSize == 5000 && d.entries[0].localHeaderOffset == 0)
        #expect(d.entries[1].size == 3000 && d.entries[1].localHeaderOffset == 30 + 11 + 5000)
        #expect(!d.entries[0].isEncrypted && !d.entries[0].isDirectory)
    }

    @Test func readsZip64() throws {
        let a = ZipFixture.bytes(4000)
        let zip = ZipFixture.make([.init(name: "a.jpg", data: a), .init(name: "b.jpg", data: a, method: 0)], zip64: true)
        let d = try directory(zip)
        #expect(d.entries.map(\.name) == ["a.jpg", "b.jpg"])
        #expect(d.entries[1].size == 4000 && d.entries[1].compressedSize == 4000)
        #expect(d.entries[1].localHeaderOffset == 30 + 5 + d.entries[0].compressedSize)
    }

    @Test func cp437NameDecodes() throws {
        let zip = ZipFixture.make([.init(name: "", data: Data([1]), method: 0,
                                         rawName: Data([0x81, 0x2E, 0x6A, 0x70, 0x67]))])
        #expect(try directory(zip).entries[0].name == "ü.jpg")
    }

    @Test func utf8NameDecodes() throws {
        let zip = ZipFixture.make([.init(name: "Ünïcødé/01.jpg", data: Data([1]), method: 0)])
        #expect(try directory(zip).entries[0].name == "Ünïcødé/01.jpg")
    }

    @Test func flagsEncrypted() throws {
        let zip = ZipFixture.make([.init(name: "x.jpg", data: Data([1]), method: 0, encrypted: true)])
        #expect(try directory(zip).entries[0].isEncrypted)
    }

    @Test func findsEOCDBehindAComment() throws {
        let zip = ZipFixture.make([.init(name: "x.jpg", data: Data([1, 2]), method: 0)],
                                  comment: Data(repeating: 0x41, count: 65_535))
        #expect(try directory(zip).entries.map(\.name) == ["x.jpg"])
    }

    @Test func findsEOCDBeforeTrailingBytes() throws {
        // Seen in the wild: six zero bytes after an end record with no comment; unzip reads such a file.
        let zip = ZipFixture.make([.init(name: "x.jpg", data: Data([1, 2]), method: 0)]) + Data(count: 6)
        #expect(try directory(zip).entries.map(\.name) == ["x.jpg"])
        let zip64 = ZipFixture.make([.init(name: "y.jpg", data: Data([1, 2]), method: 0)], zip64: true) + Data(count: 6)
        #expect(try directory(zip64).entries.map(\.name) == ["y.jpg"])
    }

    @Test func truncatedTailIsDamaged() throws {
        let zip = ZipFixture.make([.init(name: "x.jpg", data: Data([1, 2]), method: 0)])
        let cut = zip.prefix(zip.count - 10)
        #expect(throws: ArchiveError.damaged) { try ZipDirectory.locate(tail: Data(cut), fileSize: cut.count) }
    }

    @Test func badSignatureIsDamaged() throws {
        var zip = ZipFixture.make([.init(name: "x.jpg", data: Data([1, 2]), method: 0)])
        let tail = Data(zip.suffix(min(zip.count, ZipDirectory.tailLength)))
        let place = try ZipDirectory.locate(tail: tail, fileSize: zip.count)
        zip[place.offset] = 0   // the central header's signature
        #expect(throws: ArchiveError.damaged) {
            try ZipDirectory.parse(zip.subdata(in: place.offset..<(place.offset + place.size)))
        }
    }

    @Test func emptyArchiveHasNoEntries() throws {
        #expect(try directory(ZipFixture.make([])).entries.isEmpty)
    }

    @Test func directoryEntryFlagged() throws {
        let zip = ZipFixture.make([.init(name: "caps/", data: Data(), method: 0)])
        #expect(try directory(zip).entries[0].isDirectory)
    }

    @Test func dataOffsetSkipsTheLocalHeader() throws {
        let zip = ZipFixture.make([.init(name: "caps/01.jpg", data: Data([9, 9]), method: 0)])
        let entry = try directory(zip).entries[0]
        let header = zip.subdata(in: 0..<ZipDirectory.localHeaderLength)
        #expect(try ZipDirectory.dataOffset(localHeader: header, entry: entry) == 30 + 11)
        #expect(throws: ArchiveError.damaged) { try ZipDirectory.dataOffset(localHeader: Data(count: 30), entry: entry) }
    }

    @Test func hugeZip64FieldsAreDamagedNotATrap() throws {
        var zip = ZipFixture.make([.init(name: "a.jpg", data: Data([1]), method: 0)], zip64: true)
        // The ZIP64 end record's directory offset (8 bytes at record + 48) set to 2^63 + 1.
        let tail = Data(zip.suffix(min(zip.count, ZipDirectory.tailLength)))
        let record = zip.count - 22 - 20 - 56
        #expect(record >= 0 && tail.count == zip.count)
        for i in 0..<8 { zip[record + 48 + i] = i == 7 ? 0x80 : (i == 0 ? 1 : 0) }
        #expect(throws: ArchiveError.damaged) { try ZipDirectory.locate(tail: zip, fileSize: zip.count) }
    }

    @Test func absurdEntrySizeIsDamaged() throws {
        // A 10-byte deflated entry claiming 3 GB: refused before anything is allocated.
        var zip = ZipFixture.make([.init(name: "a.jpg", data: ZipFixture.bytes(10))])
        let place = try ZipDirectory.locate(tail: zip, fileSize: zip.count)
        for (i, b) in [UInt8(0x00), 0x00, 0x00, 0xC0].enumerated() { zip[place.offset + 24 + i] = b }
        let d = try ZipDirectory.parse(zip.subdata(in: place.offset..<(place.offset + place.size)))
        #expect(throws: ArchiveError.damaged) { try ZipDirectory.checkSizes(d.entries[0]) }
    }
}
