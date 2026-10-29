import CoreGraphics
import CoreML
import Foundation
import os
import Vision

/// The custom detector's boxes (`DetectorSetup`): the user's compiled Core ML object detector under Vision, on the
/// photo whole and on each person Vision found (`look`), the same box from both kept once; only the labels
/// detector.conf's `[classes]` names, by those names.
///
/// Measured with a YOLOv8n detector at 320 px converted with its NMS (spike, M4 Max, 52 photos, Loupe's 1536 px proxy,
/// .utility): whole 3.4 ms median (p90 4.4), on a person's crop 2.6 ms, CPU only 6.0 / 5.6 ms; loading 0.5 s, once.
/// The same at 640 px (YOLOv8m) found about the same at 3× the time (9.7 ms; CPU only 35 ms). Intel not measured.
public enum ModelDetector {
    /// Below this confidence nothing is kept: detector.conf's `score` chooses among the rest when framing.
    public static let keptScore = 0.2
    /// The same box found whole and on a person's crop: boxes of one kind overlapping by this much (IoU) are one.
    static let sameOverlap = 0.5

    /// Two resident models cover the common fast/large switch without growing with the model catalog.
    /// Loading is serialized off-main; inference does not hold this queue.
    private static let loadQueue = DispatchQueue(label: "Loupe model loading", qos: .utility)
    private static var loaded: [(path: String, model: VNCoreMLModel?)] = []
    private static func model(_ path: String) -> VNCoreMLModel? {
        loadQueue.sync {
            if let i = loaded.firstIndex(where: { $0.path == path }) {
                let item = loaded.remove(at: i); loaded.append(item); return item.model
            }
            let url = URL(fileURLWithPath: path)
            let result = (try? MLModel(contentsOf: url, configuration: MLModelConfiguration()))
                .flatMap { try? VNCoreMLModel(for: $0) }
            loaded.append((path, result))
            if loaded.count > 2 { loaded.removeFirst(loaded.count - 2) }
            return result
        }
    }
    /// Preflight on a utility queue before changing the selected model.
    public static func prepare(_ path: String) -> Bool {
        guard let model = model(path),
              let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(gray: 0.5, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage() else { return false }
        let request = VNCoreMLRequest(model: model); request.imageCropAndScaleOption = .scaleFit
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return false }
        return objectResults(request.results) != nil
    }
    static func objectResults(_ results: [VNObservation]?) -> [VNRecognizedObjectObservation]? {
        results as? [VNRecognizedObjectObservation]
    }

    /// The boxes on `image` (rects normalised top-left, as `SubjectBoxes`), where `setup.look` says, `people` being
    /// Vision's; nil when the model cannot be loaded or Vision fails. Blocks: call it off the main thread.
    public static func detections(in image: CGImage, people: [CGRect], setup: DetectorSetup) -> [SubjectBoxes.Detection]? {
        guard let model = model(setup.model) else { return nil }
        let names = Dictionary(setup.classes.map { ($0.label, $0.kind) }, uniquingKeysWith: { a, _ in a })
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var found: [SubjectBoxes.Detection] = []
        // Each person with a little room round them, as Vision's bottom-left region.
        let crops: [CGRect?] = (setup.lookPeople ? people : []).map { p in
            let r = p.insetBy(dx: -p.width * 0.05, dy: -p.height * 0.05).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        }
        for region in (setup.lookWhole ? [nil] : []) + crops {
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFit
            if let region { request.regionOfInterest = region }
            guard (try? handler.perform([request])) != nil else { return nil }
            guard let objects = objectResults(request.results) else { return nil }
            let r = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            for o in objects {
                guard let top = o.labels.first, let kind = names[top.identifier], Double(top.confidence) >= keptScore
                else { continue }
                let b = o.boundingBox
                let whole = CGRect(x: r.minX + b.minX * r.width, y: r.minY + b.minY * r.height,
                                   width: b.width * r.width, height: b.height * r.height)
                found.append(.init(kind: kind, rect: SubjectDetector.normalised(whole), score: Double(top.confidence)))
            }
        }
        return merged(found)
    }

    /// One box per place: of the boxes of a kind overlapping by `sameOverlap` or more, the surest.
    static func merged(_ found: [SubjectBoxes.Detection]) -> [SubjectBoxes.Detection] {
        var kept: [SubjectBoxes.Detection] = []
        for d in found.sorted(by: { $0.score > $1.score }) {
            let same = kept.contains { k in
                guard k.kind == d.kind else { return false }
                let i = k.rect.intersection(d.rect)
                guard !i.isNull else { return false }
                let inter = i.width * i.height
                return inter / (k.rect.width * k.rect.height + d.rect.width * d.rect.height - inter) >= sameOverlap
            }
            if !same { kept.append(d) }
        }
        return kept
    }
}
