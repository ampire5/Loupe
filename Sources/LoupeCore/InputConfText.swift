/// Edits the text of `input.conf` in place, leaving everything else in the file as it is (spec §8.3): the settings panel
/// writes a binding with `binding(_:to:in:)` and gives a built-in one back with `restoringBuiltIn(_:in:)`.
public enum InputConfText {
    /// `text` with `trigger` bound to `action`:
    /// 1. the last active line of the same input is replaced (the one `InputConf.parse` keeps), its trailing comment
    ///    stays;
    /// 2. else the last commented-out binding of the input is uncommented (`# f fit` becomes `f <action>`); a commented
    ///    line that is no binding (a note on the format) does not count;
    /// 3. else a line goes after the last line, active or commented, of the input's group (keys or mouse);
    /// 4. else at the end.
    /// Inputs are compared as `InputConf.trigger(_:)` reads them, so `L` and `Shift+l` are one input.
    public static func binding(_ trigger: InputTrigger, to action: InputAction, in text: String) -> String {
        var file = File(text)
        let actionText = InputConf.text(of: action)
        if let line = InputConf.parse(text).lines.last(where: { $0.trigger == trigger }) {
            file.rows[line.line - 1].rewrite(action: actionText)
        } else if let index = file.rows.lastIndex(where: { $0.commentedBinding == trigger }) {
            file.rows[index].uncomment()
            file.rows[index].rewrite(action: actionText)
        } else {
            let line = Row(content: InputConf.text(of: trigger) + " " + actionText, eol: "")
            if let index = file.rows.lastIndex(where: { $0.group == group(of: trigger) }) {
                file.insert(line, after: index)
            } else {
                file.insert(line, after: file.rows.count - 1)
            }
        }
        return file.text
    }

    /// `text` with every active line of `trigger` commented out (`# ` in front of the line), which gives the input back
    /// to the built-in layout. A text without such a line comes back unchanged.
    public static func restoringBuiltIn(_ trigger: InputTrigger, in text: String) -> String {
        var file = File(text)
        for line in InputConf.parse(text).lines where line.trigger == trigger {
            file.rows[line.line - 1].commentOut()
        }
        return file.text
    }

    private enum Group { case keys, mouse }

    private static func group(of trigger: InputTrigger) -> Group {
        if case .mouse = trigger { return .mouse }
        return .keys
    }

    /// The file as lines with their line ends, numbered as `InputConf.parse` numbers them (`\n`, `\r\n` and `\r` end a
    /// line; a BOM stays in front of the first one).
    private struct File {
        var rows: [Row] = []

        init(_ text: String) {
            var content = ""
            for c in text {
                if c == "\n" || c == "\r\n" || c == "\r" {
                    rows.append(Row(content: content, eol: String(c)))
                    content = ""
                } else {
                    content.append(c)
                }
            }
            if !content.isEmpty { rows.append(Row(content: content, eol: "")) }
        }

        var text: String { rows.map { $0.content + $0.eol }.joined() }

        /// Puts `row` after `index` (-1 for an empty file), with the line end of the line before it, which gets one if
        /// it was the last line of a file without a final newline.
        mutating func insert(_ row: Row, after index: Int) {
            var row = row
            if index >= 0 {
                if rows[index].eol.isEmpty { rows[index].eol = rows.first { !$0.eol.isEmpty }?.eol ?? "\n" }
                row.eol = rows[index].eol
            } else {
                row.eol = "\n"
            }
            rows.insert(row, at: index + 1)
        }
    }

    private struct Row {
        var content: String
        var eol: String

        private static let blanks: Set<Character> = [" ", "\t"]

        /// The first token of `text` (without a BOM) as an input, nil when it is none.
        private static func input(of text: Substring) -> (trigger: InputTrigger, token: Substring)? {
            let token = text.drop { Self.blanks.contains($0) || $0 == "\u{FEFF}" }.prefix { !blanks.contains($0) }
            guard let t = InputConf.trigger(String(token)) else { return nil }
            return (t, token)
        }

        /// The group of the line by its first token (after `#` and spaces in a commented line), nil for a line without
        /// an input.
        var group: Group? {
            let text = Substring(content)
            let afterBlanks = text.drop { Self.blanks.contains($0) || $0 == "\u{FEFF}" }
            let body = afterBlanks.first == "#" ? afterBlanks.dropFirst() : afterBlanks
            guard let (_, token) = Self.input(of: body) else { return nil }
            return token.hasPrefix("MBTN_") || token.hasPrefix("MX_") ? .mouse : .keys
        }

        /// The input of a commented-out line that is a binding of its own (it parses, whole, as one line), nil for any
        /// other line.
        var commentedBinding: InputTrigger? {
            let afterBlanks = Substring(content).drop { Self.blanks.contains($0) || $0 == "\u{FEFF}" }
            guard afterBlanks.first == "#" else { return nil }
            var copy = self
            copy.uncomment()
            let parsed = InputConf.parse(copy.content)
            guard parsed.warnings.isEmpty, parsed.lines.count == 1 else { return nil }
            return parsed.lines[0].trigger
        }

        /// `# ` in front of the line (after a BOM, which has to stay the first character of the file).
        mutating func commentOut() {
            let bom = content.hasPrefix("\u{FEFF}") ? "\u{FEFF}" : ""
            content = bom + "# " + content.dropFirst(bom.count)
        }

        /// Drops the `#` and the blanks after it, keeping the indent in front of it.
        mutating func uncomment() {
            let indent = content.prefix { Self.blanks.contains($0) || $0 == "\u{FEFF}" }
            let rest = content.dropFirst(indent.count)
            guard rest.first == "#" else { return }
            content = String(indent) + String(rest.dropFirst().drop { Self.blanks.contains($0) })
        }

        /// Puts `action` in place of the line's action, keeping the indent, the input as written, and the trailing
        /// comment (at its column when the new text leaves room for it).
        mutating func rewrite(action: String) {
            let hash = content.firstIndex(of: "#") ?? content.endIndex
            let code = content[..<hash]
            let comment = content[hash...]
            let indent = code.prefix { Self.blanks.contains($0) || $0 == "\u{FEFF}" }
            let token = Self.input(of: code)?.token ?? ""
            var line = String(indent) + String(token) + " " + action
            if !comment.isEmpty {
                let pad = max(2, code.count - line.count)
                line += String(repeating: " ", count: pad) + comment
            }
            content = line
        }
    }
}
