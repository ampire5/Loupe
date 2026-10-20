import CoreGraphics
import Darwin
import Foundation
import ImageIO
import LoupeCore
import LoupeRender
import UniformTypeIdentifiers

// LoupeBench autocolour [--generate N] [--limit N] [--size PX] <folder>
//
// The work of the window's colour corrector (M3c spec §3, §8), one photo after another, off the app: a thumbnail of
// at most --size px (default 512, the strip's) made with ImageIO from the JPEG, `AutoColorAnalyzer.analyse` on it,
// `ColorLUTBuilder.cube` (auto colour on, method apple, threshold 0 so that every photo that can be analysed gets a
// cube) and `ColorLUT.make` (the upload to a 3D texture). Prints the median and max of each step over the photos;
// the first photo is reported apart: it carries Core Image's and Metal's warm-up.
// --limit N takes only the first N files in name order (read-only; a folder of real photos may be given).
// --generate N first writes N synthetic JPEGs of 4000x3000 (gradients of varied colours, a few blobs and noise) into
// the folder, which must be empty or missing. Never point it at the user's photo folders to generate.

enum AutoColourBench {
    static let usage = "usage: LoupeBench autocolour [--generate N] [--limit N] [--size PX] <folder>"

    static func main(_ arguments: [String]) -> Never {
        var generate = 0, size = 512, limit = Int.max
        var folder: String?
        var args = arguments[...]
        while let arg = args.popFirst() {
            switch arg {
            case "--generate":
                guard let v = args.popFirst(), let n = Int(v), n > 0 else { fail("--generate needs a positive integer") }
                generate = n
            case "--limit":
                guard let v = args.popFirst(), let n = Int(v), n > 0 else { fail("--limit needs a positive integer") }
                limit = n
            case "--size":
                guard let v = args.popFirst(), let n = Int(v), n >= 16 else { fail("--size needs an integer >= 16") }
                size = n
            case _ where arg.hasPrefix("--"): fail("unknown option \(arg)\n\(usage)")
            default:
                guard folder == nil else { fail(usage) }
                folder = arg
            }
        }
        guard let folder else { fail(usage) }
        let dir = URL(fileURLWithPath: folder)
        if generate > 0 { Self.generate(generate, into: dir) }
        run(dir, size: size, limit: limit)
        exit(0)
    }

    // MARK: - Measurement

    private static func run(_ dir: URL, size: Int, limit: Int) {
        let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let files = Array(all.prefix(limit))
        if files.isEmpty { fail("no JPEG files in \(dir.path)") }
        let settings = ColorSettings(autoColor: true, method: .apple, strength: 1,
                                     filters: Set(AutoColorFilter.allCases), vibranceGain: 1,
                                     threshold: 0, full: 0, vibrance: false, vibranceAmount: 0.5)
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double { d / .milliseconds(1) }
        var thumb: [Double] = [], analysis: [Double] = [], cube: [Double] = [], upload: [Double] = []
        var tooDark = 0, noCube = 0
        for url in files {
            var t = clock.now
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: size,
                  ] as CFDictionary) else { print("skipped \(url.lastPathComponent): no thumbnail"); continue }
            thumb.append(ms(clock.now - t))
            t = clock.now
            let made = AutoColorAnalyzer.analyse(image)
            analysis.append(ms(clock.now - t))
            if made.tooDark { tooDark += 1 }
            let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            t = clock.now
            let built = ColorLUTBuilder.cube(analysis: made, settings: settings, colorSpace: space)
            cube.append(ms(clock.now - t))
            guard let built else { noCube += 1; continue }
            t = clock.now
            let lut = ColorLUT.make(built)
            upload.append(ms(clock.now - t))
            if lut == nil { print("upload failed: \(url.lastPathComponent)") }
        }
        print("\(files.count) JPEG, thumbnail ≤ \(size) px, \(tooDark) too dark to analyse, \(noCube) without a cube")
        print("| step | first (warm-up) | median of the rest | max of the rest | min of the rest |")
        print("|---|---|---|---|---|")
        func row(_ name: String, _ values: [Double]) {
            guard let first = values.first else { return }
            let rest = Array(values.dropFirst()).sorted()
            guard !rest.isEmpty else { print("| \(name) | \(f(first)) | - | - | - |"); return }
            let median = rest.count % 2 == 1 ? rest[rest.count / 2] : (rest[rest.count / 2 - 1] + rest[rest.count / 2]) / 2
            print("| \(name) | \(f(first)) | \(f(median)) | \(f(rest.last!)) | \(f(rest.first!)) |")
        }
        row("thumbnail (ImageIO)", thumb)
        row("analysis", analysis)
        row("cube (build)", cube)
        row("upload (ColorLUT.make)", upload)
        let both = zip(cube, upload).map { $0 + $1 }
        row("cube + upload (the corrector's \"cube\" ms)", both)
    }

    private static func f(_ v: Double) -> String { String(format: "%.2f", v) }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("LoupeBench autocolour: \(message)\n".utf8))
        exit(2)
    }

    // MARK: - Test JPEGs

    /// `count` synthetic 4000x3000 sRGB JPEGs in `dir` (made if missing; refused when it already holds files).
    private static func generate(_ count: Int, into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: dir.path), !existing.isEmpty {
            fail("--generate: \(dir.path) is not empty")
        }
        let width = 4000, height = 3000
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for index in 0..<count {
            // Brightness and saturation vary from photo to photo: dark and saturated to pale and flat.
            let brightness = 0.12 + 0.8 * Double(index) / Double(max(1, count - 1))
            let saturation = 0.15 + 0.8 * random()
            let hue = random()
            func colour(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
                let i = Int(h * 6) % 6, fr = h * 6 - floor(h * 6)
                let p = v * (1 - s), q = v * (1 - fr * s), t = v * (1 - (1 - fr) * s)
                switch i {
                case 0: return (v, t, p)
                case 1: return (q, v, p)
                case 2: return (p, v, t)
                case 3: return (p, q, v)
                case 4: return (t, p, v)
                default: return (v, p, q)
                }
            }
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            let a = colour(hue, saturation, min(1, brightness + 0.25))
            let b = colour((hue + 0.35 + 0.3 * random()).truncatingRemainder(dividingBy: 1), saturation,
                           max(0.02, brightness - 0.2))
            let angle = random() * .pi
            let (dx, dy) = (cos(angle), sin(angle))
            // A few soft blobs on top of the gradient.
            let blobs = (0..<5).map { _ in
                (x: random() * Double(width), y: random() * Double(height), r: 300 + 700 * random(),
                 c: colour(random(), saturation, min(1, brightness + 0.3 * random())))
            }
            pixels.withUnsafeMutableBufferPointer { buffer in
                for y in 0..<height {
                    for x in 0..<width {
                        var t = (Double(x) / Double(width) * dx + Double(y) / Double(height) * dy)
                        t = min(1, max(0, t))
                        var r = a.0 + (b.0 - a.0) * t, g = a.1 + (b.1 - a.1) * t, bl = a.2 + (b.2 - a.2) * t
                        for blob in blobs {
                            let ddx = Double(x) - blob.x, ddy = Double(y) - blob.y
                            let w = exp(-(ddx * ddx + ddy * ddy) / (2 * blob.r * blob.r))
                            r += (blob.c.0 - r) * w * 0.7
                            g += (blob.c.1 - g) * w * 0.7
                            bl += (blob.c.2 - bl) * w * 0.7
                        }
                        let noise = (Double(((x &* 73856093) ^ (y &* 19349663)) & 15) - 7.5) / 255
                        let o = (y * width + x) * 4
                        buffer[o] = UInt8(max(0, min(255, (r + noise) * 255)))
                        buffer[o + 1] = UInt8(max(0, min(255, (g + noise) * 255)))
                        buffer[o + 2] = UInt8(max(0, min(255, (bl + noise) * 255)))
                    }
                }
            }
            let context = pixels.withUnsafeMutableBytes {
                CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8,
                          bytesPerRow: width * 4, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            }
            guard let image = context?.makeImage() else { fail("cannot make the test image") }
            let url = dir.appendingPathComponent(String(format: "test%02d.jpg", index + 1))
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { fail("cannot write \(url.path)") }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
        }
        print("generated \(count) JPEG of \(width)x\(height) in \(dir.path)")
    }
}
