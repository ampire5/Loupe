import CoreGraphics
import CoreVideo
import Vision

/// Finds a photo's subjects with Vision (smart zoom spec §5), on any thread, synchronously: faces, people (whole
/// bodies), animals and where the eye goes in one pass over the image; the things in front (foreground instances, the
/// costly request) only when the chain reaches `object` and nothing before it was found. Kinds the chain does not name
/// are not looked for. The custom detector's classes with `detector` when the chain names any (`ModelDetector`). The image is a proxy of the oriented photo (`SubjectFinder`), so the boxes are in
/// its space.
public enum SubjectDetector {
    /// Nil when Vision failed (a transient error is not a photo without subjects: nothing is stored for it).
    public static func boxes(from image: CGImage, chain: [SubjectKind], detector: DetectorSetup? = nil) -> SubjectBoxes? {
        let custom = detector != nil && chain.contains { $0.isCustom }
        var boxes = SubjectBoxes(faces: [], people: [], objects: [], saliency: [],
                                 searched: chain.filter { custom || !$0.isCustom })
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        let animals = VNRecognizeAnimalsRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        var requests: [VNRequest] = []
        if chain.contains(.face) { requests.append(faces) }
        if chain.contains(.person) || (custom && detector?.lookPeople == true) { requests.append(people) }
        if chain.contains(.object) { requests.append(animals) }
        if chain.contains(.saliency) { requests.append(saliency) }
        if !requests.isEmpty {
            guard (try? handler.perform(requests)) != nil else { return nil }
            boxes.faces = (faces.results ?? []).map { normalised($0.boundingBox) }
            boxes.people = (people.results ?? []).map { normalised($0.boundingBox) }
            boxes.objects = (animals.results ?? []).map { normalised($0.boundingBox) }
            boxes.saliency = (saliency.results?.first).flatMap(hotSpot).map { [$0] } ?? []
        }
        // The things in front: only when the chain gets as far as `object` with nothing found before it.
        if let object = chain.firstIndex(of: .object),
           chain[..<object].allSatisfy({ boxes.boxes($0).isEmpty }), boxes.objects.isEmpty {
            boxes.objects = foreground(handler)
        }
        if custom, let detector {
            guard let found = ModelDetector.detections(in: image, people: boxes.people, setup: detector) else { return nil }
            boxes.detections = found
            if !chain.contains(.person) { boxes.people = [] }
        }
        return boxes
    }

    /// Vision's normalised rect (origin bottom-left, y up) in the photo's space (origin top-left, y down).
    public static func normalised(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Where the eye goes: the heat map's cells at `hotShare` of its peak or more, as one box (top-left space, as the
    /// map's rows run). Vision's own `salientObjects` box is too coarse to point anywhere: on the test photos (DSCF0150–
    /// 0154, a–c, 1536 px) it covers 0.45–0.85 of each side and its centre is about the photo's, where the hot spot of
    /// the 68×68 map is ~0.2 of a side and off centre (b.jpg: the spot at (0.73, 0.64), the box's centre (0.55, 0.48)).
    public static let hotShare: Float = 0.5

    static func hotSpot(_ observation: VNSaliencyImageObservation) -> CGRect? {
        let map = observation.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), row = CVPixelBufferGetBytesPerRow(map)
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: Float.self)
            for x in 0..<w { values[y * w + x] = line[x] }
        }
        return hotSpot(values, width: w, height: h)
    }

    /// The box of the hottest place of `heat` (rows top-down), normalised: of the cells at `hotShare` of the peak or
    /// more, the group touching (corners too) with the most heat. Not the box round all of them: two places apart (a face
    /// at the top, something at the bottom) made one tall box whose centre was on neither (owner's report, 2026-10-28).
    /// Nil when all is 0.
    static func hotSpot(_ heat: [Float], width: Int, height: Int) -> CGRect? {
        guard let peak = heat.max(), peak > 0 else { return nil }
        let hot = heat.map { $0 >= peak * hotShare }
        var seen = [Bool](repeating: false, count: heat.count)
        var best: (sum: Float, minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for start in heat.indices where hot[start] && !seen[start] {
            var group = (sum: Float(0), minX: width, minY: height, maxX: -1, maxY: -1)
            var stack = [start]
            seen[start] = true
            while let i = stack.popLast() {
                let x = i % width, y = i / width
                group.sum += heat[i]
                group.minX = min(group.minX, x); group.minY = min(group.minY, y)
                group.maxX = max(group.maxX, x); group.maxY = max(group.maxY, y)
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) {
                        let j = ny * width + nx
                        if hot[j], !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            if group.sum > (best?.sum ?? -1) { best = group }
        }
        guard let b = best else { return nil }
        return CGRect(x: Double(b.minX) / Double(width), y: Double(b.minY) / Double(height),
                      width: Double(b.maxX - b.minX + 1) / Double(width), height: Double(b.maxY - b.minY + 1) / Double(height))
    }

    /// The bounding boxes of the foreground instances, from the instance mask (one label per pixel).
    private static func foreground(_ handler: VNImageRequestHandler) -> [CGRect] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil, let result = request.results?.first else { return [] }
        let mask = result.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return [] }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        var bounds: [Int: (minX: Int, minY: Int, maxX: Int, maxY: Int)] = [:]
        for y in 0..<h {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let label = Int(line[x])
                guard label != 0 else { continue }   // 0 is the background
                if let b = bounds[label] {
                    bounds[label] = (min(b.minX, x), min(b.minY, y), max(b.maxX, x), max(b.maxY, y))
                } else {
                    bounds[label] = (x, y, x, y)
                }
            }
        }
        // The mask's rows run top-down, as the photo's space does.
        return bounds.keys.sorted().map { label in
            let b = bounds[label]!
            return CGRect(x: Double(b.minX) / Double(w), y: Double(b.minY) / Double(h),
                          width: Double(b.maxX - b.minX + 1) / Double(w), height: Double(b.maxY - b.minY + 1) / Double(h))
        }
    }
}
