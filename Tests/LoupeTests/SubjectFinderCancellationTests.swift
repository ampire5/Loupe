import CoreGraphics
import Foundation
import LoupeCore
import LoupeRender
import Testing
@testable import Loupe

private actor CatalogGate {
    var calls = 0
    private var waiting: CheckedContinuation<Void, Never>?
    func read() async {
        calls += 1
        if calls == 1 { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { waiting?.resume(); waiting = nil }
}

@MainActor struct SubjectFinderCancellationTests {
    @Test func disablingAnalysisDiscardsRunningResultAndReenableDoesNotJoinIt() async throws {
        let row = DecodedImage.bytesPerRow(width: 16)
        let buffer = try PageAlignedBuffer(minimumLength: row * 16)
        memset(buffer.bytes, 255, buffer.length)
        let image = try await TiledImage.make(from: DecodedImage(pixelSize: .init(width: 16, height: 16),
            bytesPerRow: row, buffer: buffer, colorSpace: CGColorSpaceCreateDeviceRGB()))
        let url = URL(fileURLWithPath: "/subjects-\(UUID().uuidString).jpg")
        let setup = DetectorSetup()
        var boxes = SubjectBoxes(faces: [], people: [], objects: [], saliency: [], searched: SubjectKind.vision)
        boxes.analysisID = setup.analysisID
        boxes.applied = false
        boxes.proxySide = 1536
        let cached = boxes
        let gate = CatalogGate()
        let finder = SubjectFinder(stored: { _ in await gate.read(); return cached }, keep: { _, _ in
            Issue.record("Catalog result should not be written again")
        })
        var cancelledDelivered = false, freshDelivered = false
        finder.request(url, image: image, orientation: .up, applied: false, setup: setup, ahead: false) { _ in
            cancelledDelivered = true
        }
        for _ in 0..<200 {
            if await gate.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.calls == 1)
        finder.keepOnly([]) // Manual: abandon both pending work and the running request.
        finder.request(url, image: image, orientation: .up, applied: false, setup: setup, ahead: false) { _ in
            freshDelivered = true
        }
        await gate.release()
        for _ in 0..<200 {
            if freshDelivered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(freshDelivered)
        #expect(!cancelledDelivered)
        #expect(await gate.calls == 2, "Reenabled analysis must not join the cancelled request")
    }
}
