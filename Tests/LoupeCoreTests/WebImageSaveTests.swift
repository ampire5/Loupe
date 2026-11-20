import Foundation
import Testing
@testable import LoupeCore

@Suite struct WebImageSaveTests {
    @Test func simultaneousSavesPreserveBothOriginalsAndSanitizeNames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Data([1, 2, 3]), second = Data([4, 5, 6])
        async let a = WebImageFiles.save(first, named: "../fox.jpg", to: folder)
        async let b = WebImageFiles.save(second, named: "../fox.jpg", to: folder)
        let (one, two) = try await (a, b)
        #expect(Set([one.lastPathComponent, two.lastPathComponent]) == ["fox.jpg", "fox 2.jpg"])
        #expect(try Data(contentsOf: one) == first)
        #expect(try Data(contentsOf: two) == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    }

    @Test func absentDestinationIsReportedWithoutCreatingIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: WebImageFiles.FileError.missingDestination) {
            try WebImageFiles.save(Data([1]), named: "photo.jpg", to: folder)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
