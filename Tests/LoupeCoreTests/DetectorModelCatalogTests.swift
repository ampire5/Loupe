import Foundation
import Testing
@testable import LoupeCore

@Test func localModelCatalogShowsResolutionAndExcludesIncompletePackages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, size) in [("small", 320), ("large", 640)] {
        let url = root.appendingPathComponent(name + ".mlmodelc")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data().write(to: url.appendingPathComponent("coremldata.bin"))
        let data = try JSONSerialization.data(withJSONObject: [["inputSchema": [["type": "Image", "width": String(size), "height": String(size)]]]])
        try data.write(to: url.appendingPathComponent("metadata.json"))
    }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("incomplete.mlmodelc"), withIntermediateDirectories: true)
    let entries = DetectorModelCatalog.scan(selected: "", configured: "", directories: [root])
    #expect(entries.count == 2)
    #expect(entries.map(\.title) == ["large · 640×640", "small · 320×320"])
}
