import Foundation
import LoupeCore

/// The CPU double-precision reference the `resample` compute kernel is measured against (spec §8): the same
/// separable filter in linear light, with exactly the kernel's tap window and per-axis normalisation, so a PSNR
/// below the rounding floor means the GPU code (alignment, tap window, the slot a tap is read from) is wrong rather
/// than the filter being a different one. Ported from the bench's `check.swift` `reference()`, generalised to the
/// four kernels and the fixed window `b ... b + taps - 1`.
enum ResampleReference {
    /// sRGB byte to linear light (IEC 61966-2-1), what reading the level through its `_srgb` view does.
    static func linear(_ v: UInt8) -> Double { decodeLUT[Int(v)] }

    private static let decodeLUT: [Double] = (0..<256).map { i in
        let c = Double(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Linear light to an sRGB byte, rounded to nearest, as the `_srgb` drawable encodes on store.
    static func encode(_ v: Double) -> UInt8 {
        let c = min(max(v, 0), 1)
        let e = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8((e * 255).rounded())
    }

    /// The kernel's weight at distance `x` (in compressed units, `distance * min(1, m)`).
    static func weight(_ kernel: ResampleKernel, _ x: Double) -> Double {
        let a = abs(x)
        switch kernel {
        case .lanczos3, .lanczos2:
            let n = Double(kernel.support)
            if a < 1e-9 { return 1 }
            if a >= n { return 0 }
            let p = Double.pi * a
            return n * sin(p) * sin(p / n) / (p * p)
        case .mitchell, .catmullRom:
            let (b, c) = kernel == .mitchell ? (1.0 / 3, 1.0 / 3) : (0.0, 0.5)
            if a < 1 { return ((12 - 9 * b - 6 * c) * a * a * a + (-18 + 12 * b + 6 * c) * a * a + (6 - 2 * b)) / 6 }
            if a < 2 { return ((-b - 6 * c) * a * a * a + (6 * b + 30 * c) * a * a + (-12 * b - 48 * c) * a + (8 * b + 24 * c)) / 6 }
            return 0
        }
    }

    /// Taps per axis, as the shader's `RESAMPLE_TAPS`: `2 * support` up, `4 * support` down (`m <= 1`), which
    /// covers the kernel stretched by `1/m` for every `m > 0.5`.
    static func taps(_ kernel: ResampleKernel, m: Double) -> Int { kernel.support * (m > 1 ? 2 : 4) }

    /// Renders a `viewWidth` x `viewHeight` frame of a `width` x `height` level whose pixel (x, y) is `source(x, y)`
    /// (linear RGB), drawn at `m` view px per level px with level px 0 at view `offset`. Pixels whose centre lies
    /// outside the image's view rect `[offset, offset + extent * m)` get `background` (linear). Taps outside the
    /// level clamp to its edge. Returns BGRA sRGB bytes, alpha 255, row-major.
    /// `phase` moves the level's texel grid against the image: texel i has its centre at image position
    /// `i + 0.5 - phase` level px (an odd-size level mirrored about the image's extent starts half a px before it).
    /// `antiringing` (magnifying only) clamps each output to the range of the 2 x 2 texels around its sample point.
    /// `curve` encodes the image's pixels (the photo's transfer curve, M3b spec §4; sRGB by default); the background is
    /// always sRGB-encoded, as the renderer writes it.
    static func render(source: (Int, Int) -> (Double, Double, Double), width: Int, height: Int, kernel: ResampleKernel,
                       m: Double, offset: SIMD2<Double>, extent: SIMD2<Double>, viewWidth: Int, viewHeight: Int,
                       background: (Double, Double, Double), phase: SIMD2<Double> = .zero,
                       antiringing: Bool = false, curve: (Double) -> UInt8 = encode) -> [UInt8] {
        let rgb = filter(source: source, width: width, height: height, kernel: kernel, m: m, offset: offset,
                         viewWidth: viewWidth, viewHeight: viewHeight, phase: phase, antiringing: antiringing)
        return encodeFrame(rgb, offset: offset, extent: extent, m: m, viewWidth: viewWidth, viewHeight: viewHeight,
                           background: background, curve: curve)
    }

    /// `render` for a photo with alpha (M3b spec §3): `source` is premultiplied linear RGB, `alpha` its alpha, both
    /// filtered alike (as one RGBA texel in the shader); a pixel inside the image is `rgb + (1 - a) * backdrop(x, y)`
    /// (view px, alpha not clamped, as the shader composites), outside it `background`.
    static func renderComposite(source: (Int, Int) -> (Double, Double, Double), alpha: (Int, Int) -> Double,
                                width: Int, height: Int, kernel: ResampleKernel, m: Double, offset: SIMD2<Double>,
                                extent: SIMD2<Double>, viewWidth: Int, viewHeight: Int,
                                background: (Double, Double, Double),
                                backdrop: (Int, Int) -> (Double, Double, Double),
                                curve: (Double) -> UInt8 = encode) -> [UInt8] {
        let rgb = filter(source: source, width: width, height: height, kernel: kernel, m: m, offset: offset,
                         viewWidth: viewWidth, viewHeight: viewHeight, phase: .zero, antiringing: false)
        let a = filter(source: { x, y in let v = alpha(x, y); return (v, v, v) }, width: width, height: height,
                       kernel: kernel, m: m, offset: offset, viewWidth: viewWidth, viewHeight: viewHeight, phase: .zero,
                       antiringing: false)
        return encodeFrame(composite(rgb, alpha: a, viewWidth: viewWidth, backdrop: backdrop), offset: offset,
                           extent: extent, m: m, viewWidth: viewWidth, viewHeight: viewHeight, background: background,
                           curve: curve)
    }

    /// `filtered` (linear RGB, 3 per view px) with each pixel composited over `backdrop`: `rgb + (1 - a) * back`, `a`
    /// from `alpha` (filtered alike, its first channel).
    static func composite(_ filtered: [Double], alpha: [Double], viewWidth: Int,
                          backdrop: (Int, Int) -> (Double, Double, Double)) -> [Double] {
        var out = filtered
        for p in 0..<(filtered.count / 3) {
            let back = backdrop(p % viewWidth, p / viewWidth), t = 1 - alpha[p * 3]
            out[p * 3] += t * back.0; out[p * 3 + 1] += t * back.1; out[p * 3 + 2] += t * back.2
        }
        return out
    }

    /// Linear RGB (3 per view px, row-major) to BGRA bytes encoded by `curve`, alpha 255; pixels whose centre lies
    /// outside the image's view rect `[offset, offset + extent * m)` get `background` (linear, sRGB-encoded).
    static func encodeFrame(_ rgb: [Double], offset: SIMD2<Double>, extent: SIMD2<Double>, m: Double, viewWidth: Int,
                            viewHeight: Int, background: (Double, Double, Double),
                            curve: (Double) -> UInt8 = encode) -> [UInt8] {
        let x0 = offset.x, x1 = offset.x + extent.x * m, y0 = offset.y, y1 = offset.y + extent.y * m
        var out = [UInt8](repeating: 255, count: viewWidth * viewHeight * 4)
        for y in 0..<viewHeight {
            let cy = Double(y) + 0.5
            for x in 0..<viewWidth {
                let cx = Double(x) + 0.5, o = (y * viewWidth + x) * 4, i = (y * viewWidth + x) * 3
                if cx >= x0 && cx < x1 && cy >= y0 && cy < y1 {
                    out[o] = curve(rgb[i + 2]); out[o + 1] = curve(rgb[i + 1]); out[o + 2] = curve(rgb[i])
                } else {
                    out[o] = encode(background.2); out[o + 1] = encode(background.1); out[o + 2] = encode(background.0)
                }
            }
        }
        return out
    }

    /// The separable filter of `render` over every view pixel (inside the image or not), linear RGB, 3 per pixel.
    static func filter(source: (Int, Int) -> (Double, Double, Double), width: Int, height: Int, kernel: ResampleKernel,
                       m: Double, offset: SIMD2<Double>, viewWidth: Int, viewHeight: Int, phase: SIMD2<Double>,
                       antiringing: Bool) -> [Double] {
        let n = taps(kernel, m: m), k = min(1, m)
        /// First tap of view coordinate `o` on an axis whose level px 0 is at `off`, and its normalised weights
        /// (written to `w[o * n ..< o * n + n]`). Flat buffers and unsafe pointers below: the tests run unoptimised,
        /// where nested arrays make this reference cost tens of CPU seconds per suite.
        func windows(_ count: Int, _ off: Double, _ phase: Double) -> (first: [Int], weights: [Double]) {
            var first = [Int](repeating: 0, count: count), weights = [Double](repeating: 0, count: count * n)
            for o in 0..<count {
                let c = (Double(o) + 0.5 - off) / m - 0.5 + phase
                let b = Int(c.rounded(.down)) - n / 2 + 1
                var s = 0.0
                for t in 0..<n {
                    let w = weight(kernel, (Double(b + t) - c) * k)
                    weights[o * n + t] = w
                    s += w
                }
                for t in 0..<n { weights[o * n + t] /= s }
                first[o] = b
            }
            return (first, weights)
        }
        let (bx, wx) = windows(viewWidth, offset.x, phase.x), (by, wy) = windows(viewHeight, offset.y, phase.y)
        var linearSource = [Double](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let p = source(x, y), o = (y * width + x) * 3
                linearSource[o] = p.0; linearSource[o + 1] = p.1; linearSource[o + 2] = p.2
            }
        }

        // Horizontal pass for every level row the vertical pass needs (clamped into the level), row r at
        // rows[(r - rowMin) * viewWidth * 3 ...].
        let rowMin = by.min()!, rowMax = by.max()! + n - 1, stride = viewWidth * 3
        var rows = [Double](repeating: 0, count: (rowMax - rowMin + 1) * stride)
        rows.withUnsafeMutableBufferPointer { rows in
            linearSource.withUnsafeBufferPointer { src in
                wx.withUnsafeBufferPointer { wx in
                    for r in rowMin...rowMax {
                        let line = (r - rowMin) * stride, sy = min(max(r, 0), height - 1) * width
                        for x in 0..<viewWidth {
                            var acc = (0.0, 0.0, 0.0)
                            for t in 0..<n {
                                let wt = wx[x * n + t], o = (sy + min(max(bx[x] + t, 0), width - 1)) * 3
                                acc.0 += wt * src[o]; acc.1 += wt * src[o + 1]; acc.2 += wt * src[o + 2]
                            }
                            rows[line + x * 3] = acc.0; rows[line + x * 3 + 1] = acc.1; rows[line + x * 3 + 2] = acc.2
                        }
                    }
                }
            }
        }

        var out = [Double](repeating: 0, count: viewWidth * viewHeight * 3)
        rows.withUnsafeBufferPointer { rows in
            wy.withUnsafeBufferPointer { wy in
                for y in 0..<viewHeight {
                    for x in 0..<viewWidth {
                        let o = (y * viewWidth + x) * 3
                        var rgb = (0.0, 0.0, 0.0)
                        do {
                            for t in 0..<n {
                                let wt = wy[y * n + t], i = (by[y] + t - rowMin) * stride + x * 3
                                rgb.0 += wt * rows[i]; rgb.1 += wt * rows[i + 1]; rgb.2 += wt * rows[i + 2]
                            }
                            if antiringing, m > 1 {
                                // floor(c) and floor(c) + 1 per axis (the first tap plus n/2 - 1), clamped into the
                                // level.
                                let fx = bx[x] + n / 2 - 1, fy = by[y] + n / 2 - 1
                                var lo = (Double.infinity, Double.infinity, Double.infinity), hi = (-lo.0, -lo.1, -lo.2)
                                for (tx, ty) in [(fx, fy), (fx + 1, fy), (fx, fy + 1), (fx + 1, fy + 1)] {
                                    let o = (min(max(ty, 0), height - 1) * width + min(max(tx, 0), width - 1)) * 3
                                    let p = (linearSource[o], linearSource[o + 1], linearSource[o + 2])
                                    lo = (min(lo.0, p.0), min(lo.1, p.1), min(lo.2, p.2))
                                    hi = (max(hi.0, p.0), max(hi.1, p.1), max(hi.2, p.2))
                                }
                                rgb = (min(max(rgb.0, lo.0), hi.0), min(max(rgb.1, lo.1), hi.1),
                                       min(max(rgb.2, lo.2), hi.2))
                            }
                        }
                        out[o] = rgb.0; out[o + 1] = rgb.1; out[o + 2] = rgb.2
                    }
                }
            }
        }
        return out
    }

    /// PSNR in dB over the RGB channels of two BGRA frames of equal size, counting only the pixels for which
    /// `mask(x, y)` holds (all when nil). `width` is the frame width, needed to turn byte offsets into (x, y).
    /// Identical frames give `.infinity`.
    static func psnr(_ a: [UInt8], _ b: [UInt8], width: Int, mask: ((Int, Int) -> Bool)? = nil) -> Double {
        precondition(a.count == b.count && a.count % (width * 4) == 0)
        var se = 0.0, n = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            let p = i / 4
            if let mask, !mask(p % width, p / width) { continue }
            for ch in 0..<3 {
                let d = Double(a[i + ch]) - Double(b[i + ch])
                se += d * d
                n += 1
            }
        }
        precondition(n > 0, "psnr: the mask selects no pixel")
        return se == 0 ? .infinity : 10 * log10(255 * 255 / (se / n))
    }
}

/// The radial mode: EWA Lanczos (mpv's `ewa_lanczossharp`, M3a spec §3.7), written from the formula with libm's
/// double `j1` and no table, so it checks both the shader's tap window and `MetalContext`'s weight LUT.
extension ResampleReference {
    /// Third zero of J1 over π: the kernel radius before blur.
    static let ewaRadius = 3.2383154841662362
    /// First zero of J1 over π: the window's radius (where jinc first reaches 0).
    static let ewaFirstZero = 1.2196698912665045
    static let ewaBlur = 0.9812505644269356
    /// Taps reach this far (level px): the kernel's radius after blur.
    static var ewaCutoff: Double { ewaRadius * ewaBlur }

    /// `2 J1(π x) / (π x)`, 1 at 0.
    static func jinc(_ x: Double) -> Double {
        if abs(x) < 1e-12 { return 1 }
        let p = Double.pi * x
        return 2 * j1(p) / p
    }

    /// The EWA weight at distance `r` (level px): jinc(r / b) windowed by jinc stretched to the blurred radius, 0 from
    /// that radius on.
    static func ewaWeight(_ r: Double) -> Double {
        let r = abs(r)
        guard r < ewaCutoff else { return 0 }
        return jinc(r / ewaBlur) * jinc(r / (ewaBlur * ewaRadius / ewaFirstZero))
    }

    /// `render` for EWA Lanczos (magnifying only, `m > 1`): each view pixel sums, in linear light, every level texel
    /// whose centre lies within `ewaCutoff` of the sample point (they all lie in the 7 x 7 square around the nearest
    /// texel), weights normalised to sum 1, taps outside the level clamped to its edge; `antiringing` clamps to the
    /// range of the 2 x 2 texels around the sample point. Same arguments and output as `render`.
    static func renderEWA(source: (Int, Int) -> (Double, Double, Double), width: Int, height: Int, m: Double,
                          offset: SIMD2<Double>, extent: SIMD2<Double>, viewWidth: Int, viewHeight: Int,
                          background: (Double, Double, Double), antiringing: Bool = false,
                          curve: (Double) -> UInt8 = encode) -> [UInt8] {
        let rgb = filterEWA(source: source, width: width, height: height, m: m, offset: offset, viewWidth: viewWidth,
                            viewHeight: viewHeight, antiringing: antiringing)
        return encodeFrame(rgb, offset: offset, extent: extent, m: m, viewWidth: viewWidth, viewHeight: viewHeight,
                           background: background, curve: curve)
    }

    /// `renderComposite` for EWA Lanczos.
    static func renderEWAComposite(source: (Int, Int) -> (Double, Double, Double), alpha: (Int, Int) -> Double,
                                   width: Int, height: Int, m: Double, offset: SIMD2<Double>, extent: SIMD2<Double>,
                                   viewWidth: Int, viewHeight: Int, background: (Double, Double, Double),
                                   backdrop: (Int, Int) -> (Double, Double, Double),
                                   curve: (Double) -> UInt8 = encode) -> [UInt8] {
        let rgb = filterEWA(source: source, width: width, height: height, m: m, offset: offset, viewWidth: viewWidth,
                            viewHeight: viewHeight, antiringing: false)
        let a = filterEWA(source: { x, y in let v = alpha(x, y); return (v, v, v) }, width: width, height: height,
                          m: m, offset: offset, viewWidth: viewWidth, viewHeight: viewHeight, antiringing: false)
        return encodeFrame(composite(rgb, alpha: a, viewWidth: viewWidth, backdrop: backdrop), offset: offset,
                           extent: extent, m: m, viewWidth: viewWidth, viewHeight: viewHeight, background: background,
                           curve: curve)
    }

    /// The radial filter of `renderEWA` over every view pixel, linear RGB, 3 per pixel.
    static func filterEWA(source: (Int, Int) -> (Double, Double, Double), width: Int, height: Int, m: Double,
                          offset: SIMD2<Double>, viewWidth: Int, viewHeight: Int, antiringing: Bool) -> [Double] {
        precondition(m > 1, "EWA Lanczos only magnifies")
        var linearSource = [Double](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let p = source(x, y), o = (y * width + x) * 3
                linearSource[o] = p.0; linearSource[o + 1] = p.1; linearSource[o + 2] = p.2
            }
        }
        let cutoff = ewaCutoff
        var out = [Double](repeating: 0, count: viewWidth * viewHeight * 3)
        linearSource.withUnsafeBufferPointer { src in
            func texel(_ x: Int, _ y: Int) -> Int { (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 3 }
            for y in 0..<viewHeight {
                let cy = (Double(y) + 0.5 - offset.y) / m - 0.5, ny = Int((cy + 0.5).rounded(.down))
                for x in 0..<viewWidth {
                    let o = (y * viewWidth + x) * 3
                    let cx = (Double(x) + 0.5 - offset.x) / m - 0.5, nx = Int((cx + 0.5).rounded(.down))
                    var acc = (0.0, 0.0, 0.0), sum = 0.0
                    for ty in (ny - 3)...(ny + 3) {
                        for tx in (nx - 3)...(nx + 3) {
                            let dx = Double(tx) - cx, dy = Double(ty) - cy
                            let r = (dx * dx + dy * dy).squareRoot()
                            guard r < cutoff else { continue }
                            let w = ewaWeight(r), i = texel(tx, ty)
                            acc.0 += w * src[i]; acc.1 += w * src[i + 1]; acc.2 += w * src[i + 2]
                            sum += w
                        }
                    }
                    var rgb = (acc.0 / sum, acc.1 / sum, acc.2 / sum)
                    if antiringing {
                        let fx = Int(cx.rounded(.down)), fy = Int(cy.rounded(.down))
                        let near = [texel(fx, fy), texel(fx + 1, fy), texel(fx, fy + 1), texel(fx + 1, fy + 1)]
                        func clamped(_ v: Double, _ ch: Int) -> Double {
                            let values = near.map { src[$0 + ch] }
                            return min(max(v, values.min()!), values.max()!)
                        }
                        rgb = (clamped(rgb.0, 0), clamped(rgb.1, 1), clamped(rgb.2, 2))
                    }
                    out[o] = rgb.0; out[o + 1] = rgb.1; out[o + 2] = rgb.2
                }
            }
        }
        return out
    }
}
