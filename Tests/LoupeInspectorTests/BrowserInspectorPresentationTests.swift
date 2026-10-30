import AppKit
import Foundation
import HomeScreenModel
import LoupeCore
import LoupeInspector
import Testing

@MainActor @Suite(.serialized) struct BrowserInspectorPresentationTests {
    private func fixture(_ defaults: UserDefaults) async -> BrowserInspectorController {
        let loader = BrowserInspectorLoader(settleDelay: .zero, reader: { _ in
            var metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
            metadata.camera = "Example Camera"
            metadata.generation = "A cat beside a window"
            metadata.header = ImageInfo(pixelSize: PixelSize(width: 1200, height: 800), typeIdentifier: "public.jpeg",
                                        isProgressive: false, fileSize: 2048, colorSpaceName: "sRGB")
            return BrowserInspectorResult(metadata: metadata)
        })
        let controller = BrowserInspectorController(defaults: defaults, loader: loader)
        _ = controller.view
        loader.select(BrowserEntry(url: URL(fileURLWithPath: "/Examples/cat.jpg"), name: "cat.jpg", kind: .file))
        loader.isActive = true
        for _ in 0..<300 where loader.result == nil { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(loader.result != nil)
        return controller
    }

    private func disclosures(_ view: NSView) -> [NSButton] {
        if let button = view as? NSButton, button.bezelStyle == .disclosure { return [button] }
        return view.subviews.flatMap { disclosures($0) }
    }

    private func visibleValues(_ view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { visibleValues($0) }
    }

    @Test func selectionShowsCardFactsWhileWaitingAndKeepsTheSameSectionControls() async {
        let domain = "local.loupe.inspector-progressive.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let gate = PresentationReadGate()
        let loader = BrowserInspectorLoader(settleDelay: .zero, reader: { await gate.read($0.name) })
        let controller = BrowserInspectorController(defaults: defaults, loader: loader)
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        loader.isActive = true
        defer { loader.isActive = false }
        func entry(_ name: String, camera: String) -> BrowserEntry {
            BrowserEntry(url: URL(fileURLWithPath: "/Examples/" + name), name: name, kind: .file,
                         facts: FileFacts(width: 1200, height: 800, camera: camera, colorSpace: "sRGB", typeIdentifier: "public.jpeg"))
        }
        loader.select(entry("a.jpg", camera: "Camera A"))
        #expect(visibleValues(controller.view).contains("Camera A"))
        let sections = disclosures(controller.view)
        #expect(sections.count == 4)
        for _ in 0..<300 where !(await gate.names.contains("a.jpg")) { try? await Task.sleep(for: .milliseconds(1)) }
        loader.select(entry("b.jpg", camera: "Camera B"))
        #expect(visibleValues(controller.view).contains("Camera B"))
        #expect(!visibleValues(controller.view).contains("Camera A"))
        #expect(visibleValues(controller.view).contains("Requesting information…"))
        #expect(disclosures(controller.view) == sections)
        await gate.finish("a.jpg")
        for _ in 0..<300 where !(await gate.names.contains("b.jpg")) { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(visibleValues(controller.view).contains("Camera B"))
        await gate.finish("b.jpg")
        for _ in 0..<300 where loader.result == nil { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(loader.result != nil)
        #expect(disclosures(controller.view) == sections)
        #expect(visibleValues(controller.view).contains("Camera B"))
        #expect(!visibleValues(controller.view).contains("Requesting information…"))
    }

    @Test func allInformationGroupsStartExpanded() async {
        let domain = "local.loupe.inspector-defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let controller = await fixture(defaults)
        defer { controller.loader.isActive = false }
        let buttons = disclosures(controller.view)
        #expect(Set(buttons.map(\.title)) == ["Capture", "Generation", "File and Location", "Technical Details"])
        #expect(buttons.allSatisfy { $0.state == .on })
        let values = visibleValues(controller.view)
        #expect(values.contains("Example Camera"))
        #expect(values.contains("A cat beside a window"))
        #expect(values.contains("/Examples/cat.jpg"))
        #expect(values.contains("JPEG"))
    }

    @Test func userCanCollapseAndItsChoiceSurvivesRecreation() async throws {
        let domain = "local.loupe.inspector-collapse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = await fixture(defaults)
        defer { first.loader.isActive = false }
        let generation = try #require(disclosures(first.view).first { $0.title == "Generation" })
        #expect(generation.state == .on)
        generation.performClick(nil)
        #expect(generation.state == .off)
        #expect(!visibleValues(first.view).contains("A cat beside a window"))
        #expect(defaults.object(forKey: "browserInspector.expanded.Generation") as? Bool == false)
        let second = await fixture(defaults)
        defer { second.loader.isActive = false }
        let restored = try #require(disclosures(second.view).first { $0.title == "Generation" })
        #expect(restored.state == .off)
        #expect(!visibleValues(second.view).contains("A cat beside a window"))
        #expect(disclosures(second.view).filter { $0.title != "Generation" }.allSatisfy { $0.state == .on })
    }
}

private actor PresentationReadGate {
    var names: [String] = []
    var replies: [String: CheckedContinuation<BrowserInspectorResult, Never>] = [:]
    func read(_ name: String) async -> BrowserInspectorResult {
        names.append(name)
        return await withCheckedContinuation { replies[name] = $0 }
    }
    func finish(_ name: String) {
        let metadata = PhotoMetadata(properties: [:], pngText: [:], created: nil, modified: nil)
        replies.removeValue(forKey: name)?.resume(returning: BrowserInspectorResult(metadata: metadata))
    }
}
