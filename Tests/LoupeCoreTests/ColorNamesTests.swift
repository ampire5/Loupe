import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LoupeCore

/// A solid image in `space` (components include the alpha slot when the layout has one), encoded as `type`.
private func solid(_ space: CGColorSpace, components: [CGFloat], alpha: CGImageAlphaInfo, type: UTType,
                   size: Int = 64) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: alpha.rawValue)!
    context.setFillColor(CGColor(colorSpace: space, components: components)!)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return TestJPEGs.encode(context.makeImage()!, type: type)
}

private func rgb(_ name: CFString, type: UTType = .jpeg) -> Data {
    solid(CGColorSpace(name: name)!, components: [0.5, 0.3, 0.2, 1], alpha: .noneSkipFirst, type: type)
}

private func gray(type: UTType = .jpeg) -> Data {
    solid(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, components: [0.5, 1], alpha: .none, type: type)
}

private func cmykJPEG() -> Data {
    solid(CGColorSpaceCreateDeviceCMYK(), components: [0.2, 0.4, 0.1, 0.1, 1], alpha: .none, type: .jpeg)
}

/// `iccData` with the 'desc' tag renamed, so the profile has no description (the tag table has no checksum).
private func withoutDescription(_ iccData: Data) -> Data {
    var bytes = iccData
    let count = Int(bytes[128]) << 24 | Int(bytes[129]) << 16 | Int(bytes[130]) << 8 | Int(bytes[131])
    for i in 0..<count {
        let entry = 132 + 12 * i
        if Array(bytes[entry..<entry + 4]) == Array("desc".utf8) { bytes.replaceSubrange(entry..<entry + 4, with: Array("dscx".utf8)) }
    }
    return bytes
}

private func infoThroughRegistry(_ data: Data) throws -> ImageInfo { try DecoderRegistry.decoder(for: data).probe(data) }

@Test func namesInStats() throws {
    // A JPEG (libjpeg-turbo) and a PNG (ImageIO) say the same thing for the same profile.
    for (space, expected) in [(CGColorSpace.sRGB, "sRGB"), (CGColorSpace.displayP3, "Display P3"),
                              (CGColorSpace.adobeRGB1998, "Adobe RGB (1998)"), (CGColorSpace.rommrgb, "ProPhoto RGB")] {
        #expect(try infoThroughRegistry(rgb(space)).colorSpaceName == expected, "jpeg \(space)")
        #expect(try infoThroughRegistry(rgb(space, type: .png)).colorSpaceName == expected, "png \(space)")
    }
    #expect(try infoThroughRegistry(cmykJPEG()).colorSpaceName == "CMYK → Display P3")
    #expect(try infoThroughRegistry(gray()).colorSpaceName == "Gray → Display P3")
    #expect(try infoThroughRegistry(gray(type: .png)).colorSpaceName == "Gray → Display P3")
}

@Test func profileDescriptionNamesAnUnknownProfile() throws {
    // A camera's own profile has no CF name: its ICC description is the name.
    let wide = CGColorSpace(name: CGColorSpace.itur_2020)!
    let named = CGColorSpace(iccData: wide.copyICCData()!)!
    let data = solid(named, components: [0.5, 0.3, 0.2, 1], alpha: .noneSkipFirst, type: .jpeg)
    #expect(try infoThroughRegistry(data).colorSpaceName == "Rec. ITU-R BT.2020-1")
}

@Test func nameOfAProfileWithoutOneIsUnnamed() throws {
    // Adobe RGB's profile with its 'desc' tag renamed: no description, and (as ICC data) no CF name.
    let icc = withoutDescription(CGColorSpace(name: CGColorSpace.adobeRGB1998)!.copyICCData()! as Data)
    let resolved = EmbeddedColorSpace.resolve(iccData: icc)
    #expect(resolved.space.model == .rgb)
    #expect(resolved.name == "ICC (unnamed)")
    // And the same through the probe: ICC data in a JPEG's APP2 chunk is what libjpeg-turbo reads.
    let space = try #require(CGColorSpace(iccData: icc as CFData))
    let data = solid(space, components: [0.5, 0.3, 0.2, 1], alpha: .noneSkipFirst, type: .jpeg)
    #expect(try infoThroughRegistry(data).colorSpaceName == "ICC (unnamed)")
}

@Test func probeAgreesWithDecode() throws {
    let cases: [(String, Data)] = [("cmyk jpeg", cmykJPEG()), ("gray jpeg", gray()), ("gray png", gray(type: .png)),
                                   ("adobe jpeg", rgb(CGColorSpace.adobeRGB1998)), ("p3 png", rgb(CGColorSpace.displayP3, type: .png)),
                                   ("untagged jpeg", TestJPEGs.halves(width: 64, height: 64))]
    for (label, data) in cases {
        let decoder = DecoderRegistry.decoder(for: data)
        let info = try decoder.probe(data)
        let probed = try #require(info.colorSpace, "\(label)")
        for image in [try decoder.decodeFull(data, info: info), try decoder.preview(data, info: info, level: 1).image] {
            #expect(probed.copyICCData() as Data? == image.colorSpace.copyICCData() as Data?, "\(label): probe and decode differ")
            #expect(EmbeddedColorSpace.displayName(of: probed) == EmbeddedColorSpace.displayName(of: image.colorSpace), "\(label)")
        }
    }
    #expect(try infoThroughRegistry(cmykJPEG()).colorSpace?.name as String? == CGColorSpace.displayP3 as String)
    #expect(try infoThroughRegistry(gray()).colorSpace?.name as String? == CGColorSpace.displayP3 as String)
}

@Test func catalogueKeepsTheNameNotTheSpace() throws {
    let info = try infoThroughRegistry(cmykJPEG())
    #expect(info.colorSpace != nil)
    #expect(info.catalogued.colorSpace == nil && info.catalogued.colorSpaceName == "CMYK → Display P3")
}

@Test func statsShowTheReadableNameOfASpace() {
    for (name, expected) in [(CGColorSpace.sRGB, "sRGB"), (CGColorSpace.displayP3, "Display P3"),
                             (CGColorSpace.adobeRGB1998, "Adobe RGB (1998)"), (CGColorSpace.rommrgb, "ProPhoto RGB")] {
        #expect(EmbeddedColorSpace.displayName(of: CGColorSpace(name: name)!) == expected)
    }
}

@Test func noCFConstantReachesTheStats() {
    let names: [CFString] = [CGColorSpace.itur_2100_PQ, CGColorSpace.itur_2100_HLG, CGColorSpace.displayP3_PQ,
                             CGColorSpace.displayP3_HLG, CGColorSpace.extendedSRGB, CGColorSpace.extendedLinearSRGB,
                             CGColorSpace.extendedLinearDisplayP3, CGColorSpace.extendedDisplayP3, CGColorSpace.linearSRGB,
                             CGColorSpace.extendedITUR_2020, CGColorSpace.extendedLinearITUR_2020, CGColorSpace.linearITUR_2020,
                             CGColorSpace.itur_709, CGColorSpace.dcip3, CGColorSpace.acescgLinear, CGColorSpace.genericRGBLinear]
    for name in names {
        guard let space = CGColorSpace(name: name) else { continue }
        let shown = EmbeddedColorSpace.displayName(of: space)
        #expect(!shown.contains("kCGColorSpace"), "\(name) shows as \(shown)")
    }
    #expect(EmbeddedColorSpace.displayName(of: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!) == "Rec. 2100 PQ")
    #expect(EmbeddedColorSpace.displayName(of: CGColorSpace(name: CGColorSpace.itur_2100_HLG)!) == "Rec. 2100 HLG")
    #expect(EmbeddedColorSpace.displayName(of: CGColorSpace(name: CGColorSpace.displayP3_PQ)!) == "Display P3 PQ")
}

@Test func aGrayProfileOnRGBPixelsIsNotConvertedToP3() {
    // libjpeg-turbo hands RGB pixels: a gray profile does not describe them, so it keeps the earlier reading (sRGB).
    let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!.copyICCData()! as Data
    #expect(EmbeddedColorSpace.resolve(iccData: gray).name == "sRGB")
    #expect(EmbeddedColorSpace.resolve(iccData: gray).space.name as String? == CGColorSpace.sRGB as String)
    #expect(EmbeddedColorSpace.resolve(iccData: gray, convertsGray: true).name == "Gray → Display P3")
}

// MARK: - ICCDescription on hostile input

private func realProfiles() -> [Data] {
    [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.adobeRGB1998, CGColorSpace.itur_2020, CGColorSpace.linearSRGB,
     CGColorSpace.genericGrayGamma2_2].compactMap { CGColorSpace(name: $0)?.copyICCData() as Data? }
}

@Test func iccDescriptionNeverTrapsOnTruncatedProfiles() {
    for profile in realProfiles() {
        #expect(ICCDescription.read(profile) != nil)
        for length in 0...profile.count {
            _ = ICCDescription.read(profile.prefix(length))                       // a slice of the same storage, too
            _ = ICCDescription.read(Data(profile.prefix(length)))
        }
    }
}

@Test func iccDescriptionNeverTrapsOnMutatedProfiles() {
    var state: UInt64 = 0x9E3779B97F4A7C15
    func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(state >> 33) % bound
    }
    for profile in realProfiles() {
        for _ in 0..<3000 {
            var bytes = profile
            for _ in 0..<(1 + next(6)) {
                // Mostly the header and tag table, where the offsets and lengths are; sometimes anywhere.
                let index = next(4) == 0 ? next(bytes.count) : 120 + next(min(bytes.count - 120, 600))
                bytes[index] = [0, 0xFF, 0x80, UInt8(next(256))][next(4)]
            }
            _ = ICCDescription.read(bytes)
        }
    }
}

/// A profile of just a header (zeroed), a one-entry tag table and one 'desc' tag holding `tag`.
private func profile(descriptionTag tag: [UInt8]) -> Data {
    func be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    return Data([UInt8](repeating: 0, count: 128) + be(1) + Array("desc".utf8) + be(144) + be(tag.count) + tag)
}

private func utf16(_ text: String) -> [UInt8] { text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] } }

@Test func iccDescriptionPicksTheEnglishRecordEvenWhenItIsNotFirst() {
    func be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    let german = utf16("Hallo"), english = utf16("Hello")
    // Records: lang, country, byte length, offset from the tag's start; the strings follow the records (16 + 24 = 40).
    let tag = Array("mluc".utf8) + be(0) + be(2) + be(12)
        + Array("deDE".utf8) + be(german.count) + be(40)
        + Array("enUS".utf8) + be(english.count) + be(40 + german.count) + german + english
    #expect(ICCDescription.read(profile(descriptionTag: tag)) == "Hello")
}

@Test func iccDescriptionToleratesAnOddLengthString() {
    func be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    let text = utf16("Hi!") + [0x00]   // 7 bytes: a stray half code unit at the end
    let tag = Array("mluc".utf8) + be(0) + be(1) + be(12) + Array("enUS".utf8) + be(text.count) + be(28) + text
    #expect(ICCDescription.read(profile(descriptionTag: tag)) == "Hi!")
    // A record that points outside its tag is refused, not read.
    let outside = Array("mluc".utf8) + be(0) + be(1) + be(12) + Array("enUS".utf8) + be(64) + be(28) + text
    #expect(ICCDescription.read(profile(descriptionTag: outside)) == nil)
}

@Test func iccDescriptionStopsAtTheFirstNul() {
    func be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    // A v2 'desc' whose count covers "Camera" NUL "garbage" NUL: only the text before the first NUL is the name.
    let text = Array("Camera".utf8) + [0] + Array("garbage".utf8) + [0]
    let tag = Array("desc".utf8) + be(0) + be(text.count) + text
    #expect(ICCDescription.read(profile(descriptionTag: tag)) == "Camera")
    // Nothing before the NUL: no name.
    let leading = [0] + Array("Camera".utf8) + [0] + Array("garbage".utf8)   // as long as `text`: the count fits the tag
    let empty = Array("desc".utf8) + be(0) + be(leading.count) + leading
    #expect(ICCDescription.read(profile(descriptionTag: empty)) == nil)
}
