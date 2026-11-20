import Foundation
import Testing
@testable import LoupeCore

struct FramingFitterTests {
    @Test func lateExplicitGroupsAreProposedBeyondSpatialNeighbors() throws {
        var sample = try FramingReferenceTests.sample()
        let cat = SubjectKind(rawValue: "cat")!, ball = SubjectKind(rawValue: "ball")!, cup = SubjectKind(rawValue: "cup")!
        let pair = SubjectKind(rawValue: "cat+ball")!
        sample.profile.chain = [.face, pair]
        sample.profile.composition.maxZoom = 4
        sample.profile.composition.maxCrop[.face] = 1
        sample.input = try FramingGeometry(ViewTransform(imageSize: .init(width: 1600, height: 1200),
            viewSize: .init(width: 1500, height: 300), mode: .fit))
        sample.boxes.faces = [.init(x: 0.5, y: 0.02, width: 0.1, height: 0.1)]
        sample.boxes.detections = [
            .init(kind: cat, rect: .init(x: 0.12, y: 0.78, width: 0.08, height: 0.1), score: 1),
            .init(kind: ball, rect: .init(x: 0.8, y: 0.78, width: 0.08, height: 0.1), score: 1)
        ] + (0..<10).map { i in
            .init(kind: cup, rect: .init(x: 0.4 + Double(i) * 0.015, y: 0.78, width: 0.04, height: 0.1), score: 1)
        }
        sample.evidence.classes = ["CAT": cat, "BALL": ball, "CUP": cup]
        let composition = try #require(SubjectFraming.composition(sample.boxes, kind: pair,
            options: sample.profile.composition, imageSize: sample.input.imageSize, framing: sample.evidence.framing))
        let expected = composition.resolve(sample.input.transform, autoZoom: true, size: sample.profile.size).transform
        let proposals = FramingCandidates.generate(reference: sample, profile: sample.profile, limit: 96)
        #expect(proposals.contains { abs($0.scale - expected.scale) < 1e-8 && $0.center == expected.center })
    }
    @Test func candidatesIncludeInstancesAndVisionAndAreBounded() throws {
        var sample = try FramingReferenceTests.sample()
        sample.boxes.people = [.init(x: 0.1, y: 0.1, width: 0.4, height: 0.8)]
        sample.boxes.saliency = [.init(x: 0.7, y: 0.4, width: 0.1, height: 0.1)]
        let proposals = FramingCandidates.generate(reference: sample, profile: sample.profile, limit: 48)
        #expect(proposals.count <= 48 && proposals.count > 3)
        #expect(proposals.allSatisfy { $0.scale.isFinite && $0.center.x.isFinite })
        #expect(proposals.contains { $0.center.x > 0.5 })
    }
    @Test func fittingIsDeterministicAndValidationDoesNotTrain() async throws {
        var sample = try FramingReferenceTests.sample()
        sample.target = try FramingGeometry(FramingReplay.transform(reference: sample, profile: sample.profile))
        let first = try await FramingFitter.fit(profile: sample.profile, references: [sample], budget: .testing)
        var heldOut = sample; heldOut.id = UUID(); heldOut.validation = true; heldOut.group = "held-out"
        heldOut.source = URL(fileURLWithPath: "/held-out.jpg")
        heldOut.target.center.x = 0.7
        let second = try await FramingFitter.fit(profile: sample.profile, references: [sample, heldOut], budget: .testing)
        #expect(first.policy == second.policy)
        #expect(first.trainingLoss.isFinite && first.evaluations <= FramingFitBudget.testing.maximumEvaluations)
        #expect(second.validationLoss != nil)
    }
    @Test func differentIntentsDoNotTrainOneCompromise() async throws {
        let sample = try FramingReferenceTests.sample()
        var other = sample; other.id = UUID(); other.intent = .overview
        let one = try await FramingFitter.fit(profile: sample.profile, references: [sample], budget: .testing)
        let two = try await FramingFitter.fit(profile: sample.profile, references: [sample, other], budget: .testing)
        #expect(one.policy == two.policy)
    }
    @Test func cancellationAndEmptyTrainingAreExplicit() async throws {
        let sample = try FramingReferenceTests.sample()
        await #expect(throws: Error.self) {
            try await FramingFitter.fit(profile: sample.profile, references: [], budget: .testing)
        }
        let task = Task { try await FramingFitter.fit(profile: sample.profile, references: [sample], budget: .testing,
            checkpoint: { throw CancellationError() }) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func policyRoundTripAndMismatchFallback() async throws {
        let sample = try FramingReferenceTests.sample()
        let run = try await FramingFitter.fit(profile: sample.profile, references: [sample], budget: .testing)
        let policy = try JSONDecoder().decode(FramingPolicy.self, from: JSONEncoder().encode(run.policy))
        #expect(policy == run.policy)
        var wrong = sample.evidence; wrong.analysisID = "other-detector"
        #expect(policy.predict(input: sample.input.transform, boxes: sample.boxes, evidence: wrong,
            profile: sample.profile, behavior: .auto) == nil)
    }
    @Test func learnsDistinctDetailAndOverviewWithoutAveraging() async throws {
        var sample = try FramingReferenceTests.sample()
        let proposals = FramingCandidates.generate(reference: sample, profile: sample.profile, limit: 48)
        let close = try #require(proposals.max(by: { $0.scale < $1.scale }))
        sample.target = try FramingGeometry(close)
        var wide = sample; wide.id = UUID(); wide.intent = .overview
        wide.target = try FramingGeometry(sample.input.transform.withMode(.fit))
        let budget = FramingFitBudget(maximumEvaluations: 16, candidateLimit: 48, epochs: 16)
        let detail = try await FramingFitter.fit(profile: sample.profile, references: [sample, wide], budget: budget)
        let overview = try await FramingFitter.fit(profile: sample.profile, references: [sample, wide], intent: .overview, budget: budget)
        #expect(detail.samples[0].candidateView.scale > overview.samples[0].candidateView.scale)
        #expect(detail.trainingLoss < detail.baselineTrainingLoss)
    }
    @Test func frameOccupancyConditionsFeaturesRatherThanUniversalCategoryWeights() throws {
        let sample = try FramingReferenceTests.sample()
        var far = sample.boxes; far.faces[0].size = .init(width: 0.05, height: 0.05)
        let crop = sample.target.transform
        let nearFeatures = FramingFeatures.values(input: sample.input.transform, boxes: sample.boxes,
            evidence: sample.evidence, crop: crop, kinds: [.face])
        let farFeatures = FramingFeatures.values(input: sample.input.transform, boxes: far,
            evidence: sample.evidence, crop: crop, kinds: [.face])
        #expect(nearFeatures != farFeatures)
    }
    @Test func detailAndOverviewPoliciesMatchTheSameExternalProfile() async throws {
        var sample = try FramingReferenceTests.sample()
        var wide = sample; wide.id = UUID(); wide.intent = .overview
        wide.target = try FramingGeometry(wide.input.transform.withMode(.fit))
        sample.target = try FramingGeometry(sample.input.transform.withMode(.actual(2)).clamped)
        for intent in FramingIntent.allCases {
            let run = try await FramingFitter.fit(profile: sample.profile, references: [sample, wide], intent: intent, budget: .testing)
            #expect(run.policy.baseline.fingerprint == sample.profile.fingerprint)
            #expect(run.policy.predict(input: sample.input.transform, boxes: sample.boxes, evidence: sample.evidence,
                profile: sample.profile, behavior: .auto) != nil)
        }
    }
    @Test func denseScenesStillProposeNewNeighborGroups() throws {
        var sample = try FramingReferenceTests.sample()
        sample.profile.composition.maxZoom = 4
        sample.profile.composition.maxCrop[.face] = 1
        sample.boxes.faces = (0..<32).map { i in
            CGRect(x: 0.12 + Double(i % 8) * 0.1, y: 0.12 + Double(i / 8) * 0.18, width: 0.12, height: 0.12)
        }
        let selected = Array(sample.boxes.faces.prefix(2)).map { SubjectComposition.Region(kind: .face, rect: $0) }
        let c = try #require(SubjectFraming.composition(sample.boxes, selected: selected, expandHeads: false,
            options: sample.profile.composition, imageSize: sample.input.imageSize, framing: sample.evidence.framing))
        let expected = c.resolve(sample.input.transform, autoZoom: true, size: sample.profile.size).transform
        let proposals = FramingCandidates.generate(reference: sample, profile: sample.profile, limit: 20)
        #expect(proposals.contains { abs($0.scale - expected.scale) < 1e-8 && $0.center == expected.center })
    }
    @Test func samePhotoCannotLeakAcrossTrainingAndValidation() async throws {
        let sample = try FramingReferenceTests.sample()
        var other = sample; other.id = UUID(); other.group = "other-series"; other.validation = true
        await #expect(throws: Error.self) {
            try await FramingFitter.fit(profile: sample.profile, references: [sample, other], budget: .testing)
        }
    }
    @Test func duplicateReferenceIdentityIsRejectedWithoutATrap() async throws {
        let sample = try FramingReferenceTests.sample()
        await #expect(throws: Error.self) {
            try await FramingFitter.fit(profile: sample.profile, references: [sample, sample], budget: .testing)
        }
    }
}
