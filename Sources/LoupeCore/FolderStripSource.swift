import Foundation

public struct FolderStripEntry: Equatable, Sendable {
    public let id: FolderStripID
    public var parent: FolderStripID?
    public var title: String
    public var depth: Int
    public var photoCount: Int?
    public init(id: FolderStripID, parent: FolderStripID? = nil, title: String, depth: Int = 0, photoCount: Int? = nil) {
        self.id = id; self.parent = parent; self.title = title; self.depth = depth; self.photoCount = photoCount
    }
}
public protocol FolderStripSource: Sendable {
    func rows(around: FolderStripID) async throws -> [FolderStripEntry]
    func children(of: FolderStripID) async throws -> [FolderStripEntry]
    func target(for: FolderStripID) async throws -> FolderTarget?
}

/// Server order and IDs are authoritative; disk hierarchy must never leak into a gallery list.
public struct FolderStripGallerySource: FolderStripSource {
    private let loadRows: @Sendable (FolderStripID) async throws -> [FolderStripEntry]
    private let loadTarget: @Sendable (FolderStripID) async throws -> FolderTarget?
    public init(rows: @escaping @Sendable (FolderStripID) async throws -> [FolderStripEntry],
                target: @escaping @Sendable (FolderStripID) async throws -> FolderTarget?) {
        loadRows = rows; loadTarget = target
    }
    public func rows(around id: FolderStripID) async throws -> [FolderStripEntry] { try await loadRows(id) }
    public func children(of id: FolderStripID) async throws -> [FolderStripEntry] { [] }
    public func target(for id: FolderStripID) async throws -> FolderTarget? { try await loadTarget(id) }
}
