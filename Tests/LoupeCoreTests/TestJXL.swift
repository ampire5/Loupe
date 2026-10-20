import Foundation
import Testing

/// JPEG XL made by the reference encoder (Homebrew's cjxl), so decoders are tested on real libjxl output.
enum TestJXL {
    static let cjxlPath = "/opt/homebrew/bin/cjxl"
    static let available = FileManager.default.isExecutableFile(atPath: cjxlPath)

    /// `input` (any file cjxl reads, named `inputName`: a .jpg is transcoded losslessly by default) encoded to JXL.
    static func encode(_ input: Data, arguments: [String] = [], inputName: String = "in.png") throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-jxl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent(inputName), output = dir.appendingPathComponent("out.jxl")
        try input.write(to: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cjxlPath)
        process.arguments = [source.path, output.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return try Data(contentsOf: output)
    }
}
