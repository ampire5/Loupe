/// The text of the config problems overlay (Task 17c), as a pure function so what the box says is tested
/// without AppKit: a header, then the warnings as `Config.parse` and `InputConf.parse` word them (loupe.conf's, then
/// input.conf's; each names its file), as many as fit and "…and N more".
public enum ConfigWarningsText {
    /// Warnings listed before the rest are summed up; a long file full of typos must not cover the picture.
    public static let maxListed = 8

    /// nil when there is nothing to say.
    public static func block(for warnings: [String], maxListed: Int = ConfigWarningsText.maxListed) -> String? {
        guard !warnings.isEmpty else { return nil }
        let count = warnings.count
        var lines = ["Config: \(count) problem\(count == 1 ? "" : "s"), ignored — defaults used"]
        lines += warnings.prefix(maxListed)
        if count > maxListed { lines.append("…and \(count - maxListed) more") }
        return lines.joined(separator: "\n")
    }
}
