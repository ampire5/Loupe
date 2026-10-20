import Foundation
import Testing
@testable import LoupeCore

/// Ss (spectral selection start) of every SOS marker, in file order, found by a plain byte scan
/// for FF DA. A false hit inside entropy data is impossible (FF is always stuffed as FF 00 there).
private func scanStarts(_ data: Data) -> [(offset: Int, ss: UInt8)] {
    let bytes = [UInt8](data)
    var result: [(Int, UInt8)] = []
    var i = 0
    while i + 1 < bytes.count {
        if bytes[i] == 0xFF, bytes[i + 1] == 0xDA {
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let components = Int(bytes[i + 4])
            result.append((i, bytes[i + 4 + 1 + components * 2]))
            i += 2 + length
        } else {
            i += 1
        }
    }
    return result
}

@Test func dcPrefixEndsBeforeFirstACScan() throws {
    let data = TestJPEGs.gradient(width: 256, height: 192, progressive: true)
    let scans = scanStarts(data)
    #expect(scans.count > 1)
    let offset = try #require(JPEGScans.endOfDCScans(data))
    #expect(data[offset] == 0xFF && data[offset + 1] == 0xDA)
    #expect(scans.first { $0.offset == offset }?.ss ?? 0 > 0)
    #expect(scans.filter { $0.offset < offset }.allSatisfy { $0.ss == 0 })
    #expect(scans.contains { $0.offset < offset })
}

@Test func nilForBaseline() {
    let data = TestJPEGs.gradient(width: 256, height: 192, progressive: false)
    #expect(JPEGScans.endOfDCScans(data) == nil)
}

@Test func mainImageEndWithTrailer() {
    let original = TestJPEGs.gradient(width: 64, height: 48, progressive: true)
    var data = original
    data.append(Data(repeating: 0x41, count: 200 * 1024))
    #expect(JPEGScans.mainImageEnd(data) == original.count)
}

@Test func mainImageEndNilWhenTruncated() {
    let data = TestJPEGs.gradient(width: 256, height: 192, progressive: true)
    #expect(JPEGScans.mainImageEnd(data.prefix(data.count / 2)) == nil)
    #expect(JPEGScans.mainImageEnd(data) == data.count)
}

/// Camera JPEGs carry a whole thumbnail JPEG (with its own EOI) in APP1; a byte search for FF D9
/// would call a truncated main image complete.
@Test func mainImageEndSkipsThumbnailEOI() {
    let original = TestJPEGs.gradient(width: 512, height: 512)
    let thumbnail = Data([0xFF, 0xD8, 0x12, 0x34, 0x56, 0xFF, 0xD9])
    let length = 2 + thumbnail.count
    var data = original.prefix(2)
    data.append(contentsOf: [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)])
    data.append(thumbnail)
    data.append(original.dropFirst(2))
    #expect(JPEGScans.mainImageEnd(data) == data.count)
    #expect(JPEGScans.mainImageEnd(data.prefix(data.count * 6 / 10)) == nil)
}
