/// A half float, the element of `ColorCube` and of `rgba16Float` texels. Swift's `Float16` is unavailable on Intel
/// Macs (lts/macos26), so there it is two bytes with the IEEE 754 binary16 layout and software conversions, rounding
/// to nearest even as the hardware does, and comparing, equality and hashing by value as `Float16`'s (−0 equals 0, NaN
/// equals nothing); on Apple Silicon it is `Float16` itself.
#if arch(x86_64)
public struct Half: Hashable, Comparable, Sendable, ExpressibleByIntegerLiteral {
    public var bitPattern: UInt16

    public static func == (a: Half, b: Half) -> Bool { Float(a) == Float(b) }

    public static func < (a: Half, b: Half) -> Bool { Float(a) < Float(b) }

    public func hash(into hasher: inout Hasher) { hasher.combine(Float(self)) }

    public init(bitPattern: UInt16) { self.bitPattern = bitPattern }

    public init(_ value: Double) { self.init(Float(value)) }

    public init(integerLiteral value: Int) { self.init(Float(value)) }

    public init(_ value: Float) {
        let x = value.bitPattern
        let sign = UInt16(truncatingIfNeeded: (x >> 16) & 0x8000)
        let exponent = Int((x >> 23) & 0xff)
        var mantissa = x & 0x7f_ffff
        if exponent == 0xff {   // infinity, NaN (kept quiet)
            bitPattern = sign | 0x7c00 | (mantissa != 0 ? 0x200 : 0)
            return
        }
        let e = exponent - 127 + 15
        if e >= 0x1f {
            bitPattern = sign | 0x7c00   // too large: infinity
        } else if e <= 0 {
            // Subnormal (or zero): the 24-bit significand shifted down to units of 2^-24.
            guard e >= -10 else { bitPattern = sign; return }
            mantissa |= 0x80_0000
            let shift = UInt32(14 - e)
            var h = mantissa >> shift
            let rest = mantissa & ((1 << shift) - 1), halfway = UInt32(1) << (shift - 1)
            if rest > halfway || (rest == halfway && h & 1 != 0) { h += 1 }
            bitPattern = sign | UInt16(h)
        } else {
            // A carry out of the mantissa raises the exponent, up to infinity: still the correctly rounded value.
            var h = UInt32(e) << 10 | mantissa >> 13
            let rest = mantissa & 0x1fff
            if rest > 0x1000 || (rest == 0x1000 && h & 1 != 0) { h += 1 }
            bitPattern = sign | UInt16(h)
        }
    }
}

extension Float {
    public init(_ half: Half) {
        let sign = UInt32(half.bitPattern & 0x8000) << 16
        let exponent = UInt32((half.bitPattern >> 10) & 0x1f), mantissa = UInt32(half.bitPattern & 0x3ff)
        switch exponent {
        case 0: self = (sign != 0 ? -1 : 1) * Float(mantissa) * 0x1p-24
        case 0x1f: self = Float(bitPattern: sign | 0x7f80_0000 | mantissa << 13)
        default: self = Float(bitPattern: sign | (exponent + 112) << 23 | mantissa << 13)
        }
    }
}

extension Double {
    public init(_ half: Half) { self.init(Float(half)) }
}
#else
public typealias Half = Float16
#endif
