import CoreGraphics
import Foundation
import ImageIO
import LoupeCore
import QuartzCore

// LoupeBench subjects [--limit N] [--size PX] <folder>
//
// The analysis of smart zoom's `SubjectFinder` (smart zoom spec §5, §7), one photo after another, off the app: a
// proxy of at most --size px (default 1536, `SubjectFinder.proxySide`) made with ImageIO from the photo, oriented, then
// `SubjectDetector.boxes` with the cheap requests (chain face, person, saliency) and, apart, the costly foreground
// mask (chain object). Prints the median, p90 and max of each over the photos and what was found; the first photo is
// reported apart (Vision's warm-up). Read-only; --limit N takes the first N files in name order.

enum SubjectsBench {
    static func main(_ arguments: [String]) -> Never {
        var size = 1536, limit = Int.max
        var folder: String?
        var args = arguments[...]
        while let arg = args.popFirst() {
            switch arg {
            case "--size": size = args.popFirst().flatMap(Int.init) ?? size
            case "--limit": limit = args.popFirst().flatMap(Int.init) ?? limit
            default: folder = arg
            }
        }
        guard let folder else { fail("usage: LoupeBench subjects [--limit N] [--size PX] <folder>") }
        let dir = URL(fileURLWithPath: folder)
        let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let files = Array(all.prefix(limit))
        if files.isEmpty { fail("no photos in \(dir.path)") }
        var cheap: [Double] = [], object: [Double] = []
        var withFace = 0, withPerson = 0, withObject = 0
        for url in files {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: size,
                  ] as CFDictionary) else { print("skipped \(url.lastPathComponent)"); continue }
            var t0 = CACurrentMediaTime()
            guard let boxes = SubjectDetector.boxes(from: image, chain: [.face, .person, .saliency]) else { continue }
            cheap.append((CACurrentMediaTime() - t0) * 1000)
            t0 = CACurrentMediaTime()
            let objects = SubjectDetector.boxes(from: image, chain: [.object]) ?? boxes
            object.append((CACurrentMediaTime() - t0) * 1000)
            if !boxes.faces.isEmpty { withFace += 1 }
            if !boxes.people.isEmpty { withPerson += 1 }
            if !objects.objects.isEmpty { withObject += 1 }
        }
        func row(_ name: String, _ ms: [Double]) -> String {
            let rest = ms.dropFirst().sorted()
            guard !rest.isEmpty else { return "| \(name) | \(String(format: "%.0f", ms.first ?? 0)) | – | – | – |" }
            let p = { (q: Double) in rest[min(rest.count - 1, Int(Double(rest.count - 1) * q))] }
            return String(format: "| %@ | %.0f | %.0f | %.0f | %.0f |", name, ms[0], p(0.5), p(0.9), rest.last!)
        }
        print("\(cheap.count) photos, proxy ≤ \(size) px; faces in \(withFace), people in \(withPerson), objects in \(withObject)")
        print("| request | first (warm-up), ms | median, ms | p90, ms | max, ms |")
        print("|---|---|---|---|---|")
        print(row("face + person + saliency", cheap))
        print(row("foreground mask (object)", object))
        exit(0)
    }
}
