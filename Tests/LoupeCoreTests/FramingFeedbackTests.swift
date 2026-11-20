import Foundation
import Testing
@testable import LoupeCore

struct FramingFeedbackTests {
    @Test func oldDatasetAndOverlappingObjects() throws {
        let old = Data(#"{"schema":1,"revision":0,"references":[],"votes":[],"policies":[]}"#.utf8)
        let dataset = try JSONDecoder().decode(FramingDataset.self, from: old)
        #expect(dataset.objectFeedback.isEmpty)
        var ref = try FramingReferenceTests.sample()
        ref.boxes.people = [.init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)]
        let hits = FramingInstance.at(.init(x: 0.4, y: 0.3), in: ref.boxes)
        #expect(hits.map(\.kind) == [.face, .person])
        #expect(FramingInstance.at(.init(x: -0.1, y: 0.3), in: ref.boxes).isEmpty)
    }
    @Test func objectFeedbackPreservesCropsAndUndoIsRevisionFenced() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FramingReferenceStore(directory: dir)
        let before = try await store.upsert(FramingReferenceTests.sample())
        let ref = before.references[0]
        let feedback = FramingObjectFeedback(source: ref.source, sourceRevision: .init(bytes: 10, modified: .distantPast),
            evidence: ref.evidence, boxes: ref.boxes, instance: ref.instances[0], intent: .detail, reason: .blurred)
        let after = try await store.record(feedback, expectedRevision: before.revision)
        #expect(after.references == before.references)
        #expect(after.objectFeedback == [feedback])
        let undone = try await store.restore(before, expectedRevision: after.revision)
        #expect(undone.objectFeedback.isEmpty)
        #expect(undone.references == before.references)
        await #expect(throws: Error.self) { try await store.restore(after, expectedRevision: after.revision) }
        var invalid = feedback; invalid.instance.id = "nonexistent"
        await #expect(throws: Error.self) { try await store.record(invalid, expectedRevision: undone.revision) }
    }
}
