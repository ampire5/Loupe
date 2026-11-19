import AppKit
import Darwin
import ImageIO
import LoupeCore
import UniformTypeIdentifiers

/// Synthetic evidence only; never opens the user's catalog, settings or detector model.
@MainActor enum FramingLearningBench {
    static func cpu() -> Double {
        var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }
    static func run(directory: URL) async -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        do {
            let profile = FramingProfile(name: "vision", chain: [.face, .person, .object, .saliency])
            let store = FramingReferenceStore(directory: directory.appendingPathComponent("dataset"))
            let rows = try await Task.detached(priority: .utility) { try fixtures(directory: directory, profile: profile) }.value
            for row in rows { _ = try await store.upsert(row) }
            let library = FramingLearningLibrary(store: store)
            let coordinator = FramingLearningCoordinator(library: library, profile: profile, intent: .detail,
                currentProfile: { profile }, currentPolicy: { nil }, applyTab: { _, _ in })
            let sampleRequest = FramingCaptureRequest(origin: .init(source: rows[0].source, profile: profile,
                behavior: .auto, input: rows[0].input.transform), target: rows[0].target.transform,
                evidence: rows[0].evidence, expectedRevision: rows[0].sourceRevision ?? .init(bytes: 0, modified: .distantPast), boxes: { rows[0].boxes })
            let helper = ViewerFramingLearning(library: library, profile: { profile }, source: { rows[0].source },
                capture: { sampleRequest }, apply: { _ in }, reframe: {}, next: {}, message: { _ in })
            for round in 0..<6 {
                let start = cpu()
                let menu = helper.feedbackMenu(at: .init(x: 0.5, y: 0.4), boxes: rows[0].boxes)
                menu.update(); _ = menu.size
                for item in menu.items { item.submenu?.update(); _ = item.submenu?.size }
                print(String(format: "CONTROL feedback-menu-%d main-thread-ms=%.3f", round, (cpu() - start) * 1000))
            }
            var windows: [FramingLearningWindow] = []
            for round in 0..<4 {
                let start = cpu()
                let window = FramingLearningWindow(coordinator: coordinator)
                window.showWindow(nil); window.window?.contentView?.layoutSubtreeIfNeeded(); window.window?.displayIfNeeded()
                print(String(format: "WINDOW create-%d main-thread-ms=%.3f", round, (cpu() - start) * 1000))
                let returnStart = cpu()
                window.window?.orderOut(nil); window.showWindow(nil); window.window?.displayIfNeeded()
                print(String(format: "WINDOW return-%d main-thread-ms=%.3f", round, (cpu() - returnStart) * 1000))
                windows.append(window)
            }
            guard let window = windows.last else { exit(2) }
            coordinator.load()
            await wait { coordinator.references.count == rows.filter { $0.intent == .detail }.count }
            let wall = Date(), startCPU = cpu()
            coordinator.fit()
            print(String(format: "CONTROL fit main-thread-ms=%.3f", (cpu() - startCPU) * 1000))
            await wait(seconds: 60) { !coordinator.running }
            guard let result = coordinator.result else { print("FIT FAILED \(coordinator.message)"); exit(1) }
            print(String(format: "FIT references=%d wall-ms=%.1f evaluations=%d training=%.4f validation=%.4f",
                coordinator.references.count, Date().timeIntervalSince(wall) * 1000, result.evaluations,
                result.trainingLoss, result.validationLoss ?? -1))
            let sample = rows[0]
            let inference = await Task.detached(priority: .utility) {
                var times: [Double] = []
                for _ in 0..<20 {
                    let start = Date()
                    _ = result.policy.predict(input: sample.input.transform, boxes: sample.boxes, evidence: sample.evidence,
                        profile: result.baseline, behavior: .auto)
                    times.append(Date().timeIntervalSince(start) * 1000)
                }
                return times.sorted()
            }.value
            print(String(format: "INFERENCE median-ms=%.3f max-ms=%.3f", inference[inference.count / 2], inference.last!))
            var expanded = rows[0]
            expanded.evidence.analysisID = "synthetic-context"
            for i in 0..<18 {
                let kind = SubjectKind(rawValue: "category-\(i)")!
                expanded.evidence.classes["CLASS_\(i)"] = kind
                expanded.boxes.detections.append(.init(kind: kind,
                    rect: .init(x: 0.02 + Double(i % 6) * 0.15, y: 0.05 + Double(i / 6) * 0.25, width: 0.08, height: 0.12), score: 1))
            }
            let expandedFit = Date()
            let expandedResult = try await FramingFitter.fit(profile: profile, references: [expanded])
            print(String(format: "EXPANDED-FIT categories=%d parameters=%d wall-ms=%.1f", expandedResult.policy.kinds.count,
                expandedResult.policy.coefficients.count, Date().timeIntervalSince(expandedFit) * 1000))
            let expandedInference = await Task.detached(priority: .utility) {
                var times: [Double] = []
                for _ in 0..<20 {
                    let start = Date()
                    _ = expandedResult.policy.predict(input: expanded.input.transform, boxes: expanded.boxes, evidence: expanded.evidence,
                        profile: profile, behavior: .auto)
                    times.append(Date().timeIntervalSince(start) * 1000)
                }
                return times.sorted()
            }.value
            print(String(format: "EXPANDED-INFERENCE median-ms=%.3f max-ms=%.3f", expandedInference[expandedInference.count / 2], expandedInference.last!))
            await wait { window.previewReady }
            if let view = window.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: directory.appendingPathComponent("learning-window.png"))
                }
            }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("MEMORY peak-bytes=\(usage.ru_maxrss)")
            print("MACHINE \(ProcessInfo.processInfo.operatingSystemVersionString) \(ProcessInfo.processInfo.processorCount) logical CPUs")
            if Bundle.main.object(forInfoDictionaryKey: "LoupeLearningBenchDirectory") != nil {
                app.activate(); try? await Task.sleep(for: .seconds(45))
            }
            for window in windows { window.close() }
            exit(0)
        } catch { print("BENCH ERROR \(error)"); exit(1) }
    }
    private static func wait(seconds: Double = 5, _ predicate: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }
    private nonisolated static func fixtures(directory: URL, profile: FramingProfile) throws -> [FramingReference] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var rows: [FramingReference] = []
        for i in 0..<12 {
            let url = directory.appendingPathComponent(String(format: "scene-%02d.png", i))
            let x = 0.2 + Double(i % 4) * 0.12, y = 0.12 + Double(i % 3) * 0.08
            let face = CGRect(x: x, y: y, width: 0.12, height: 0.15)
            let person = CGRect(x: x - 0.03, y: y, width: 0.22, height: 0.65)
            let box = CGRect(x: 0.7, y: 0.6, width: 0.16, height: 0.14)
            try autoreleasepool {
                guard let ctx = CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 6400,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FramingLearningError.invalid }
                ctx.setFillColor(CGColor(red: 0.07, green: 0.1, blue: 0.15, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
                for (rect, color) in [(person, CGColor(red: 0.18, green: 0.55, blue: 0.75, alpha: 1)),
                                      (face, CGColor(red: 0.95, green: 0.65, blue: 0.2, alpha: 1)),
                                      (box, CGColor(red: 0.55, green: 0.4, blue: 0.8, alpha: 1))] {
                    ctx.setFillColor(color)
                    ctx.fill(CGRect(x: rect.minX * 1600, y: (1 - rect.maxY) * 1200, width: rect.width * 1600, height: rect.height * 1200))
                }
                guard let image = ctx.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw FramingLearningError.invalid }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw FramingLearningError.invalid }
            }
            let t = ViewTransform(imageSize: .init(width: 1600, height: 1200), viewSize: .init(width: 960, height: 640))
            let boxes = SubjectBoxes(faces: [face], people: [person], objects: [box], saliency: [face])
            for intent in FramingIntent.allCases {
                var desiredProfile = profile; desiredProfile.size = intent == .detail ? 0.9 : 0.45
                var r = try FramingReference(source: url, profile: profile, behavior: .auto, input: t, target: t, boxes: boxes)
                r.intent = intent
                r.target = try FramingGeometry(FramingReplay.transform(reference: r, profile: desiredProfile))
                r.sourceRevision = try FramingSourceRevision.read(url); r.group = "series-\(i / 3)"; r.validation = i >= 9
                rows.append(r)
            }
        }
        return rows
    }
}
