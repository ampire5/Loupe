import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LoupeCore

/// What ImageIO reports for `data`, through the same mapping the decoders use.
private func imageIOOrientation(_ data: Data) -> ImageOrientation? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    return ImageIODecoder.orientation(of: properties)
}

/// An APP1 segment (marker, length, payload) with `payload` as its content.
private func app1(_ payload: [UInt8]) -> [UInt8] {
    let length = payload.count + 2
    return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
}

/// An Exif APP1 with a hand-built TIFF block in the given byte order: IFD0 holding `entries` (tag, type, count,
/// value), values inline.
private func exifSegment(little: Bool, entries: [(tag: Int, type: Int, count: Int, value: Int)]) -> [UInt8] {
    func u16(_ v: Int) -> [UInt8] { little ? [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] : [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    func u32(_ v: Int) -> [UInt8] { little ? u16(v & 0xFFFF) + u16(v >> 16) : u16(v >> 16) + u16(v & 0xFFFF) }
    var tiff: [UInt8] = (little ? [0x49, 0x49] : [0x4D, 0x4D]) + u16(42) + u32(8) + u16(entries.count)
    for e in entries { tiff += u16(e.tag) + u16(e.type) + u32(e.count) + u16(e.value) + [0, 0] }
    tiff += u32(0)
    return app1([0x45, 0x78, 0x69, 0x66, 0, 0] + tiff)
}

/// `jpeg` with `segment` inserted right after SOI.
private func inserting(_ segment: [UInt8], into jpeg: Data) -> Data {
    Data(jpeg.prefix(2)) + Data(segment) + Data(jpeg.dropFirst(2))
}

/// `jpeg` without its APP1 segments (and any other APPn, to be safe), the rest untouched.
private func strippingApp(_ jpeg: Data) -> Data {
    var out = Data(jpeg.prefix(2))
    var i = 2
    while i + 4 <= jpeg.count, jpeg[i] == 0xFF {
        let marker = jpeg[i + 1], length = Int(jpeg[i + 2]) << 8 | Int(jpeg[i + 3])
        if marker == 0xDA { break }
        if !(0xE0...0xEF).contains(marker) { out.append(jpeg[i..<(i + 2 + length)]) }
        i += 2 + length
    }
    return out + jpeg[i...]
}

@Test func exifReaderAgreesWithImageIOForEveryOrientation() {
    for orientation in ImageOrientation.allCases {
        let data = TestJPEGs.pattern(orientation: orientation.rawValue)
        #expect(JPEGExif.orientation(data) == imageIOOrientation(data), "\(orientation)")
        // ImageIO writes the tag whenever it is not 1; for 1 it may leave it out, which reads as up as well.
        #expect(JPEGExif.orientation(data) == orientation, "\(orientation)")
    }
}

@Test func exifReaderReadsBothByteOrders() {
    let plain = strippingApp(TestJPEGs.pattern())
    for little in [true, false] {
        for orientation in ImageOrientation.allCases {
            let segment = exifSegment(little: little, entries: [(0x0100, 3, 1, 7), (0x0112, 3, 1, orientation.rawValue)])
            let data = inserting(segment, into: plain)
            #expect(JPEGExif.orientation(data) == orientation, "\(little ? "II" : "MM") \(orientation)")
            #expect(imageIOOrientation(data) == orientation, "ImageIO \(little ? "II" : "MM") \(orientation)")
        }
    }
}

@Test func exifReaderMapsValuesOutsideOneToEightToUp() {
    let plain = strippingApp(TestJPEGs.pattern())
    for value in [0, 9, 255, 0xFFFF] {
        for little in [true, false] {
            let data = inserting(exifSegment(little: little, entries: [(0x0112, 3, 1, value)]), into: plain)
            #expect(JPEGExif.orientation(data) == .up, "\(value)")
            #expect(imageIOOrientation(data) == .up, "ImageIO \(value)")
        }
    }
}

@Test func exifReaderWithoutExifIsUp() {
    let plain = strippingApp(TestJPEGs.pattern())
    #expect(JPEGExif.orientation(plain) == .up)
    // An Exif block whose IFD0 has no orientation tag.
    #expect(JPEGExif.orientation(inserting(exifSegment(little: true, entries: [(0x0100, 3, 1, 5)]), into: plain)) == .up)
    // An empty IFD0.
    #expect(JPEGExif.orientation(inserting(exifSegment(little: false, entries: []), into: plain)) == .up)
    #expect(JPEGExif.orientation(TestJPEGs.pattern(orientation: nil)) == .up)
}

@Test func exifReaderSkipsXMPAndOtherAPP1() {
    let plain = strippingApp(TestJPEGs.pattern())
    let xmp = app1(Array("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta tiff:Orientation=\"6\"/>".utf8))
    #expect(JPEGExif.orientation(inserting(xmp, into: plain)) == .up)
    // XMP first, then the Exif one: the Exif one is found.
    let exif = exifSegment(little: false, entries: [(0x0112, 3, 1, 8)])
    #expect(JPEGExif.orientation(inserting(xmp + exif, into: plain)) == .left)
    // APP0 and a COM in front of it.
    let app0: [UInt8] = [0xFF, 0xE0, 0, 7, 0x4A, 0x46, 0x49, 0x46, 0]
    let com: [UInt8] = [0xFF, 0xFE, 0, 4, 0x68, 0x69]
    #expect(JPEGExif.orientation(inserting(app0 + com + exif, into: plain)) == .left)
    // A fill byte before a marker is allowed.
    #expect(JPEGExif.orientation(inserting([0xFF] + exif, into: plain)) == .left)
}

@Test func exifReaderOnASliceWithANonZeroStartIndex() throws {
    let data = TestJPEGs.pattern(orientation: 6)
    let padded = Data([1, 2, 3, 4, 5]) + data + Data([9, 9])
    let slice = padded[5..<(5 + data.count)]
    try #require(slice.startIndex == 5)
    #expect(JPEGExif.orientation(slice) == .right)
    #expect(JPEGExif.orientation(padded[6...]) == nil)   // not at SOI any more
}

@Test func exifReaderRejectsWhatItDoesNotUnderstand() {
    let plain = strippingApp(TestJPEGs.pattern())
    #expect(JPEGExif.orientation(Data()) == nil)
    #expect(JPEGExif.orientation(Data([0xFF, 0xD8])) == nil)
    #expect(JPEGExif.orientation(Data("not a jpeg at all".utf8)) == nil)
    // Orientation entry that is not a single SHORT.
    #expect(JPEGExif.orientation(inserting(exifSegment(little: true, entries: [(0x0112, 4, 1, 6)]), into: plain)) == nil)
    #expect(JPEGExif.orientation(inserting(exifSegment(little: true, entries: [(0x0112, 3, 2, 6)]), into: plain)) == nil)
    // Wrong TIFF magic, wrong byte-order mark.
    var bad = exifSegment(little: true, entries: [(0x0112, 3, 1, 6)])
    bad[10 + 2] = 43
    #expect(JPEGExif.orientation(inserting(bad, into: plain)) == nil)
    bad = exifSegment(little: true, entries: [(0x0112, 3, 1, 6)])
    bad[10] = 0x58
    #expect(JPEGExif.orientation(inserting(bad, into: plain)) == nil)
    // A segment length that runs past the data, one that is below 2.
    #expect(JPEGExif.orientation(Data([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 0, 0])) == nil)
    #expect(JPEGExif.orientation(Data([0xFF, 0xD8, 0xFF, 0xE1, 0, 1, 0, 0])) == nil)
    // IFD offset pointing outside the block, huge entry count.
    var far = exifSegment(little: true, entries: [(0x0112, 3, 1, 6)])
    far[10 + 4] = 0xFF
    #expect(JPEGExif.orientation(inserting(far, into: plain)) == nil)
    var many = exifSegment(little: true, entries: [(0x0112, 3, 1, 6)])
    many[10 + 8] = 0xFF; many[10 + 9] = 0xFF
    #expect(JPEGExif.orientation(inserting(many, into: plain)) == nil)
    // More segments than the walk allows.
    let comments = Array([[UInt8]](repeating: [0xFF, 0xFE, 0, 2], count: JPEGExif.maxSegments + 1).joined())
    #expect(JPEGExif.orientation(inserting(comments, into: plain)) == nil)
}

@Test func exifReaderNeverTrapsOnTruncation() {
    for little in [true, false] {
        let exif = exifSegment(little: little, entries: [(0x0100, 3, 1, 5), (0x0112, 3, 1, 6)])
        let data = inserting(exif, into: strippingApp(TestJPEGs.pattern()))
        let whole = JPEGExif.orientation(data)
        #expect(whole == .right)
        // Cut at every byte of the first 2 KB (the whole header, then well into the scan data).
        for cut in 0..<min(data.count, 2048) {
            let result = JPEGExif.orientation(data.prefix(cut))
            // A cut before the APP1 ends, or inside it, is unrecognised; later cuts still find the tag.
            if cut < exif.count + 2 { #expect(result == nil, "cut \(cut)") } else { #expect(result == whole, "cut \(cut)") }
        }
    }
    // ImageIO's own file as well: whatever the cut, no trap, and a result is either right or nil.
    let data = TestJPEGs.pattern(orientation: 8)
    for cut in 0..<min(data.count, 2048) {
        let result = JPEGExif.orientation(data.prefix(cut))
        #expect(result == nil || result == .left, "cut \(cut)")
    }
    // Every single-byte corruption of the first 2 KB: no trap.
    var copy = data
    for i in 0..<min(copy.count, 2048) {
        let saved = copy[i]
        for value: UInt8 in [0x00, 0xFF, 0x80] { copy[i] = value; _ = JPEGExif.orientation(copy) }
        copy[i] = saved
    }
}
