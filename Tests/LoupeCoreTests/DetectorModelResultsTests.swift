import Testing
import Vision
@testable import LoupeCore

@Test func detectorRejectsClassifierResultsInsteadOfTreatingThemAsNoObjects() {
    #expect(ModelDetector.objectResults(nil) == nil)
    #expect(ModelDetector.objectResults([])?.isEmpty == true)
    #expect(ModelDetector.objectResults([VNClassificationObservation()]) == nil)
}
