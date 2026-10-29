// A Core ML object detector (the custom detector's model, docs/detector.md) under Vision: how long it takes per photo
// and what it finds, before detector.conf is written.
//
//   swiftc -O ModelBench.swift -o modelbench
//   modelbench <model.mlmodelc> <folder> [--units all|cpu|gpu] [--size PX] [--out DIR] [--crops]
//
// Each photo is decoded as Loupe's Vision proxy (long side --size, default 1536) and looked at whole; with --crops,
// also on each person Vision finds (VNDetectHumanRectanglesRequest), the model seeing that crop at its own input size.
// Times are wall clock per request after a warm-up, on one thread, at .utility. TSV on stdout; with --out, the proxy
// with the boxes drawn. Read-only for the photos.

import CoreGraphics
import CoreML
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

var args = CommandLine.arguments.dropFirst()
var units = "all", size = 1536, out: String?, crops = false, positional: [String] = []
while let a = args.popFirst() {
    switch a {
    case "--units": units = args.popFirst() ?? units
    case "--size": size = args.popFirst().flatMap(Int.init) ?? size
    case "--out": out = args.popFirst()
    case "--crops": crops = true
    default: positional.append(a)
    }
}
guard positional.count == 2 else { fail("usage: modelbench <model.mlmodelc> <folder> [--units all|cpu|gpu] [--size PX] [--out DIR] [--crops]") }

let config = MLModelConfiguration()
config.computeUnits = ["cpu": .cpuOnly, "gpu": .cpuAndGPU, "ane": .cpuAndNeuralEngine][units] ?? .all
let loadStart = Date()
guard let ml = try? MLModel(contentsOf: URL(fileURLWithPath: positional[0]), configuration: config),
      let model = try? VNCoreMLModel(for: ml) else { fail("cannot load \(positional[0])") }
let loadMs = Date().timeIntervalSince(loadStart) * 1000

let files = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: positional[1]), includingPropertiesForKeys: nil)) ?? [])
    .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
if files.isEmpty { fail("no photos") }
if let out { try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true) }

struct Hit { let label: String; let score: Float; let rect: CGRect; let crop: Bool }   // rect: normalised, top-left

/// The model on `region` (normalised, Vision's bottom-left) of `image`; hits in the whole image's top-left space.
func detect(_ image: CGImage, region: CGRect?) -> (hits: [Hit], ms: Double) {
    let request = VNCoreMLRequest(model: model)
    request.imageCropAndScaleOption = .scaleFit
    if let region { request.regionOfInterest = region }
    let handler = VNImageRequestHandler(cgImage: image)
    let t = Date()
    try? handler.perform([request])
    let ms = Date().timeIntervalSince(t) * 1000
    let r = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    let hits = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { o -> Hit? in
        guard let top = o.labels.first else { return nil }
        let b = o.boundingBox   // normalised to the region, bottom-left
        let whole = CGRect(x: r.minX + b.minX * r.width, y: r.minY + b.minY * r.height, width: b.width * r.width, height: b.height * r.height)
        return Hit(label: top.identifier, score: top.confidence,
                   rect: CGRect(x: whole.minX, y: 1 - whole.maxY, width: whole.width, height: whole.height), crop: region != nil)
    }
    return (hits, ms)
}

func people(_ image: CGImage) -> [CGRect] {
    let request = VNDetectHumanRectanglesRequest()
    request.upperBodyOnly = false
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).filter { $0.confidence > 0.3 }.map(\.boundingBox)
}

func proxy(_ url: URL) -> CGImage? {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                                      kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary)
}

/// A saturated colour at `hue` (0…1).
@Sendable func colour(_ hue: Double) -> CGColor {
    let h = hue * 6, x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
    let (r, g, b): (Double, Double, Double) = switch Int(h) % 6 {
    case 0: (1, x, 0)
    case 1: (x, 1, 0)
    case 2: (0, 1, x)
    case 3: (0, x, 1)
    case 4: (x, 0, 1)
    default: (1, 0, x)
    }
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}

func draw(_ image: CGImage, hits: [Hit], persons: [CGRect], to url: URL) {
    let k = min(1, 1024 / Double(max(image.width, image.height)))
    let w = Int(Double(image.width) * k), h = Int(Double(image.height) * k)
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    c.setLineWidth(2); c.setLineDash(phase: 0, lengths: [5, 4]); c.setStrokeColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
    for p in persons { c.stroke(CGRect(x: p.minX * Double(w), y: p.minY * Double(h), width: p.width * Double(w), height: p.height * Double(h))) }
    c.setLineDash(phase: 0, lengths: [])
    for hit in hits {
        let r = CGRect(x: hit.rect.minX * Double(w), y: (1 - hit.rect.maxY) * Double(h), width: hit.rect.width * Double(w), height: hit.rect.height * Double(h))
        // A colour per label, the same on every photo.
        let hue = Double(hit.label.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) / 360
        c.setLineWidth(hit.crop ? 2 : 3)
        c.setStrokeColor(colour(hue))
        c.stroke(r)
        let text = "\(hit.label.lowercased()) \(String(format: "%.2f", hit.score))\(hit.crop ? " c" : "")"
        let attrs = [kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1),
                     kCTFontAttributeName: CTFontCreateWithName("Menlo-Bold" as CFString, 12, nil)] as CFDictionary
        c.setFillColor(CGColor(gray: 0, alpha: 0.7))
        c.fill(CGRect(x: r.minX, y: r.maxY - 15, width: Double(text.count) * 7.3 + 4, height: 15))
        c.textPosition = CGPoint(x: r.minX + 2, y: r.maxY - 12)
        CTLineDraw(CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs)), c)
    }
    guard let img = c.makeImage(), let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(d)
}

// Measured on .utility, as Loupe's subject finder runs.
let done = DispatchSemaphore(value: 0)
DispatchQueue.global(qos: .utility).async {
    var wholeMs: [Double] = [], cropMs: [Double] = [], personMs: [Double] = []
    if let first = files.first.flatMap(proxy) { _ = detect(first, region: nil) }   // warm-up: the first request compiles for the device
    print("# model \(positional[0]) units \(units) load \(String(format: "%.0f", loadMs)) ms")
    print("file\tsource\tlabel\tscore\tx\ty\tw\th")
    for url in files {
        guard let image = proxy(url) else { continue }
        var (hits, ms) = detect(image, region: nil)
        wholeMs.append(ms)
        var persons: [CGRect] = []
        if crops {
            let t = Date(); persons = people(image); personMs.append(Date().timeIntervalSince(t) * 1000)
            for p in persons {
                // A little room round the person, square-ish crops suit a square input.
                let r = p.insetBy(dx: -p.width * 0.05, dy: -p.height * 0.05).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let (more, cms) = detect(image, region: r)
                cropMs.append(cms); hits += more
            }
        }
        for hit in hits {
            print(String(format: "%@\t%@\t%@\t%.2f\t%.3f\t%.3f\t%.3f\t%.3f", url.lastPathComponent, hit.crop ? "crop" : "whole", hit.label,
                         hit.score, hit.rect.minX, hit.rect.minY, hit.rect.width, hit.rect.height))
        }
        if hits.isEmpty { print("\(url.lastPathComponent)\tnone") }
        if let out { draw(image, hits: hits, persons: persons, to: URL(fileURLWithPath: out).appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".jpg")) }
    }
    func stats(_ name: String, _ v: [Double]) {
        guard !v.isEmpty else { return }
        let s = v.sorted()
        print(String(format: "# %@: n %d, median %.1f ms, p90 %.1f ms, max %.1f ms", name, s.count, s[s.count / 2], s[min(s.count - 1, s.count * 9 / 10)], s.last!))
    }
    stats("whole", wholeMs); stats("person detection", personMs); stats("crop", cropMs)
    done.signal()
}
done.wait()
