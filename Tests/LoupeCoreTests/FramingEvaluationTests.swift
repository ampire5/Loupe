import Foundation
import Testing
@testable import LoupeCore

struct FramingEvaluationTests {
    @Test func identicalHasZeroErrorAndSeparatePanComponents() throws {
        let sample = try FramingReferenceTests.sample()
        let exact = FramingEvaluation.measure(reference: sample, predicted: sample.target.transform)
        #expect(exact.loss == 0)
        var moved = sample.target.transform; moved.center.x += 0.1
        let error = FramingEvaluation.measure(reference: sample, predicted: moved)
        #expect(abs(error.dx) > 0 && error.dy == 0 && error.logScale == 0)
        #expect(error.elements[0].dx != 0 && error.loss > 0)
    }
    @Test func clippingDoesNotMoveTheMeasuredCenterAndExclusionsAreValid() throws {
        var sample = try FramingReferenceTests.sample()
        sample.boxes.faces = [.init(x: 0.01, y: 0.3, width: 0.2, height: 0.2)]
        let exact = FramingEvaluation.measure(reference: sample, predicted: sample.target.transform)
        #expect(exact.loss == 0)
        #expect(exact.elements[0].referenceVisibility == 0)
        #expect(exact.elements[0].referenceCenter.x < 0)
    }
    @Test func allVisionCategoriesAndRepeatedObjectsHaveStableIdentity() throws {
        var sample = try FramingReferenceTests.sample()
        sample.boxes.faces.append(sample.boxes.faces[0])
        sample.boxes.people = [.init(x: 0.2, y: 0.2, width: 0.5, height: 0.7)]
        sample.boxes.saliency = [.init(x: 0.3, y: 0.3, width: 0.2, height: 0.2)]
        sample.boxes.objects = [.init(x: 0.5, y: 0.5, width: 0.1, height: 0.1)]
        let report = FramingEvaluation.measure(reference: sample, predicted: sample.target.transform)
        #expect(Set(report.elements.map(\.id)).count == 5)
        #expect(Set(report.elements.map(\.kind)) == Set(SubjectKind.vision))
    }
    @Test func replayUsesFrozenContextAndMatchesProduction() throws {
        var sample = try FramingReferenceTests.sample()
        let kind = SubjectKind(rawValue: "cat")!
        sample.profile.chain = [kind]
        sample.boxes.faces = []
        sample.boxes.detections = [.init(kind: kind, rect: .init(x: 0.2, y: 0.3, width: 0.1, height: 0.2), score: 0.4)]
        sample.evidence.selectionThreshold = 0.3
        let output = FramingReplay.transform(reference: sample, profile: sample.profile)
        #expect(output.scale > sample.input.transform.fitScale)
        sample.evidence.selectionThreshold = 0.5
        #expect(FramingReplay.transform(reference: sample, profile: sample.profile).mode == .fit)
        sample.behavior = .pan
        #expect(FramingReplay.transform(reference: sample, profile: sample.profile).scale == sample.input.scale)
    }
    @Test func duplicateInstancesDoNotMultiplyCategoryWeight() throws {
        var sample = try FramingReferenceTests.sample()
        var moved = sample.target.transform; moved.center.x += 0.05
        let one = FramingEvaluation.measure(reference: sample, predicted: moved).loss
        sample.boxes.faces = Array(repeating: sample.boxes.faces[0], count: 10)
        #expect(abs(FramingEvaluation.measure(reference: sample, predicted: moved).loss - one) < 1e-12)
    }
}
