import Foundation

/// One app-owned store shared across windows. All JSON, bookmarks and filesystem access are utility work.
public final class FramingReferenceStore: @unchecked Sendable {
    // Defensive memory ceilings, not optimizer settings: malformed or oversized files must never trigger unbounded reads.
    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumReferences = 4096
    public let directory: URL
    private let queue = DispatchQueue(label: "loupe.framing-references", qos: .utility)
    public init(directory: URL) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("framing-references.json") }
    private func read() throws -> FramingDataset {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw FramingLearningError.capacity }
        let dataset = try JSONDecoder().decode(FramingDataset.self, from: data)
        guard dataset.schema == 1 else { throw FramingLearningError.schema }
        guard dataset.references.count <= Self.maximumReferences, dataset.objectFeedback.count <= Self.maximumReferences * 8,
              dataset.objectFeedback.allSatisfy(\.isValid) else { throw FramingLearningError.capacity }
        guard dataset.references.allSatisfy(\.isValid), Set(dataset.references.map(\.id)).count == dataset.references.count else { throw FramingLearningError.invalid }
        return dataset
    }
    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
    public func snapshot() async throws -> FramingDataset { try await perform { try self.read() } }
    public func savedPolicies() async throws -> [FramingPolicy] { try await perform { try self.read().policies } }
    private func change(expectedRevision: UInt64? = nil, cancellation: FramingMutationToken? = nil,
                        _ body: @escaping @Sendable (inout FramingDataset) throws -> Void) async throws -> FramingDataset {
        try await perform {
            var dataset = try self.read()
            if let expectedRevision, expectedRevision != dataset.revision { throw FramingLearningError.stale }
            try body(&dataset)
            guard dataset.references.count <= Self.maximumReferences, dataset.objectFeedback.count <= Self.maximumReferences * 8,
              dataset.objectFeedback.allSatisfy(\.isValid) else { throw FramingLearningError.capacity }
            guard dataset.references.allSatisfy(\.isValid), Set(dataset.references.map(\.id)).count == dataset.references.count else { throw FramingLearningError.invalid }
            dataset.revision += 1
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(dataset)
            guard data.count <= Self.maximumFileBytes else { throw FramingLearningError.capacity }
            try cancellation?.beginCommit()
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try data.write(to: self.file, options: .atomic)
            return dataset
        }
    }
    public func upsert(_ reference: FramingReference, expectedRevision: UInt64? = nil, cancellation: FramingMutationToken? = nil) async throws -> FramingDataset {
        try await change(expectedRevision: expectedRevision, cancellation: cancellation) { dataset in
            var reference = reference
            if let i = dataset.references.firstIndex(where: { reference.replaces($0) }) {
                reference.id = dataset.references[i].id
                reference.group = dataset.references[i].group; reference.validation = dataset.references[i].validation
                dataset.references[i] = reference
            } else {
                if dataset.references.contains(where: { $0.id == reference.id }) { reference.id = UUID() }
                dataset.references.append(reference)
            }
        }
    }
    public func record(_ feedback: FramingObjectFeedback, expectedRevision: UInt64,
                       cancellation: FramingMutationToken? = nil) async throws -> FramingDataset {
        try await change(expectedRevision: expectedRevision, cancellation: cancellation) { dataset in
            guard feedback.isValid else { throw FramingLearningError.invalid }
            if let index = dataset.objectFeedback.firstIndex(where: { feedback.replaces($0) }) {
                var feedback = feedback; feedback.id = dataset.objectFeedback[index].id
                dataset.objectFeedback[index] = feedback
            } else { dataset.objectFeedback.append(feedback) }
        }
    }
    /// A one-step checkpoint is safe only if no other transaction has happened since the edit.
    public func restore(_ checkpoint: FramingDataset, expectedRevision: UInt64,
                        cancellation: FramingMutationToken? = nil) async throws -> FramingDataset {
        try await change(expectedRevision: expectedRevision, cancellation: cancellation) { dataset in
            guard checkpoint.schema == dataset.schema else { throw FramingLearningError.schema }
            let revision = dataset.revision
            dataset = checkpoint; dataset.revision = revision
        }
    }
    public func remove(id: UUID, expectedRevision: UInt64, cancellation: FramingMutationToken? = nil) async throws -> FramingDataset {
        try await change(expectedRevision: expectedRevision, cancellation: cancellation) { dataset in
            dataset.references.removeAll { $0.id == id }; dataset.votes.removeAll { $0.referenceID == id }
        }
    }
    public func updateGroup(id: UUID, group: String, validation: Bool, expectedRevision: UInt64, cancellation: FramingMutationToken? = nil) async throws -> FramingDataset {
        try await change(expectedRevision: expectedRevision, cancellation: cancellation) { dataset in
            guard let i = dataset.references.firstIndex(where: { $0.id == id }) else { throw FramingLearningError.stale }
            let source = dataset.references[i].source.standardizedFileURL
            for j in dataset.references.indices where dataset.references[j].source.standardizedFileURL == source {
                dataset.references[j].group = group
            }
            // Moving one item splits a series; reserving a series applies to every member of the destination.
            for j in dataset.references.indices where dataset.references[j].group == group {
                dataset.references[j].validation = validation
            }
        }
    }
    public func vote(_ vote: FramingComparisonVote, expectedRevision: UInt64, cancellation: FramingMutationToken? = nil) async throws -> FramingDataset {
        try await change(expectedRevision: expectedRevision, cancellation: cancellation) { dataset in
            guard dataset.references.contains(where: { $0.id == vote.referenceID && $0.validation }) else { throw FramingLearningError.stale }
            dataset.votes.removeAll { $0.runID == vote.runID && $0.referenceID == vote.referenceID }
            dataset.votes.append(vote)
        }
    }
    public func savePolicy(_ policy: FramingPolicy?, replacing profile: String, intent: FramingIntent,
                           baselineFingerprint: String? = nil, evidence: FramingEvidence? = nil,
                           expectedRevision: UInt64, cancellation: FramingMutationToken? = nil) async throws -> FramingDataset {
        try await change(expectedRevision: expectedRevision, cancellation: cancellation) { dataset in
            let fingerprint = baselineFingerprint ?? policy?.baseline.fingerprint
            let context = evidence ?? policy?.evidence
            dataset.policies.removeAll { $0.baseline.name == profile && $0.intent == intent
                && (fingerprint == nil || $0.baseline.fingerprint == fingerprint)
                && (context == nil || $0.evidence == context) }
            if let policy { dataset.policies.append(policy) }
        }
    }
    public func sourceMetadata(_ url: URL) async throws -> (FramingSourceRevision, Data?) {
        try await perform { (try FramingSourceRevision.read(url), try? url.bookmarkData(options: .minimalBookmark)) }
    }
}

/// Cancellation has an explicit atomic-write cutoff. Once commit starts, finish the single-file transaction.
public final class FramingMutationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var committing = false
    public init() {}
    @discardableResult public func cancel() -> Bool {
        lock.withLock { guard !committing else { return false }; cancelled = true; return true }
    }
    func beginCommit() throws {
        try lock.withLock { if cancelled { throw CancellationError() }; committing = true }
    }
}
