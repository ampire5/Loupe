import CoreML
import CoreVideo
import CryptoKit
import Foundation

public struct NeuralUpscaleModel: Hashable, Sendable {
    public enum Scale: Int, CaseIterable, Sendable {
        case double = 2
        case quadruple = 4

        public var title: String { "\(rawValue)×" }
    }

    struct ImageInterface {
        let input, output: String
        let width, height: Int
        let scale: Scale

        init(_ description: MLModelDescription) throws {
            let inputs = description.inputDescriptionsByName
            let outputs = description.outputDescriptionsByName.filter { $0.value.type == .image }
            guard inputs.count == 1, outputs.count == 1,
                  let input = inputs.first, let output = outputs.first,
                  let source = input.value.imageConstraint, let result = output.value.imageConstraint,
                  (1...2048).contains(source.pixelsWide), (1...2048).contains(source.pixelsHigh),
                  source.pixelFormatType == kCVPixelFormatType_32BGRA,
                  result.pixelFormatType == kCVPixelFormatType_32BGRA,
                  let scale = Scale.allCases.first(where: { result.pixelsWide == source.pixelsWide * $0.rawValue
                      && result.pixelsHigh == source.pixelsHigh * $0.rawValue })
            else { throw NeuralUpscaleError.incompatibleModel }
            self.input = input.key
            self.output = output.key
            self.width = source.pixelsWide
            self.height = source.pixelsHigh
            self.scale = scale
        }
    }

    public enum Compute: String, Codable, Hashable, CaseIterable, Sendable {
        case cpuAndGPU, cpuAndNeuralEngine, all
        var units: MLComputeUnits {
            switch self {
            case .cpuAndGPU: .cpuAndGPU
            case .cpuAndNeuralEngine: .cpuAndNeuralEngine
            case .all: .all
            }
        }
    }

    public var name: String
    public let url: URL
    public let revision: SHA256Digest
    public var margin: Int
    public var compute: Compute

    var isPackage: Bool { url.pathExtension.lowercased() == "mlpackage" }

    /// Inspect the compiled image interface without loading an inference model.
    public func nativeScale() async throws -> Scale {
        let compiled = if isPackage { try await MLModel.compileModel(at: url) } else { url }
        defer { if isPackage { try? FileManager.default.removeItem(at: compiled) } }
        let asset = try MLModelAsset(url: compiled)
        let description = try await asset.modelDescription
        return try ImageInterface(description).scale
    }

    private struct Configuration: Decodable {
        let name: String?
        let margin: Int?
        let compute: Compute?
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Loupe/Upscale Models", isDirectory: true)
    }

    /// A catalog contains packages and compiled directories. The identity includes model files and sidecar defaults.
    /// Call from a worker. Reading the model interface is a separate operation.
    public static func scan(_ directory: URL) -> [Self] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let children = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
        return children.filter { ["mlpackage", "mlmodelc"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(64).map { entry in
                let url = entry.standardizedFileURL
                let sidecar = url.appendingPathExtension("json")
                let configuration: Configuration? = {
                    guard let handle = try? FileHandle(forReadingFrom: sidecar) else { return nil }
                    defer { try? handle.close() }
                    guard let data = try? handle.read(upToCount: 16_384) else { return nil }
                    return try? JSONDecoder().decode(Configuration.self, from: data)
                }()
                let files = manager.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                               options: [.skipsHiddenFiles])
                var revision = SHA256()
                let members = files.map { $0.prefix(256).compactMap { $0 as? URL } } ?? []
                for item in ([url, sidecar] + members).sorted(by: { $0.path < $1.path }) {
                    let values = try? item.resourceValues(forKeys: keys)
                    let stamp = values?.contentModificationDate?.timeIntervalSinceReferenceDate
                    revision.update(data: Data("\(item.path.utf8.count):\(item.path):\(stamp ?? 0):\(values?.fileSize ?? 0)".utf8))
                }
                return Self(name: configuration?.name ?? url.deletingPathExtension().lastPathComponent,
                            url: url, revision: revision.finalize(), margin: configuration?.margin ?? 16,
                            compute: configuration?.compute ?? .cpuAndGPU)
            }
    }
}
