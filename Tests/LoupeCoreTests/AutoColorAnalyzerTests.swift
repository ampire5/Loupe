import Testing
import Foundation
import CoreGraphics
import CoreImage
@testable import LoupeCore

/// A generated sRGB image: `pixel(x, y)` gives 0...255 R, G, B.
private func makeImage(width: Int = 128, height: Int = 128, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            let i = (y * width + x) * 4
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

// M3c spec §3.1: a nearly black photo is not analysed at all.
@Test func blackIsTooDark() {
    let analysis = AutoColorAnalyzer.analyse(makeImage(width: 64, height: 64) { _, _ in (0, 0, 0) })
    #expect(analysis.tooDark)
    #expect(analysis.steps.isEmpty)
    #expect(analysis.delta == 0)
}

// A dull picture (low contrast, low saturation, a slight tint) gets Apple's steps and changes by more than 0.
@Test func dullImageGetsSteps() {
    let image = makeImage { x, y in
        let t = Double(x) / 127
        let base = 90 + 70 * t
        return (UInt8(base + 12), UInt8(base + 4 + 6 * Double(y) / 127), UInt8(base - 8))
    }
    let analysis = AutoColorAnalyzer.analyse(image)
    #expect(!analysis.tooDark)
    #expect(!analysis.steps.isEmpty)
    #expect(analysis.delta > 0)
    #expect(!analysis.steps.contains { $0.name == "CIFaceBalance" })
    #expect(analysis.steps.allSatisfy { AutoColorFilter(filterName: $0.name) == $0.kind })
}

// Spec §3.1: shadows and highlights with a radius are spatial and cannot go into a LUT.
@Test func shadowsWithRadiusDropped() {
    let curve = AutoColorStep(name: "CIToneCurve", kind: .curve, parameters: [:])
    let radial = AutoColorStep(name: "CIHighlightShadowAdjust", kind: .shadows,
                               parameters: ["inputShadowAmount": NSNumber(value: 0.4), "inputRadius": NSNumber(value: 5)])
    let flat = AutoColorStep(name: "CIHighlightShadowAdjust", kind: .shadows,
                             parameters: ["inputShadowAmount": NSNumber(value: 0.4), "inputRadius": NSNumber(value: 0)])
    let vibrance = AutoColorStep(name: "CIVibrance", kind: .vibrance, parameters: ["inputAmount": NSNumber(value: 0.1)])
    let kept = AutoColorAnalyzer.withoutSpatialSteps([curve, radial, flat, vibrance])
    #expect(kept.map(\.name) == ["CIToneCurve", "CIHighlightShadowAdjust", "CIVibrance"])
    #expect(kept[1].parameters["inputRadius"] as? NSNumber == 0)
    // The analysis counts what it dropped, for the corrector's log.
    let sample = CIImage(cgImage: makeImage(width: 16, height: 16) { x, _ in (UInt8(x * 16), 100, 90) })
    let analysis = AutoColorAnalyzer.analysis(of: sample, steps: [curve, radial, flat, vibrance])
    #expect(analysis.steps.count == 3)
    #expect(analysis.droppedSpatialSteps == 1)
    #expect(AutoColorAnalyzer.analysis(of: sample, steps: [curve, flat]).droppedSpatialSteps == 0)
}

// Review focus 2: an edited file is another file.
@Test func cacheKeyedByStamp() {
    let cache = AutoColorCache()
    let url = URL(fileURLWithPath: "/tmp/a.jpg")
    let stamp = FileStamp(modified: Date(timeIntervalSinceReferenceDate: 1000), size: 10)
    let other = FileStamp(modified: Date(timeIntervalSinceReferenceDate: 2000), size: 10)
    cache.store(AutoColorAnalysis(steps: [], delta: 7, tooDark: false), for: url, stamp: stamp)
    #expect(cache.analysis(for: url, stamp: stamp)?.delta == 7)
    #expect(cache.analysis(for: url, stamp: other) == nil)
    #expect(cache.analysis(for: URL(fileURLWithPath: "/tmp/b.jpg"), stamp: stamp) == nil)
}

@Test func cacheEvicts() {
    let cache = AutoColorCache(capacity: 2)
    let stamp = FileStamp(modified: Date(timeIntervalSinceReferenceDate: 1000), size: 10)
    let urls = (1...3).map { URL(fileURLWithPath: "/tmp/\($0).jpg") }
    for (i, url) in urls.enumerated() {
        cache.store(AutoColorAnalysis(steps: [], delta: Double(i), tooDark: false), for: url, stamp: stamp)
    }
    #expect(cache.analysis(for: urls[0], stamp: stamp) == nil)
    #expect(cache.analysis(for: urls[1], stamp: stamp)?.delta == 1)
    #expect(cache.analysis(for: urls[2], stamp: stamp)?.delta == 2)
    // Storing a key again makes it the newest.
    cache.store(AutoColorAnalysis(steps: [], delta: 9, tooDark: false), for: urls[1], stamp: stamp)
    cache.store(AutoColorAnalysis(steps: [], delta: 4, tooDark: false), for: urls[0], stamp: stamp)
    #expect(cache.analysis(for: urls[2], stamp: stamp) == nil)
    #expect(cache.analysis(for: urls[1], stamp: stamp)?.delta == 9)
}
