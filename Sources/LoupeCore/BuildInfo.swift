import Foundation

/// Which build is running, for Loupe › About Loupe: `scripts/make-app.sh` stamps the commit (`+dirty` with
/// uncommitted changes), branch, build time and an optional label (`LOUPE_BUILD_LABEL`, `--label`) into Info.plist.
/// A build without them (`swift run`, no git) reads "unknown".
public struct BuildInfo: Equatable, Sendable {
    public static let commitKey = "LoupeBuildCommit"
    public static let branchKey = "LoupeBuildBranch"
    public static let dateKey = "LoupeBuildDate"
    public static let labelKey = "LoupeBuildLabel"

    public let version: String
    public let commit: String
    public let branch: String
    public let date: String
    /// nil when the build was not given one.
    public let label: String?

    public init(info: [String: Any]) {
        func value(_ key: String) -> String? {
            (info[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        version = value("CFBundleShortVersionString") ?? "unknown"
        commit = value(Self.commitKey) ?? "unknown"
        branch = value(Self.branchKey) ?? "unknown"
        date = value(Self.dateKey) ?? "unknown"
        label = value(Self.labelKey)
    }

    /// `cb8586f · night-lts · 2026-10-22 14:05`.
    public var line: String { "\(commit) · \(branch) · \(date)" }

    /// The panel's bracketed version after the app's: the label, else the commit.
    public var short: String { label ?? commit }

    /// The panel's credits (selectable there): the label's line, then the build line.
    public var credits: String { label.map { "Build \($0)\n" + line } ?? line }
}
