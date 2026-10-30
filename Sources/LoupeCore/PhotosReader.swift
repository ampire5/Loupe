import Foundation

/// Shares the existing image-cache read boundary; Photos identities never enter the filesystem reader.
public struct PhotosReader: FileReading {
    private let fallback: any FileReading
    private let load: @Sendable (URL, ReadPriority) async throws -> FileBytes
    private let sourceStamp: @Sendable (URL) async throws -> FileStamp

    public init(fallback: any FileReading = FileReader(),
                load: @escaping @Sendable (URL, ReadPriority) async throws -> FileBytes = { try await PhotosLibrary.shared.read($0, priority: $1) },
                sourceStamp: @escaping @Sendable (URL) async throws -> FileStamp = { try await PhotosLibrary.shared.stamp($0) }) {
        self.fallback = fallback
        self.load = load
        self.sourceStamp = sourceStamp
    }

    public func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes {
        if PhotosLocation.asset(in: url) != nil { return try await load(url, priority) }
        return try await fallback.read(url, priority: priority)
    }
    public func readPrefix(_ url: URL, priority: ReadPriority, isEnough: @escaping @Sendable (Data) -> Bool) async throws -> FileBytes {
        if PhotosLocation.asset(in: url) != nil { return try await load(url, priority) }
        return try await fallback.readPrefix(url, priority: priority, isEnough: isEnough)
    }
    public func stamp(_ url: URL, priority: Int) async throws -> FileStamp {
        if PhotosLocation.asset(in: url) != nil { return try await sourceStamp(url) }
        return try await fallback.stamp(url, priority: priority)
    }
    public func stamp(_ url: URL, priority: ReadPriority, started: @escaping @Sendable () -> Void) async throws -> FileStamp {
        if PhotosLocation.asset(in: url) != nil { started(); return try await sourceStamp(url) }
        return try await fallback.stamp(url, priority: priority, started: started)
    }
}
