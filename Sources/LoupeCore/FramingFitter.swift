import Foundation

public struct FramingFitBudget: Sendable {
    public var maximumEvaluations: Int
    public var candidateLimit: Int
    public var epochs: Int
    // Conservative serial starting budgets, benchmarked in docs/bench/2026-11-04-smartzoom-learning.md before release.
    public static let standard = Self(maximumEvaluations: 160, candidateLimit: 96, epochs: 16)
    public static let testing = Self(maximumEvaluations: 16, candidateLimit: 24, epochs: 3)
}

public struct FramingFitSample: Sendable, Identifiable {
    public var id: UUID
    public var baseline: FramingErrorReport
    public var candidate: FramingErrorReport
    public var candidateView: FramingGeometry
    public var baselineView: FramingGeometry
    public var bestProposalLoss: Double
}

public struct FramingFitResult: Sendable {
    public var id = UUID()
    public var baseline: FramingProfile
    public var policy: FramingPolicy
    public var evaluations: Int
    public var trainingLoss: Double
    public var validationLoss: Double?
    public var baselineTrainingLoss: Double
    public var samples: [FramingFitSample]
    public var exploratory: Bool
}

public enum FramingFitter {
    /// All arithmetic runs on the detached utility executor. Checkpoints yield to foreground work without polling.
    public static func fit(profile: FramingProfile, references: [FramingReference], intent: FramingIntent = .detail,
                           budget: FramingFitBudget = .standard,
                           checkpoint: @escaping @Sendable () async throws -> Void = { try Task.checkCancellation() },
                           progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> FramingFitResult {
        try await checkpoint()
        let job = Task.detached(priority: .utility) {
            try await run(profile: profile, references: references, intent: intent, budget: budget,
                          checkpoint: checkpoint, progress: progress)
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
    private static func run(profile: FramingProfile, references: [FramingReference], intent: FramingIntent,
                            budget: FramingFitBudget, checkpoint: @escaping @Sendable () async throws -> Void,
                            progress: @escaping @Sendable (Int, Int) -> Void) async throws -> FramingFitResult {
        let rows = references.filter { $0.profile.name == profile.name && $0.intent == intent && $0.isValid }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let training = rows.filter { !$0.validation }
        guard let first = training.first, profile.isValid, budget.maximumEvaluations > 0,
              budget.candidateLimit > 0, budget.epochs > 0 else { throw FramingLearningError.empty }
        guard Set(rows.map(\.id)).count == rows.count else { throw FramingLearningError.invalid }
        let trainingSources = Set(training.map { $0.source.standardizedFileURL })
        guard rows.filter(\.validation).allSatisfy({ !trainingSources.contains($0.source.standardizedFileURL) }) else { throw FramingLearningError.split }
        guard rows.allSatisfy({ $0.evidence == first.evidence }) else { throw FramingLearningError.stale }
        var tuned = profile, evaluations = 0
        func loss(_ profile: FramingProfile) -> Double {
            FramingEvaluation.aggregate(training) { r in
                FramingEvaluation.measure(reference: r, predicted: FramingReplay.transform(reference: r, profile: profile)).loss
            }
        }
        let initialLoss = loss(profile)
        var bestLoss = initialLoss
        // Finite coordinate search. The learned scorer is primary; numeric tuning improves its geometric proposals.
        for step in [0.2, 0.08, 0.025] {
            let neighbors = FramingParameters.neighbors(profile: tuned, references: training, step: step)
            for candidate in neighbors {
                if evaluations >= budget.maximumEvaluations { break }
                try Task.checkCancellation(); try await checkpoint()
                let next = loss(candidate); evaluations += 1
                if next < bestLoss - 1e-8 { tuned = candidate; bestLoss = next }
                progress(evaluations, budget.maximumEvaluations)
            }
        }
        let kinds = Array(Set(training.flatMap { $0.instances.map(\.kind) })).sorted { $0.rawValue < $1.rawValue }
        let example = FramingFeatures.values(input: first.input.transform, boxes: first.boxes, evidence: first.evidence,
                                             crop: first.target.transform, kinds: kinds)
        var weights = Array(repeating: 0.0, count: example.count)
        let series = Dictionary(grouping: training, by: \.group)
        // Stream one sample's proposals at a time. No dataset × candidate × feature tensor is retained.
        for epoch in 0..<budget.epochs {
            for row in training {
                try Task.checkCancellation(); try await checkpoint()
                let ideal = FramingFeatures.values(input: row.input.transform, boxes: row.boxes, evidence: row.evidence,
                                                    crop: row.target.transform, kinds: kinds)
                let proposals = FramingCandidates.generate(reference: row, profile: tuned, limit: budget.candidateLimit)
                let sampleWeight = 1 / Double(series.count * series[row.group]!.count)
                for proposal in proposals {
                    let f = FramingFeatures.values(input: row.input.transform, boxes: row.boxes, evidence: row.evidence,
                                                  crop: proposal, kinds: kinds)
                    let difference = zip(f, ideal).map(-)
                    let margin = min(2, FramingEvaluation.measure(reference: row, predicted: proposal).loss)
                    let predicted = zip(weights, difference).map(*).reduce(0, +)
                    let norm = difference.map { $0 * $0 }.reduce(0, +) + 0.1
                    let update = min(1, max(0, margin - predicted) / norm) * sampleWeight / sqrt(Double(epoch + 1))
                    for j in weights.indices { weights[j] = weights[j] * (1 - 0.001 * sampleWeight) + update * difference[j] }
                }
            }
        }
        let policy = FramingPolicy(baseline: profile, profile: tuned, intent: intent, analysisID: first.evidence.analysisID,
            evidence: first.evidence, kinds: kinds, coefficients: weights, candidateLimit: budget.candidateLimit)
        var reports: [FramingFitSample] = []
        for row in rows {
            try Task.checkCancellation(); try await checkpoint()
            let baseline = FramingReplay.transform(reference: row, profile: profile)
            let candidate = policy.predict(input: row.input.transform, boxes: row.boxes, evidence: row.evidence,
                                          profile: profile, behavior: row.behavior) ?? baseline
            let proposals = FramingCandidates.generate(reference: row, profile: tuned, limit: budget.candidateLimit)
            reports.append(.init(id: row.id, baseline: FramingEvaluation.measure(reference: row, predicted: baseline),
                candidate: FramingEvaluation.measure(reference: row, predicted: candidate), candidateView: try FramingGeometry(candidate),
                baselineView: try FramingGeometry(baseline),
                bestProposalLoss: proposals.map { FramingEvaluation.measure(reference: row, predicted: $0).loss }.min() ?? 0))
        }
        let byID = Dictionary(uniqueKeysWithValues: reports.map { ($0.id, $0) })
        let heldOut = rows.filter(\.validation)
        return .init(baseline: profile, policy: policy, evaluations: evaluations,
            trainingLoss: FramingEvaluation.aggregate(training) { byID[$0.id]!.candidate.loss },
            validationLoss: heldOut.isEmpty ? nil : FramingEvaluation.aggregate(heldOut) { byID[$0.id]!.candidate.loss },
            baselineTrainingLoss: initialLoss, samples: reports, exploratory: series.count < 3 || heldOut.isEmpty)
    }
}
