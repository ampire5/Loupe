import CoreGraphics
import Foundation
import ImageIO
import LoupeCore

// LoupeBench detector [--conf FILE] [--limit N] <folder>
//
// The custom detector (detector.conf, `DetectorSetup`) on a folder of photos, as Loupe runs it: each photo's 1536 px
// proxy through `SubjectDetector` with the detector, the time it took, the boxes of each class found, and for each mode
// the target its chain chooses (the frame's size as a share of the photo's long side). Read-only for the photos.

enum DetectorBench {
    static func main(_ arguments: [String]) -> Never {
        var conf = DetectorSetup.fileURL, limit = Int.max, folder: String?
        var args = arguments[...]
        while let arg = args.popFirst() {
            switch arg {
            case "--conf": conf = args.popFirst().map { URL(fileURLWithPath: $0) } ?? conf
            case "--limit": limit = args.popFirst().flatMap(Int.init) ?? limit
            default: folder = arg
            }
        }
        guard let folder else { fail("usage: LoupeBench detector [--conf FILE] [--limit N] <folder>") }
        let (setup, warnings) = DetectorSetup.load(from: conf)
        for w in warnings { FileHandle.standardError.write(Data("\(w)\n".utf8)) }
        guard setup.detects else { fail("no model or classes in \(conf.path)") }
        SubjectFraming.detector = DetectorFraming(setup)
        let files = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(limit)
        if files.isEmpty { fail("no photos in \(folder)") }
        let chain = SubjectKind.vision + setup.kinds
        var times: [Double] = [], wins: [String: [String: Int]] = [:]
        print("file\tms\tfound\t" + setup.modes.map(\.name).joined(separator: "\t"))
        for url in files {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1536,
                  ] as CFDictionary) else { continue }
            let start = Date()
            guard let boxes = SubjectDetector.boxes(from: image, chain: chain, detector: setup) else {
                print("\(url.lastPathComponent)\tfailed"); continue
            }
            let ms = Date().timeIntervalSince(start) * 1000
            if url != files.first { times.append(ms) }   // the first loads the model
            let found = setup.kinds.compactMap { k in boxes.boxes(k).isEmpty ? nil : "\(k.rawValue) \(boxes.boxes(k).count)" }
            let chosen = setup.modes.map { mode -> String in
                guard let kind = mode.chain.first(where: { !boxes.boxes($0).isEmpty }),
                      let frame = SubjectFraming.frame(boxes, chain: [kind]) else { return "—" }
                wins[mode.name, default: [:]][kind.rawValue, default: 0] += 1
                return String(format: "%@ %.2f", kind.rawValue, max(frame.width, frame.height))
            }
            print("\(url.lastPathComponent)\t\(String(format: "%.1f", ms))\t\(found.joined(separator: ", "))\t" + chosen.joined(separator: "\t"))
        }
        let sorted = times.sorted()
        if !sorted.isEmpty {
            print(String(format: "# %d photos: median %.1f ms, p90 %.1f ms, max %.1f ms (Vision's kinds and the detector)",
                         sorted.count, sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 9 / 10)], sorted.last!))
        }
        for mode in setup.modes {
            let w = (wins[mode.name] ?? [:]).sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
            print("# \(mode.name): " + w.joined(separator: ", "))
        }
        exit(0)
    }
}
