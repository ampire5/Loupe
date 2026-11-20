import Foundation
import Testing
@testable import LoupeCore

struct FramingReferenceTests {
    static func sample(profile: String = "test", path: String = "/sample.jpg") throws -> FramingReference {
        let t = ViewTransform(imageSize: .init(width: 1600, height: 1200), viewSize: .init(width: 800, height: 600), mode: .actual(1))
        return try FramingReference(source: URL(fileURLWithPath: path), profile: .init(name: profile, chain: [.face]),
            behavior: .auto, input: t, target: t, boxes: .init(faces: [.init(x: 0.3, y: 0.2, width: 0.2, height: 0.2)], people: [], objects: [], saliency: []))
    }
    @Test func roundTripRetainsPanScaleAndEvidence() throws {
        var sample = try Self.sample()
        let cat = SubjectKind(rawValue: "cat")!
        sample.boxes.detections = [.init(kind: cat, rect: .init(x: 0.8, y: 0.8, width: 0.1, height: 0.1), score: 0.37)]
        sample.evidence.classes = ["CAT": cat]
        let copy = try JSONDecoder().decode(FramingReference.self, from: JSONEncoder().encode(sample))
        #expect(copy == sample)
        #expect(copy.target.transform == sample.target.transform)
        #expect(copy.instances.contains { $0.kind == cat && $0.score == 0.37 })
    }
    @Test func restingGeometryUsesTheSameClampedCenterAsRendering() throws {
        var t = try Self.sample().target.transform.withMode(.fit)
        t.center = .init(x: 0.1, y: 0.9)
        let geometry = try FramingGeometry(t)
        #expect(geometry.center == t.clamped.center)
        #expect(geometry.transform.visibleRect == t.visibleRect)
    }
    @Test func rejectsInvalidAndTransientGeometry() throws {
        var t = try Self.sample().target.transform
        t.center.x = .nan
        #expect(throws: Error.self) { try FramingGeometry(t) }
        t.center.x = 0.5; t.offset.dx = 10
        #expect(throws: Error.self) { try FramingGeometry(t) }
    }
    @Test func storeReplacesOnlySameProfileSourceAndViewport() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FramingReferenceStore(directory: dir)
        let first = try Self.sample()
        let a = try await store.upsert(first)
        var changed = first; changed.id = UUID(); changed.target.center.x = 0.6
        let b = try await store.upsert(changed)
        #expect(a.references.count == 1 && b.references.count == 1)
        #expect(a.references[0].id == b.references[0].id)
        _ = try await store.upsert(Self.sample(profile: "other"))
        var viewport = first; viewport.input.viewSize.width = 900; viewport.target.viewSize.width = 900
        _ = try await store.upsert(viewport)
        let reopened = try await FramingReferenceStore(directory: dir).snapshot()
        #expect(reopened.references.count == 3)
        #expect(reopened.revision == 4)
    }
    @Test func splitAndVotesPersistAndStaleWritesAreRejected() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FramingReferenceStore(directory: dir)
        let saved = try await store.upsert(Self.sample())
        let id = saved.references[0].id
        _ = try await store.updateGroup(id: id, group: "series", validation: true, expectedRevision: saved.revision)
        await #expect(throws: Error.self) { try await store.remove(id: id, expectedRevision: saved.revision) }
        let snapshot = try await store.snapshot()
        #expect(snapshot.references[0].validation)
        #expect(snapshot.references[0].group == "series")
    }
    @Test func unreadableOrNewerDatasetIsPreserved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("framing-references.json")
        let original = Data("{\"schema\":999,\"revision\":0,\"references\":[],\"votes\":[]}".utf8)
        try original.write(to: file)
        let store = FramingReferenceStore(directory: dir)
        await #expect(throws: Error.self) { try await store.upsert(Self.sample()) }
        #expect(try Data(contentsOf: file) == original)
    }
    @Test func detailAndOverviewAreIndependentReferences() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FramingReferenceStore(directory: dir)
        let detail = try Self.sample()
        var overview = detail; overview.intent = .overview; overview.id = UUID()
        _ = try await store.upsert(detail)
        let dataset = try await store.upsert(overview)
        #expect(dataset.references.count == 2)
    }
    @Test func movingOneReferenceIntoANewSeriesDoesNotMoveTheWholeFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FramingReferenceStore(directory: dir)
        _ = try await store.upsert(Self.sample(path: "/folder/a.jpg"))
        var state = try await store.upsert(Self.sample(path: "/folder/b.jpg"))
        let first = state.references[0].id
        state = try await store.updateGroup(id: first, group: "new-series", validation: true, expectedRevision: state.revision)
        #expect(state.references[0].group == "new-series" && state.references[0].validation)
        #expect(state.references[1].group == "/folder" && !state.references[1].validation)
    }
    @Test func cancellationBeforeCommitPreservesTheDataset() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FramingReferenceStore(directory: dir)
        let token = FramingMutationToken(); #expect(token.cancel())
        await #expect(throws: CancellationError.self) { try await store.upsert(Self.sample(), cancellation: token) }
        #expect(try await store.snapshot().references.isEmpty)
    }
    @Test func oversizedStorageIsRejectedAndNeverOverwritten() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("framing-references.json")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(FramingReferenceStore.maximumFileBytes + 1)); try handle.close()
        let store = FramingReferenceStore(directory: dir)
        await #expect(throws: FramingLearningError.capacity) { try await store.upsert(Self.sample()) }
        #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == FramingReferenceStore.maximumFileBytes + 1)
    }
    @Test func comparisonKeepsTheActualCropsWhenAReferenceIsCorrectedLater() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FramingReferenceStore(directory: dir)
        var reference = try Self.sample(); reference.validation = true
        let initial = try await store.upsert(reference)
        let vote = FramingComparisonVote(referenceID: reference.id, runID: UUID(), candidateFirst: true, choice: .equal,
            referenceSnapshot: reference, baseline: reference.input, candidate: reference.target, datasetRevision: initial.revision)
        _ = try await store.vote(vote, expectedRevision: initial.revision)
        reference.target.center.x = 0.6
        let updated = try await store.upsert(reference)
        #expect(updated.references[0].target.center.x == 0.6)
        #expect(updated.votes[0].referenceSnapshot?.target.center.x == 0.5)
        #expect(updated.votes[0].candidate?.center.x == 0.5)
    }
}
