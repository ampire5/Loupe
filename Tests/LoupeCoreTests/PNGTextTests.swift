import Testing
import Foundation
import Compression
import zlib
@testable import LoupeCore

/// Synthetic PNG bytes for the text-chunk reader.
enum PNGFixture {
    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func chunk(_ type: String, _ body: Data) -> Data {
        var out = Data()
        out.append(contentsOf: be32(UInt32(body.count)))
        let typed = Data(type.utf8) + body
        out.append(typed)
        let crc = typed.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(typed.count))) }
        out.append(contentsOf: be32(crc))
        return out
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }

    static func text(_ key: String, _ value: String) -> Data {
        chunk("tEXt", Data(key.utf8) + Data([0]) + Data(value.utf8))
    }

    /// A real zlib stream: header 78 9C, deflate body, Adler-32 trailer.
    static func zlibStream(_ plain: Data) -> Data {
        var body = Data()
        plain.withUnsafeBytes { src in
            let cap = plain.count + 1024
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
            defer { dst.deallocate() }
            let n = compression_encode_buffer(dst, cap, src.bindMemory(to: UInt8.self).baseAddress!, plain.count, nil, COMPRESSION_ZLIB)
            body = Data(bytes: dst, count: n)
        }
        let adler = plain.withUnsafeBytes { UInt32(adler32(1, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(plain.count))) }
        return Data([0x78, 0x9C]) + body + Data(be32(adler))
    }

    static func ztxt(_ key: String, _ value: String) -> Data {
        chunk("zTXt", Data(key.utf8) + Data([0, 0]) + zlibStream(Data(value.utf8)))
    }

    static func itxt(_ key: String, _ value: String, compressed: Bool) -> Data {
        let head = Data(key.utf8) + Data([0, compressed ? 1 : 0, 0]) + Data("en".utf8) + Data([0]) + Data("Key".utf8) + Data([0])
        let body = compressed ? zlibStream(Data(value.utf8)) : Data(value.utf8)
        return chunk("iTXt", head + body)
    }

    static let ihdr = chunk("IHDR", Data(be32(1) + be32(1) + [8, 2, 0, 0, 0]))
    static let idat = chunk("IDAT", Data([1, 2, 3, 4]))
    static let iend = chunk("IEND", Data())
}

@Test func pngTextReadsAllThreeKindsAndStopsAtIDAT() {
    let png = PNGFixture.signature + PNGFixture.ihdr
        + PNGFixture.text("parameters", "a cat\nSteps: 20")
        + PNGFixture.itxt("Comment", "größe ✓", compressed: true)
        + PNGFixture.ztxt("prompt", "{\"1\":{}}")
        + PNGFixture.itxt("Plain", "utf8 ✓", compressed: false)
        + PNGFixture.idat
        + PNGFixture.text("late", "after IDAT")
        + PNGFixture.iend
    let text = PNGText.parse(png)
    #expect(text["parameters"] == "a cat\nSteps: 20")
    #expect(text["Comment"] == "größe ✓")
    #expect(text["prompt"] == "{\"1\":{}}")
    #expect(text["Plain"] == "utf8 ✓")
    #expect(text["late"] == nil)
    #expect(text.count == 4)
}

@Test func pngTextCutsLongTextAt64K() {
    let big = String(repeating: "a", count: 100_000)
    let png = PNGFixture.signature + PNGFixture.ihdr
        + PNGFixture.text("parameters", big) + PNGFixture.ztxt("zbig", big) + PNGFixture.idat
    let text = PNGText.parse(png)
    #expect(text["parameters"]?.utf8.count == 65_536)
    #expect(text["zbig"]?.utf8.count == 65_536)
}

@Test func pngTextTextCutKeepsMultibyteCharactersWhole() {
    // The cut at 65 536 bytes falls inside a two-byte character: the text stays readable UTF-8.
    let s = String(repeating: "a", count: 65_535) + "é" + "tail"
    let png = PNGFixture.signature + PNGFixture.ihdr + PNGFixture.chunk("iTXt", Data("k".utf8) + Data([0, 0, 0, 0, 0]) + Data(s.utf8)) + PNGFixture.idat
    let value = PNGText.parse(png)["k"]
    #expect(value == String(repeating: "a", count: 65_535))
}

@Test func pngTextCompressedTextCutKeepsUTF8() {
    // Compressed iTXt and zTXt: the multibyte character straddles byte 65 536, so the cut drops its first byte
    // instead of turning the whole text to Latin-1.
    let s = String(repeating: "a", count: 65_535) + "é" + "tail" + String(repeating: "b", count: 1_000)
    let png = PNGFixture.signature + PNGFixture.ihdr + PNGFixture.itxt("k", s, compressed: true)
        + PNGFixture.ztxt("z", s) + PNGFixture.idat
    let text = PNGText.parse(png)
    #expect(text["k"] == String(repeating: "a", count: 65_535))
    #expect(text["z"] == String(repeating: "a", count: 65_535))
    // A compressed text of exactly 65 536 bytes is not cut and stays whole.
    let exact = String(repeating: "a", count: 65_534) + "é"
    let whole = PNGText.parse(PNGFixture.signature + PNGFixture.ihdr + PNGFixture.itxt("k", exact, compressed: true) + PNGFixture.idat)
    #expect(whole["k"] == exact)
}

@Test func pngTextLatin1TextWithoutUTF8() {
    let png = PNGFixture.signature + PNGFixture.ihdr
        + PNGFixture.chunk("tEXt", Data("k".utf8) + Data([0, 0x63, 0x61, 0x66, 0xE9])) + PNGFixture.idat
    #expect(PNGText.parse(png)["k"] == "café")
}

@Test func pngTextChunkLengthPastTheEndKeepsWhatWasRead() {
    var png = PNGFixture.signature + PNGFixture.ihdr + PNGFixture.text("parameters", "kept")
    png.append(contentsOf: PNGFixture.be32(5_000_000))
    png.append(Data("tEXt".utf8) + Data("broken".utf8))
    #expect(PNGText.parse(png) == ["parameters": "kept"])
    // A cut in the middle of a chunk body too.
    let whole = PNGFixture.signature + PNGFixture.ihdr + PNGFixture.text("a", "one") + PNGFixture.text("b", "two") + PNGFixture.idat
    let cut = whole.prefix(whole.count - PNGFixture.idat.count - 6)
    #expect(PNGText.parse(Data(cut)) == ["a": "one"])
}

@Test func pngTextBrokenCompressedBodiesAreSkipped() {
    let png = PNGFixture.signature + PNGFixture.ihdr
        + PNGFixture.chunk("zTXt", Data("bad".utf8) + Data([0, 0]) + Data([1, 2, 3]))
        + PNGFixture.chunk("tEXt", Data("nonul".utf8))
        + PNGFixture.text("ok", "fine") + PNGFixture.idat
    #expect(PNGText.parse(png) == ["ok": "fine"])
}

@Test func pngTextNotAPNG() {
    #expect(PNGText.parse(Data()) == [:])
    #expect(PNGText.parse(Data("hello, this is not a png at all".utf8)) == [:])
    #expect(PNGText.parse(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46])) == [:])
}

@Test func pngTextReadFromFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pngtext-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // Text beyond the first 64 KB block, and a huge IDAT that must not be read.
    let png = PNGFixture.signature + PNGFixture.ihdr
        + PNGFixture.chunk("tEXt", Data("filler".utf8) + Data([0]) + Data(repeating: 0x61, count: 150_000))
        + PNGFixture.text("parameters", "far in")
        + PNGFixture.chunk("IDAT", Data(count: 3_000_000)) + PNGFixture.text("late", "x") + PNGFixture.iend
    let url = dir.appendingPathComponent("a.png")
    try png.write(to: url)
    let text = PNGText.read(url)
    #expect(text["parameters"] == "far in")
    #expect(text["filler"]?.utf8.count == 65_536)
    #expect(text["late"] == nil)
    #expect(PNGText.read(dir.appendingPathComponent("missing.png")) == [:])
    // Text only after 8 MB of other chunks is never reached.
    let farUrl = dir.appendingPathComponent("far.png")
    let far = PNGFixture.signature + PNGFixture.ihdr + PNGFixture.chunk("zzZz", Data(count: 9_000_000)) + PNGFixture.text("x", "y") + PNGFixture.idat
    try far.write(to: farUrl)
    #expect(PNGText.read(farUrl) == [:])
}

@Test func pngTextReportsTheTrueLengthOfComfyChunks() {
    let big = String(repeating: "a", count: 100_000)
    let png = PNGFixture.signature + PNGFixture.ihdr
        + PNGFixture.text("workflow", big) + PNGFixture.ztxt("prompt", big + big) + PNGFixture.itxt("other", big, compressed: true) + PNGFixture.idat
    let r = PNGText.scan(png)
    #expect(r.sizes["workflow"] == 100_000 && r.sizes["prompt"] == 200_000)
    #expect(r.sizes["other"] == nil)
    #expect(r.text["workflow"]?.utf8.count == 65_536 && r.text["prompt"]?.utf8.count == 65_536 && r.text["other"]?.utf8.count == 65_536)
}
