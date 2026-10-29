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
        #expect(!content.sections.contains { $0.title == "Capture" || $0.title == "Generation" })
        #expect(content.message == "Reading metadata…")
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
        await wait { loader.result?.metadata.description == "a.jpg" }
        #expect(await gate.calls == ["a.jpg", "c.jpg"])
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
