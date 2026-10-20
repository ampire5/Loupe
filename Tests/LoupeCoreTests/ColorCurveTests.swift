import Testing
import CoreGraphics
import Foundation
@testable import LoupeCore

private func space(_ name: CFString) -> CGColorSpace { CGColorSpace(name: name)! }

private func tables(_ curve: ColorCurve) -> (forward: [Float], inverse: [Float])? {
    if case .table(let forward, let inverse) = curve { return (forward, inverse) }
    return nil
}

@Test func srgbAndP3AreSrgb() {
    #expect(ColorCurve.of(space(CGColorSpace.sRGB)) == .srgb)
    #expect(ColorCurve.of(space(CGColorSpace.displayP3)) == .srgb)
}

/// macOS's Adobe RGB (1998) profile stores gamma 2.2 (the standard says 563/256 = 2.19921875, 1.3e-4 apart).
@Test func adobeRGBTableMatchesGamma22() throws {
    let t = try #require(tables(ColorCurve.of(space(CGColorSpace.adobeRGB1998))))
    #expect(t.forward.count == 256 && t.inverse.count == 4096)
    for code in 0..<256 {
        let expected = powf(Float(code) / 255, 2.2)
        #expect(abs(t.forward[code] - expected) < 1e-4, "code \(code): \(t.forward[code]) vs \(expected)")
    }
}

@Test func proPhotoTableMatchesGamma18() throws {
    let t = try #require(tables(ColorCurve.of(space(CGColorSpace.rommrgb))))
    for code in 0..<256 {
        let expected = powf(Float(code) / 255, 1.8)   // macOS's ROMM RGB profile is a pure 1.8 gamma: no linear toe
        #expect(abs(t.forward[code] - expected) < 1e-4, "code \(code): \(t.forward[code]) vs \(expected)")
    }
}

@Test func inverseRoundTrips() throws {
    for name in [CGColorSpace.adobeRGB1998, CGColorSpace.rommrgb] {
        let curve = ColorCurve.of(space(name))
        _ = try #require(tables(curve))
        for code in 0..<256 {
            let back = curve.encode(curve.decode(Float(code) / 255)) * 255
            #expect(abs(back - Float(code)) < 0.05, "\(name) code \(code) came back as \(back)")
        }
    }
}

@Test func linearSpaceIsIdentityTable() throws {
    let t = try #require(tables(ColorCurve.of(space(CGColorSpace.linearSRGB))))
    for code in 0..<256 { #expect(abs(t.forward[code] - Float(code) / 255) < 1e-4) }
    let curve = ColorCurve.table(forward: t.forward, inverse: t.inverse)
    for light in stride(from: Float(0), through: 1, by: 1.0 / 64) {
        #expect(abs(curve.encode(light) - light) < 1e-3, "light \(light)")
    }
}

@Test func srgbCurveEncodesAndDecodesAsTheSrgbFormula() {
    #expect(abs(ColorCurve.srgb.decode(0.5) - 0.214041) < 1e-5)
    #expect(abs(ColorCurve.srgb.encode(0.214041) - 0.5) < 1e-5)
    #expect(abs(ColorCurve.srgb.encode(2) - 1) < 1e-6 && ColorCurve.srgb.decode(-1) == 0)
}

@Test func nonRGBSpacesAreSrgb() {
    #expect(ColorCurve.of(space(CGColorSpace.genericGrayGamma2_2)) == .srgb)
    #expect(ColorCurve.of(space(CGColorSpace.genericCMYK)) == .srgb)
}

@Test func embeddedSrgbProfileIsSrgb() throws {
    let icc = try #require(space(CGColorSpace.sRGB).copyICCData())
    #expect(ColorCurve.of(try #require(CGColorSpace(iccData: icc))) == .srgb)
}

@Test func inverseSpansZeroToOne() throws {
    for name in [CGColorSpace.adobeRGB1998, CGColorSpace.rommrgb, CGColorSpace.linearSRGB] {
        let t = try #require(tables(ColorCurve.of(space(name))))
        #expect(t.inverse.first == 0 && t.inverse.last == 1)
        #expect(t.inverse.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}

@Test func helpersMapNaNToZero() throws {
    let curve = ColorCurve.of(space(CGColorSpace.adobeRGB1998))
    #expect(curve.decode(.nan) == 0 && curve.encode(.nan) == 0)
    #expect(ColorCurve.srgb.decode(.nan) == 0 && ColorCurve.srgb.encode(.nan) == 0)
}

/// `space`'s ICC profile made unnamed (CoreGraphics names the system sRGB and P3 profiles it recognises in their own
/// data, which the named fast path of `ColorCurve.of` takes): profile ID (bytes 84-99) cleared, CMM type (byte 4)
/// changed, the curves kept.
private func unnamed(_ space: CGColorSpace) throws -> CGColorSpace {
    let data = NSMutableData(data: try #require(space.copyICCData()) as Data)
    let bytes = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
    for i in 84..<100 { bytes[i] = 0 }
    bytes[4] ^= 0x20
    return try #require(CGColorSpace(iccData: data as CFData))
}

@Test func unnamedProfilesAreComparedWithinTheTolerance() throws {
    // The tolerance path: unnamed sRGB and P3 profiles match the sRGB curve, an unnamed Adobe RGB one does not.
    for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
        let profile = try unnamed(space(name))
        #expect(profile.name == nil, "\(name)")
        #expect(ColorCurve.of(profile) == .srgb, "\(name)")
    }
    let adobe = try unnamed(space(CGColorSpace.adobeRGB1998))
    #expect(adobe.name == nil && tables(ColorCurve.of(adobe)) != nil)
}
