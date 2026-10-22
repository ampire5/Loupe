import CoreGraphics
import simd
import Testing
@testable import LoupeCore

private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
private let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
private let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998)!

private func near(_ a: simd_float3x3, _ b: simd_float3x3, _ eps: Float) -> Bool {
    (0..<3).allSatisfy { c in (0..<3).allSatisfy { r in abs(a[c][r] - b[c][r]) <= eps } }
}

/// sRGB's linear light in Display P3's: the textbook matrix of the two D65 spaces' primaries.
private let srgbToP3 = simd_float3x3(rows: [SIMD3(0.8225, 0.1774, 0.0000),
                                            SIMD3(0.0332, 0.9669, 0.0000),
                                            SIMD3(0.0171, 0.0724, 0.9108)])

@Test func samePageSpacesNeedNothing() {
    for space in [srgb, p3, adobe] {
        let pair = PairColorSpace(first: space, second: CGColorSpace(name: space.name!)!)
        #expect(pair.layer == nil && pair.first == nil && pair.second == nil)
    }
    let one = PairColorSpace(first: srgb, second: nil)
    #expect(one.layer == nil && one.first == nil && one.second == nil)
}

@Test func srgbBesideP3IsShownInP3() {
    let pair = PairColorSpace(first: srgb, second: p3)
    #expect(pair.layer == p3)
    #expect(pair.second == nil)
    let m = try! #require(pair.first)
    #expect(near(m, srgbToP3, 2e-3), "\(m)")
    // White stays white (both D65).
    let white = m * SIMD3<Float>(1, 1, 1)
    #expect(abs(white.x - 1) < 1e-3 && abs(white.y - 1) < 1e-3 && abs(white.z - 1) < 1e-3)
    let swapped = PairColorSpace(first: p3, second: srgb)
    #expect(swapped.layer == p3 && swapped.first == nil && swapped.second != nil)
}

/// Neither in Display P3: both pages go there.
@Test func unorderedPairGoesToP3() {
    let pair = PairColorSpace(first: adobe, second: srgb)
    #expect(pair.layer == p3)
    #expect(pair.first != nil && pair.second != nil)
    // Adobe RGB's green lies outside P3: a negative red in P3's linear light.
    let green = pair.first! * SIMD3<Float>(0, 1, 0)
    #expect(green.x < 0)
}

@Test func matrixToItselfIsIdentity() {
    let m = try! #require(PairColorSpace.matrix(from: p3, to: p3))
    #expect(near(m, matrix_identity_float3x3, 1e-4))
}
