import Foundation
import Testing
import HomeScreenModel
@testable import LoupeCore

@Suite struct BrowserInspectorContentTests {
    private let file = BrowserEntry(url: URL(fileURLWithPath: "/Examples/cat.jpg"), name: "cat.jpg", kind: .file,
                                    size: 2048)

    @Test func listingFactsAppearBeforeMetadataAndNoEmptyCapture() {
        let content = BrowserInspectorContent.make(entry: file, result: nil, pending: true)
        #expect(content.name == "cat.jpg")
        #expect(content.summary.contains { $0.label == "Size" && $0.value.contains("2.0") })
        #expect(content.sections.map(\.title) == ["Capture", "Generation", "File and Location", "Technical Details"])
        #expect(content.pendingSections.contains("Capture"))
        #expect(content.pendingSections.contains("Generation"))
        #expect(content.message == nil)
    }

    @Test func cardCaptureAndHeaderFactsAreImmediatelyVisibleAndRetainedOnFailure() {
        var entry = file
        entry.facts = FileFacts(width: 3000, height: 4000, camera: "Catalog Camera", lens: "Example Lens",
                                exposure: 0.004, aperture: 2.8, iso: 400, focalLength: 50,
                                colorSpace: "Display P3", orientation: 6, progressive: true, typeIdentifier: "public.jpeg")
        let pending = BrowserInspectorContent.make(entry: entry, result: nil, pending: true)
        #expect(pending.summary.contains { $0.label == "Dimensions" && $0.value == "3000 × 4000" })
        #expect(pending.summary.contains { $0.label == "Profile" && $0.value == "Display P3" })
        #expect(pending.sections.first { $0.title == "Capture" }?.rows.contains { $0.label == "Camera" && $0.value == "Catalog Camera" } == true)
        #expect(pending.sections.first { $0.title == "Capture" }?.rows.contains { $0.label == "ISO" && $0.value == "ISO 400" } == true)
        #expect(pending.sections.first { $0.title == "Technical Details" }?.rows.contains { $0.label == "Format" && $0.value == "JPEG progressive" } == true)
        var metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        metadata.error = "Share unavailable"
        let failed = BrowserInspectorContent.make(entry: entry, result: BrowserInspectorResult(metadata: metadata), pending: false)
        #expect(failed.sections.map(\.title) == pending.sections.map(\.title))
        #expect(failed.summary.map(\.label) == pending.summary.map(\.label))
        #expect(failed.sections.first { $0.title == "Capture" }?.rows.contains { $0.value == "Catalog Camera" } == true)
        #expect(failed.pendingSections.isEmpty)
    }

    @Test func captureAndGenerationAreSeparateAndViewerDiagnosticsAreAbsent() {
        var metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        metadata.camera = "Example Camera"
        metadata.iso = "ISO 100"
        metadata.generation = "A cat beside a window"
        metadata.header = ImageInfo(pixelSize: PixelSize(width: 6000, height: 4000), typeIdentifier: "public.jpeg",
                                    isProgressive: false, fileSize: 2048, colorSpaceName: "sRGB", orientation: .right)
        let content = BrowserInspectorContent.make(entry: file, result: BrowserInspectorResult(metadata: metadata), pending: false)
        #expect(content.summary.contains { $0.label == "Dimensions" && $0.value == "4000 × 6000" })
        #expect(content.sections.first { $0.title == "Capture" }?.rows.contains { $0.label == "Camera" } == true)
        #expect(content.sections.first { $0.title == "Generation" }?.rows.first?.value == "A cat beside a window")
        #expect(!content.sections.contains { $0.title == "Display" || $0.title == "Diagnostics" })
    }

    @Test func emptySelectionAndReadFailureHaveAnExplicitState() {
        let empty = BrowserInspectorContent.make(entry: nil, result: nil, pending: false)
        #expect(empty.message == "Select a file to see its information.")
        #expect(empty.sections.isEmpty)
        var metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        metadata.error = "File not found"
        let failed = BrowserInspectorContent.make(entry: file, result: BrowserInspectorResult(metadata: metadata), pending: false)
        #expect(failed.message == "File not found")
        #expect(failed.name == "cat.jpg")
    }
}

private actor InspectorReadGate {
    var calls: [String] = []
    var replies: [String: CheckedContinuation<BrowserInspectorResult, Never>] = [:]
    func read(_ entry: BrowserEntry) async -> BrowserInspectorResult {
        calls.append(entry.name)
        return await withCheckedContinuation { replies[entry.name] = $0 }
    }
    func finish(_ name: String) {
        var m = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        m.description = name
        replies.removeValue(forKey: name)?.resume(returning: BrowserInspectorResult(metadata: m))
    }
}

@MainActor @Suite struct BrowserInspectorLoaderTests {
    private func entry(_ name: String) -> BrowserEntry {
        BrowserEntry(url: URL(fileURLWithPath: "/Examples/\(name)"), name: name, kind: .file,
                     date: Date(timeIntervalSince1970: 100), size: 100)
    }
    private func wait(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(await condition())
    }

    @Test func slowReadKeepsOnlyLatestPendingSelectionAndRejectsOldReply() async {
        let gate = InspectorReadGate()
        let loader = BrowserInspectorLoader(settleDelay: .zero, reader: { await gate.read($0) })
        loader.isActive = true
        loader.select(entry("a.jpg"))
        await wait { await gate.calls == ["a.jpg"] }
        loader.select(entry("b.jpg"))
        loader.select(entry("c.jpg"))
        #expect(loader.content.name == "c.jpg")
        #expect(loader.result == nil)
        await gate.finish("a.jpg")
        await wait { await gate.calls == ["a.jpg", "c.jpg"] }
        #expect(loader.result == nil)
        await gate.finish("c.jpg")
        await wait { loader.result?.metadata.description == "c.jpg" }
        loader.select(entry("a.jpg"))
        #expect(loader.result?.metadata.description == "a.jpg")
        #expect(await gate.calls == ["a.jpg", "c.jpg"])
        loader.isActive = false
    }

    @Test func partialCardUpdatesCannotDiscardRicherCatalogFacts() async {
        let source = InspectorReadGate()
        let catalog = InspectorCatalogGate()
        let loader = BrowserInspectorLoader(settleDelay: .zero, catalog: { _ in await catalog.read() },
                                             reader: { await source.read($0) })
        var selected = entry("a.jpg")
        selected.facts = FileFacts(width: 1200, camera: "Current Camera")
        loader.select(selected)
        loader.isActive = true
        await wait { await catalog.waiting }
        selected.facts = FileFacts(width: 1200, height: 800, camera: "New Camera")
        loader.select(selected)
        await catalog.finish()
        await wait { await source.calls == ["a.jpg"] }
        #expect(loader.entry?.facts?.camera == "New Camera")
        #expect(loader.entry?.facts?.lens == "Catalog Lens")
        #expect(loader.entry?.facts?.colorSpace == "sRGB")
        #expect(loader.entry?.facts?.height == 800)
        await source.finish("a.jpg")
        await wait { loader.result != nil }
        loader.isActive = false
    }

    @Test func catalogFactsPublishWhileSourceReadIsStillPending() async {
        let gate = InspectorReadGate()
        let loader = BrowserInspectorLoader(settleDelay: .zero, catalog: { _ in
            BrowserInspectorSeed(facts: FileFacts(width: 1200, height: 800, camera: "Catalog Camera"))
        }, reader: { await gate.read($0) })
        loader.isActive = true
        loader.select(entry("a.jpg"))
        await wait { await gate.calls == ["a.jpg"] }
        #expect(loader.result == nil)
        #expect(loader.content.sections.first { $0.title == "Capture" }?.rows.contains { $0.value == "Catalog Camera" } == true)
        #expect(loader.content.pendingSections.contains("Generation"))
        await gate.finish("a.jpg")
        await wait { loader.result != nil }
        #expect(loader.content.pendingSections.isEmpty)
        loader.isActive = false
    }

    @Test func hideAndReshowDoesNotStartAnotherReadUntilOldOneFinishes() async {
        let gate = InspectorReadGate()
        let loader = BrowserInspectorLoader(settleDelay: .zero, reader: { await gate.read($0) })
        loader.isActive = true
        loader.select(entry("a.jpg"))
        await wait { await gate.calls.count == 1 }
        loader.isActive = false
        loader.select(entry("b.jpg"))
        loader.isActive = true
        #expect(await gate.calls == ["a.jpg"])
        await gate.finish("a.jpg")
        await wait { await gate.calls == ["a.jpg", "b.jpg"] }
        loader.isActive = false
        await gate.finish("b.jpg")
        await wait { !loader.isReading }
        #expect(loader.result == nil)
    }

    @Test func arrivingFactsDoNotInvalidateTheReadOfTheSameFile() async {
        let gate = InspectorReadGate()
        let loader = BrowserInspectorLoader(settleDelay: .zero, reader: { await gate.read($0) })
        loader.isActive = true
        var selected = entry("a.jpg")
        selected.date = nil; selected.size = nil
        loader.select(selected)
        await wait { await gate.calls.count == 1 }
        selected.facts = FileFacts(width: 6000, height: 4000)
        loader.select(selected)
        await gate.finish("a.jpg")
        await wait { loader.result?.metadata.description == "a.jpg" }
        #expect(await gate.calls == ["a.jpg"])
        loader.isActive = false
        await gate.finish("a.jpg")
    }

    @Test func selectingNothingInvalidatesInFlightResult() async {
        let gate = InspectorReadGate()
        let loader = BrowserInspectorLoader(settleDelay: .zero, reader: { await gate.read($0) })
        loader.isActive = true
        loader.select(entry("a.jpg"))
        await wait { await gate.calls.count == 1 }
        loader.select(nil)
        await gate.finish("a.jpg")
        await wait { !loader.isReading }
        #expect(loader.content.name.isEmpty)
        #expect(loader.result == nil)
        #expect(await gate.calls == ["a.jpg"])
    }
}

private actor InspectorCatalogGate {
    var waiting = false
    private var reply: CheckedContinuation<BrowserInspectorSeed?, Never>?
    func read() async -> BrowserInspectorSeed? {
        waiting = true
        return await withCheckedContinuation { reply = $0 }
    }
    func finish() {
        reply?.resume(returning: BrowserInspectorSeed(facts: FileFacts(camera: "Old Camera", lens: "Catalog Lens", colorSpace: "sRGB")))
        reply = nil
    }
}
