import Testing
@testable import LoupeCore

// The software half float of Intel Macs (Half.swift); on Apple Silicon `Half` is `Float16` and needs no tests.
#if arch(x86_64)
@Test func halfRoundTripsEveryValue() {
    for bits in UInt16.min...UInt16.max {
        let half = Half(bitPattern: bits)
        let float = Float(half)
        if float.isNaN { continue }
        #expect(Half(float).bitPattern == bits, "0x\(String(bits, radix: 16)) → \(float)")
    }
}

@Test func halfRoundsLikeTheHardware() {
    #expect(Half(1).bitPattern == 0x3c00)
    #expect(Half(-2).bitPattern == 0xc000)
    #expect(Half(0.5).bitPattern == 0x3800)
    #expect(Half(65504).bitPattern == 0x7bff)        // largest finite
    #expect(Half(65520).bitPattern == 0x7c00)        // halfway to the next: to even, which is infinity
    #expect(Half(Float(1) + 0x1p-11).bitPattern == 0x3c00)   // halfway between 1 and its successor: to even
    #expect(Half(Float(1) + 0x1p-11 + 0x1p-20).bitPattern == 0x3c01)
    #expect(Half(Float(0x1p-24)).bitPattern == 0x0001)       // smallest subnormal
    #expect(Half(Float(0x1p-25)).bitPattern == 0x0000)       // halfway to it: to even, zero
    #expect(Half(Float(1e-7)).bitPattern == 0x0002)
    #expect(Half(Float.infinity).bitPattern == 0x7c00)
    #expect(Float(Half(Float.nan)).isNaN)
}
#endif
