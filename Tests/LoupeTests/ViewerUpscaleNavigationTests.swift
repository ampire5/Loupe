import AppKit
import ImageIO
import UniformTypeIdentifiers
import LoupeCore
import LoupeRender
import Testing
@testable import Loupe

@Suite(.serialized) @MainActor struct ViewerUpscaleNavigationTests {
    @Test func savedModeBecomesTheDefaultForNewViewers() {
        let preferences = UserDefaults.standard
        let key = ViewerUpscale.enabledDefaultKey
        let previous = preferences.object(forKey: key)
        preferences.removeObject(forKey: key)
        defer { preferences.set(previous, forKey: key) }
        let viewer = ViewerUpscale()
        defer { viewer.close() }
        #expect(!viewer.isEnabled)
        viewer.setEnabled(true)
        viewer.saveModeAsDefault()
        let second = ViewerUpscale()
        defer { second.close() }
        #expect(second.isEnabled)
        viewer.setEnabled(false)
        viewer.saveModeAsDefault()
        let third = ViewerUpscale()
        defer { third.close() }
        #expect(!third.isEnabled)
        #expect(second.isEnabled)
    }

    @Test(arguments: [false, true])
    func opensSavedCopyWithInferenceOff(archived: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.png")
        let context = try #require(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let picture = try #require(context.makeImage())
        let encoder = try #require(CGImageDestinationCreateWithURL(original as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, picture, nil)
        try #require(CGImageDestinationFinalize(encoder))
        let photo: URL
        if archived {
            let zip = folder.appendingPathComponent("photos.zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = folder
            process.arguments = ["-q", zip.lastPathComponent, original.lastPathComponent]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            photo = try #require(ArchivePath.url(archive: zip, entry: original.lastPathComponent))
        } else {
            photo = original
        }
        let bytes = try await FileReader().read(photo, priority: ReadPriority(0))
        let stamp = bytes.stamp
        let decoder = ImageIOImageDecoder()
        let data = bytes.data
        let info = try decoder.probe(data)
        let source = try await TiledImage.make(from: decoder.decodeFull(data, info: info))
        let outputSize = PixelSize(width: 640, height: 360)
        let stride = DecodedImage.bytesPerRow(width: outputSize.width)
        let buffer = try PageAlignedBuffer(minimumLength: stride * outputSize.height)
        let pixels = DecodedImage(pixelSize: outputSize, bytesPerRow: stride, buffer: buffer,
                                  colorSpace: source.colorSpace, hasAlphaChannel: false)
        let copy = SavedUpscale(source: photo, stamp: stamp)
        try copy.write(pixels, orientation: .up, model: "stored-test")

        let viewer = ViewerUpscale()
        defer { viewer.close() }
        let entry = CacheEntryView(url: photo, info: info, pyramid: source, failure: nil, decoderName: nil,
                                   timings: LoadTimings(), state: .full, sourceStamp: stamp)
        let timeout = ContinuousClock.now + .seconds(5)
        var enhanced: TiledImage?
        repeat {
            enhanced = viewer.update(entry: entry, current: photo, scale: 0.5, visible: true, active: true, excluded: false)
            if enhanced == nil { try await Task.sleep(for: .milliseconds(10)) }
        } while enhanced == nil && ContinuousClock.now < timeout
        #expect(!viewer.isEnabled)
        #expect(enhanced?.grid.imageSize == outputSize)
        #expect(viewer.storedCopy == copy)
        let savedStatus = viewer.imageStatus(displaying: enhanced, orientation: .right)
        #expect(savedStatus?.size == PixelSize(width: 360, height: 640))
        #expect(savedStatus?.milliseconds == nil)
        viewer.setShowsOriginal(true)
        #expect(viewer.update(entry: entry, current: photo, scale: 0.5, visible: true, active: true, excluded: false) == nil)
        #expect(viewer.storedCopy == copy)
        #expect(viewer.status == "Original")
        viewer.setShowsOriginal(false)
        #expect(viewer.update(entry: entry, current: photo, scale: 0.5, visible: true, active: false, excluded: false) === enhanced)
        #expect(viewer.update(entry: entry, current: nil, scale: 0.5, visible: true, active: true, excluded: false) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_PHOTO"] != nil))
    func savesOnlyTheConfiguredLookaheadAtFitWithDefaultPreferences() async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_PHOTO"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = (0..<4).map { folder.appendingPathComponent("\($0).jpg") }
        let reader = FileReader()
        var copies: [SavedUpscale] = []
        for file in files {
            try FileManager.default.copyItem(at: fixture, to: file)
            copies.append(SavedUpscale(source: file, stamp: try await reader.stamp(file, priority: 0)))
        }
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader)
        let data = try Data(contentsOf: files[0])
        let decoder = ImageIOImageDecoder()
        let info = try decoder.probe(data)
        let image = try await TiledImage.make(from: decoder.decodeFull(data, info: info))
        let entry = CacheEntryView(url: files[0], info: info, pyramid: image, failure: nil, decoderName: nil,
                                   timings: LoadTimings(), state: .full, sourceStamp: copies[0].stamp)
        let preferences = UserDefaults.standard
        let keys = ["loupe.upscale-scale", "loupe.upscale-lookahead", "loupe.upscale-auto-save"]
        let originals = keys.map { ($0, preferences.object(forKey: $0)) }
        let viewer = ViewerUpscale()
        defer {
            viewer.close()
            for (key, value) in originals { preferences.set(value, forKey: key) }
        }
        viewer.reload()
        let scan = ContinuousClock.now + .seconds(5)
        while viewer.scanning, .now < scan { try await Task.sleep(for: .milliseconds(10)) }
        viewer.setScale(.double)
        try #require(viewer.selected != nil)
        preferences.removeObject(forKey: "loupe.upscale-auto-save")
        try #require(viewer.autoSave)
        viewer.setLookaheadDepth(2)
        viewer.setEnabled(true)
        let ahead = UpscaleLookahead.urls(in: files, from: 0, direction: 1, depth: viewer.lookaheadDepth)
        let timeout = ContinuousClock.now + .seconds(15)
        while !copies[1...2].allSatisfy(\.exists), .now < timeout {
            _ = viewer.update(entry: entry, current: files[0], scale: 0.5, visible: true, active: true, excluded: false)
            viewer.updateLookahead(ahead, cache: cache, eligible: true)
            try await Task.sleep(for: .milliseconds(30))
        }
        let savedAll = copies[0...2].allSatisfy { $0.exists }
        #expect(savedAll)
        let enhanced = viewer.update(entry: entry, current: files[0], scale: 0.5, visible: true, active: true, excluded: false)
        let timing = try #require(viewer.imageStatus(displaying: enhanced, orientation: .up)?.milliseconds)
        #expect(timing > 0)
        #expect(!copies[3].exists)
        let listing = try BrowserListingSource.full(folder, archives: false)
        let badges = Dictionary(uniqueKeysWithValues: listing.map { ($0.name, $0.badge) })
        #expect(badges == ["0.jpg": "Upscale", "1.jpg": "Upscale", "2.jpg": "Upscale", "3.jpg": nil])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_TEST_BATCH_UPSCALE"] == "1"))
    func explicitBatchSavesWithAutomaticUpscalingOffAndSkipsOnRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ["first.png", "second.png"].map { folder.appendingPathComponent($0) }
        let context = try #require(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let picture = try #require(context.makeImage())
        for photo in files {
            let destination = try #require(CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, picture, nil)
            try #require(CGImageDestinationFinalize(destination))
        }

        let preferences = UserDefaults.standard
        let key = "loupe.upscale-auto-save"
        let previous = preferences.object(forKey: key)
        preferences.set(false, forKey: key)
        defer { preferences.set(previous, forKey: key) }
        let viewer = ViewerUpscale()
        viewer.setEnabled(false)
        defer { ViewerUpscale.cancelBatch(); viewer.close() }
        let cache = ImageCache(loader: MetalPyramidLoader())
        var feedback: [String] = []
        func runBatch(_ urls: [URL]) async throws -> String {
            feedback = []
            viewer.startBatch(urls, cache: cache) { feedback.append($0) }
            let deadline = ContinuousClock.now + .seconds(45)
            while feedback.last?.hasPrefix("Batch Upscale finished") != true, .now < deadline {
                if feedback.last?.hasPrefix("Choose a Core ML model") == true { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            return try #require(feedback.last)
        }

        let missing = folder.appendingPathComponent("missing.png")
        let first = try await runBatch([files[0], missing, files[1]])
        #expect(first.contains("2 saved · 0 skipped"))
        #expect(first.contains("1 failed · missing.png"))
        let listing = try BrowserListingSource.full(folder, archives: false)
        #expect(listing.count == 2 && listing.allSatisfy { $0.badge == SavedUpscale.badge })
        let second = try await runBatch(files)
        #expect(second.contains("0 saved · 2 skipped"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_ADVANCE_PHOTO"] != nil),
          arguments: [1, 2])
    func navigationKeepsRelevantPrefetchWhileTheNewOriginalLoads(step: Int) async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_ADVANCE_PHOTO"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = (0..<(step == 1 ? 2 : 4)).map { "\($0).jpg" }
        for name in names { try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent(name)) }
        let zip = folder.appendingPathComponent("photos.zip")
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        pack.currentDirectoryURL = folder
        pack.arguments = ["-0", "-q", zip.lastPathComponent] + names
        try pack.run()
        pack.waitUntilExit()
        try #require(pack.terminationStatus == 0)
        let files = try names.map { try #require(ArchivePath.url(archive: zip, entry: $0)) }
        let reader = FileReader(threads: 4)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader)
        let bytes = try await reader.read(files[0], priority: ReadPriority(0))
        let decoder = ImageIOImageDecoder()
        let info = try decoder.probe(bytes.data)
        let image = try await TiledImage.make(from: decoder.decodeFull(bytes.data, info: info))
        let entry = CacheEntryView(url: files[0], info: info, pyramid: image, failure: nil, decoderName: nil,
                                   timings: LoadTimings(), state: .full, sourceStamp: bytes.stamp)
        let destination = files[step]
        let queued = try #require(files.last)
        let next = SavedUpscale(source: queued, stamp: try await reader.stamp(queued, priority: 0))
        let preferences = UserDefaults.standard
        let keys = ["loupe.upscale-scale", "loupe.upscale-lookahead", "loupe.upscale-auto-save"]
        let originals = keys.map { ($0, preferences.object(forKey: $0)) }
        let viewer = ViewerUpscale()
        defer {
            viewer.close()
            for (key, value) in originals { preferences.set(value, forKey: key) }
        }
        viewer.reload()
        let scan = ContinuousClock.now + .seconds(5)
        while viewer.scanning, .now < scan { try await Task.sleep(for: .milliseconds(10)) }
        viewer.setScale(.double)
        try #require(viewer.selected != nil)
        viewer.setAutoSave(true)
        viewer.setLookaheadDepth(1)
        viewer.setEnabled(true)
        let firstCopy = SavedUpscale(source: files[0], stamp: bytes.stamp)
        let started = ContinuousClock.now
        let firstDeadline = started + .seconds(20)
        var visibleAt: ContinuousClock.Instant?
        var existedWhenShown: Bool?
        while viewer.storedImage == nil, .now < firstDeadline {
            let shown = viewer.update(entry: entry, current: files[0], scale: 0.5, visible: true, active: true, excluded: false)
            if shown != nil, visibleAt == nil {
                visibleAt = .now
                existedWhenShown = firstCopy.exists
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        try #require(viewer.storedImage != nil)
        let firstVisible = try #require(visibleAt)
        #expect(existedWhenShown == false)
        print("ZIP 2× foreground: visible in \(started.duration(to: firstVisible)), saved in \(started.duration(to: .now))")
        viewer.updateLookahead([queued], cache: cache, eligible: true)
        try await Task.sleep(for: .milliseconds(400))
        try #require(!next.exists, "The test ZIP must exercise in-flight 2× work.")
        let navigated = ContinuousClock.now
        _ = viewer.update(entry: nil, current: destination, scale: 0.5, visible: true, active: true, excluded: false)
        viewer.updateLookahead(step == 1 ? [] : [queued], cache: cache, eligible: true)

        // Keep the next original unavailable so only the already queued ZIP work can produce its result.
        let deadline = navigated + .seconds(6)
        while !next.exists, .now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(next.exists)
        print("ZIP 2× lookahead after +\(step): \(navigated.duration(to: .now)), ready=\(next.exists)")

        let nextEntry = CacheEntryView(url: queued, info: info, pyramid: image, failure: nil, decoderName: nil,
                                       timings: LoadTimings(), state: .full, sourceStamp: next.stamp)
        let displayDeadline = ContinuousClock.now + .seconds(2)
        var shown: TiledImage?
        repeat {
            shown = viewer.update(entry: nextEntry, current: queued, scale: 0.5, visible: true, active: true, excluded: false)
            if shown != nil && viewer.storedCopy == next { break }
            try await Task.sleep(for: .milliseconds(10))
        } while .now < displayDeadline
        #expect(shown?.grid.imageSize.width == image.grid.imageSize.width * 2)
        #expect(viewer.status == "Saved upscale · 2×")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_PHOTO"] != nil))
    func reopensSavedCopyWithoutReprocessingWhenAnotherModelIsSelected() async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_PHOTO"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("original.jpg")
        try FileManager.default.copyItem(at: fixture, to: photo)
        let stamp = try await FileReader().stamp(photo, priority: 0)
        let data = try Data(contentsOf: photo)
        let decoder = ImageIOImageDecoder()
        let info = try decoder.probe(data)
        let source = try await TiledImage.make(from: decoder.decodeFull(data, info: info))
        let outputSize = PixelSize(width: info.pixelSize.width * 2, height: info.pixelSize.height * 2)
        let stride = DecodedImage.bytesPerRow(width: outputSize.width)
        let buffer = try PageAlignedBuffer(minimumLength: stride * outputSize.height)
        let pixels = DecodedImage(pixelSize: outputSize, bytesPerRow: stride, buffer: buffer,
                                  colorSpace: source.colorSpace, hasAlphaChannel: false)
        let copy = SavedUpscale(source: photo, stamp: stamp)
        try copy.write(pixels, orientation: .up, model: "previous-model")
        let viewer = ViewerUpscale()
        defer { viewer.close() }
        viewer.reload()
        let scan = ContinuousClock.now + .seconds(5)
        while viewer.scanning, .now < scan { try await Task.sleep(for: .milliseconds(10)) }
        try #require(viewer.selected != nil)
        viewer.setEnabled(true)
        let entry = CacheEntryView(url: photo, info: info, pyramid: source, failure: nil, decoderName: nil,
                                   timings: LoadTimings(), state: .full, sourceStamp: stamp)
        let timeout = ContinuousClock.now + .seconds(5)
        repeat {
            _ = viewer.update(entry: entry, current: photo, scale: 2, visible: true, active: true, excluded: false)
            if viewer.storedImage != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        } while .now < timeout
        try #require(viewer.storedImage != nil)
        #expect(viewer.status == "Saved upscale · 2×")
        #expect(copy.matches(model: "previous-model"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_PHOTO"] != nil))
    func switchingUpscaleFactorsFiltersModelsAndReusesBothResults() async throws {
        _ = NSApplication.shared
        let photo = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_PHOTO"]))
        let decoded = try ImageIODecoder.decodeFull(Data(contentsOf: photo))
        let pyramid = try await TiledImage.make(from: decoded)
        let entry = CacheEntryView(url: photo, info: nil, pyramid: pyramid, failure: nil, decoderName: nil,
                                   timings: LoadTimings(), state: .full,
                                   sourceStamp: FileStamp(modified: .distantPast, size: decoded.buffer.length))
        let preferences = UserDefaults.standard
        let selectionKeys = ["loupe.upscale-scale", "loupe.upscale-model-2", "loupe.upscale-model-4"]
        let originals = selectionKeys.map { ($0, preferences.object(forKey: $0)) }
        let viewer = ViewerUpscale()
        defer {
            viewer.close()
            for (key, value) in originals { preferences.set(value, forKey: key) }
        }

        viewer.reload()
        let scan = ContinuousClock.now + .seconds(5)
        while viewer.scanning, .now < scan { try await Task.sleep(for: .milliseconds(10)) }
        viewer.setScale(.double)
        let doubleModelName = try #require(ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_2X_MODEL"]
            ?? viewer.models.first?.name)
        viewer.setScale(.quadruple)
        let quadrupleModelName = try #require(ProcessInfo.processInfo.environment["LOUPE_TEST_UPSCALE_4X_MODEL"]
            ?? viewer.models.first?.name)
        let panel = UpscaleSlotPanel(upscale: viewer)
        func popup(_ label: String, in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton, popup.accessibilityLabel() == label { return popup }
            return view.subviews.lazy.compactMap { popup(label, in: $0) }.first
        }
        let factorPicker = try #require(popup("Upscale factor", in: panel))
        let modelPicker = try #require(popup("Upscale model", in: panel))
        func chooseFactor(_ scale: ViewerUpscale.Scale) throws {
            factorPicker.selectItem(withTag: scale.rawValue)
            try #require(NSApp.sendAction(try #require(factorPicker.action), to: factorPicker.target, from: factorPicker))
            #expect(viewer.scale == scale)
        }
        func chooseModel(_ name: String) throws {
            try #require(modelPicker.item(withTitle: name) != nil)
            modelPicker.selectItem(withTitle: name)
            try #require(NSApp.sendAction(try #require(modelPicker.action), to: modelPicker.target, from: modelPicker))
            #expect(viewer.selected?.name == name)
        }
        try chooseFactor(.double)
        #expect(modelPicker.item(withTitle: quadrupleModelName) == nil)
        try chooseModel(doubleModelName)
        viewer.setEnabled(true)
        func update(_ target: ViewerUpscale? = nil) -> TiledImage? {
            (target ?? viewer).update(entry: entry, current: photo, scale: 2, visible: true, active: true, excluded: false)
        }
        func ready() async throws -> TiledImage {
            let deadline = ContinuousClock.now + .seconds(12)
            while .now < deadline {
                if let result = update() { return result }
                try await Task.sleep(for: .milliseconds(8))
            }
            Issue.record("Upscale did not finish: \(viewer.status ?? "no status")")
            throw CancellationError()
        }
        let first = try await ready()
        #expect(first.grid.imageSize.width == decoded.pixelSize.width * 2)
        try chooseFactor(.quadruple)
        #expect(modelPicker.item(withTitle: doubleModelName) == nil)
        try chooseModel(quadrupleModelName)
        #expect(viewer.isEnabled)
        #expect(update() == nil)
        let second = try await ready()
        #expect(second.grid.imageSize.width == decoded.pixelSize.width * 4)
        #expect(viewer.isEnabled)

        let start = ContinuousClock.now
        try chooseFactor(.double)
        #expect(viewer.selected?.name == doubleModelName)
        #expect(update() === first)
        try chooseFactor(.quadruple)
        #expect(viewer.selected?.name == quadrupleModelName)
        #expect(update() === second)
        print("Upscale two cached model switches: \(start.duration(to: .now))")
        let otherWindow = ViewerUpscale()
        defer { otherWindow.close() }
        otherWindow.setEnabled(true)
        #expect(update(otherWindow) === second)
    }
}
