import Foundation

/// Serializes profile edits across windows; reads, backups and atomic writes stay off-main.
public enum DetectorProfileFiles {
    private static let queue = DispatchQueue(label: "loupe.profile-files", qos: .utility)
    public static func edit(_ url: URL, transform: @escaping @Sendable (String) throws -> String) async throws -> DetectorSetup {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    if exists && !FileManager.default.isWritableFile(atPath: url.path) { throw CocoaError(.fileWriteNoPermission) }
                    let original = exists ? try String(contentsOf: url, encoding: .utf8) : ""
                    let updated = try transform(original)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let backup = url.appendingPathExtension("before-profile-editor")
                    if exists && !FileManager.default.fileExists(atPath: backup.path) { try original.write(to: backup, atomically: true, encoding: .utf8) }
                    try updated.write(to: url, atomically: true, encoding: .utf8)
                    continuation.resume(returning: DetectorSetup.load(from: url).0)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
