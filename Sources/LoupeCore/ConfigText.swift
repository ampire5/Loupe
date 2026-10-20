import Foundation

/// The line without its comment, trimmed. A comment starts at `#` at line start or after whitespace, but
/// not where the value begins (see `commentStart`).
func stripComment(_ line: String) -> String {
    let content = commentStart(in: line).map { String(line[..<$0]) } ?? line
    return content.trimmingCharacters(in: .whitespaces)
}

/// Index of the `#` that starts a comment: at line start or after whitespace (so `C#` in a path is kept).
/// A `#` that begins the value, after the first `=` and any spaces, is the value's when text follows it at once
/// (`background = #333`, as every other key takes `key = value`); `key = # note` is an empty value and a comment.
/// A comment after the value still starts at a later ` #`.
func commentStart(in line: String) -> String.Index? {
    var previous: Character?
    var sawEquals = false, inValue = false
    for i in line.indices {
        let c = line[i]
        if sawEquals && !inValue && !c.isWhitespace {
            inValue = true
            let next = line.index(after: i)
            if c == "#", next == line.endIndex || line[next].isWhitespace { return i }
            previous = c
            continue
        }
        if c == "#", previous?.isWhitespace ?? true { return i }
        if c == "=" { sawEquals = true }
        previous = c
    }
    return nil
}

/// Shortest text for a number: `100`, `33.3`, `2.5`.
func formatNumber(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
}

/// Edits loupe.conf text in place (ported from FrameScrub): the user's comments, blank lines, order and
/// unknown lines are kept; only the lines for the given keys change. The View menu writes through this,
/// so a hand-edited file survives a click.
public enum ConfigText {
    public static let header = "# Loupe settings (mpv-style key=value). The View menu edits values in place and keeps your comments."

    /// For each pair, rewrites the last active `key=value` line with that key (an inline comment is
    /// kept) or inserts the line if the key has none: right after the key's last commented example
    /// (`#   key=value   (default)`), else at the end. The last active line because that is the one `Config.parse`
    /// lets win: editing an earlier duplicate would change nothing. Commented-out lines never count as active.
    public static func setting(_ values: [(key: String, value: String)], in text: String) -> String {
        var lines = text.isEmpty ? [header, ""] : text.components(separatedBy: "\n")
        for (key, value) in values {
            let line = "\(key)=\(value)"
            if let i = lines.lastIndex(where: { configKey(of: $0) == key }) {
                lines[i] = line + trailingComment(of: lines[i])
            } else if let i = lines.lastIndex(where: { exampleKey(of: $0) == key }) {
                lines.insert(line, at: i + 1)
            } else {
                append(line, to: &lines)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func configKey(of line: String) -> String? {
        let content = stripComment(line)
        guard let equals = content.firstIndex(of: "=") else { return nil }
        return content[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The key of a commented example: a line that starts with `#`, whose text after the `#` and spaces is `key=…`.
    /// Headings (`# ── Zoom ───`) and prose have no `=` right after a bare key, so they are not examples.
    private static func exampleKey(of line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let rest = line.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        guard let equals = rest.firstIndex(of: "=") else { return nil }
        let key = rest[..<equals]
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0 == "#" }) else { return nil }
        return key.lowercased()
    }

    private static func trailingComment(of line: String) -> String {
        commentStart(in: line).map { " " + String(line[$0...]) } ?? ""
    }

    /// Appends before the final empty element so a trailing newline stays the last character.
    private static func append(_ line: String, to lines: inout [String]) {
        if lines.last == "" { lines.insert(line, at: lines.count - 1) } else { lines.append(line) }
    }
}
