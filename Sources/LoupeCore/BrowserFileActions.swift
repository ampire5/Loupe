import Foundation

/// Why a new name is refused (file browser spec §4.3); `text` is the line under the name field.
public enum RenameProblem: Error, Equatable, CaseIterable, Sendable {
    case empty, slash, colon, leadingDot, exists

    public var text: String {
        switch self {
        case .empty: "A name cannot be empty."
        case .slash: "A name cannot contain “/”."
        case .colon: "A name cannot contain “:”."
        case .leadingDot: "A name starting with “.” would hide the item."
        case .exists: "An item with this name is already here."
        }
    }
}

extension RenameProblem: LocalizedError {
    public var errorDescription: String? { text }
}

/// The volume has no Trash (often an SMB share): the app asks before deleting for good.
public enum BrowserTrashError: Error, Equatable, Sendable {
    case noTrash
}

/// The file browser's Rename and Move to Trash (file browser spec §4.3). After a rename the stores that keep paths
/// (positions, Recent, sessions, folder settings, pins) follow it. Blocking: run off the main thread.
public struct BrowserFileActions: Sendable {
    public typealias Trasher = @Sendable (URL) throws -> Void

    private let stores: [any PathMoving]
    private let trasher: Trasher

    public init(stores: [any PathMoving],
                trasher: @escaping Trasher = { _ = try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.stores = stores
        self.trasher = trasher
    }

    public static func validate(_ name: String) -> RenameProblem? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        if name.contains("/") { return .slash }
        if name.contains(":") { return .colon }
        if name.hasPrefix(".") { return .leadingDot }
        return nil
    }

    /// `url` renamed to `name` in its folder; its new URL. A change of case alone goes through a temporary name, which
    /// a case-insensitive volume needs.
    public func rename(_ url: URL, to name: String) throws -> URL {
        if let problem = Self.validate(name) { throw problem }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        let fm = FileManager.default
        let caseOnly = name != url.lastPathComponent && name.lowercased() == url.lastPathComponent.lowercased()
        if caseOnly {
            let step = url.deletingLastPathComponent().appendingPathComponent(".loupe-rename-\(UUID().uuidString)")
            try fm.moveItem(at: url, to: step)
            do { try fm.moveItem(at: step, to: target) } catch {
                try? fm.moveItem(at: step, to: url)
                throw error
            }
        } else {
            guard !fm.fileExists(atPath: target.path) else { throw RenameProblem.exists }
            try fm.moveItem(at: url, to: target)
        }
        for store in stores { store.movePaths(from: url, to: target) }
        return target
    }

    /// To the Trash; `permanently` deletes for good (after the app asked). A volume without a Trash is `noTrash`.
    public func trash(_ url: URL, permanently: Bool) throws {
        if permanently {
            try FileManager.default.removeItem(at: url)
            return
        }
        do {
            try trasher(url)
        } catch let error as CocoaError where error.code == .featureUnsupported || error.code == .fileWriteVolumeReadOnly {
            throw BrowserTrashError.noTrash
        }
    }
}
