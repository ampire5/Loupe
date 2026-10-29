import Foundation

/// The custom detector (owner, 2026-10-28): smart zoom on what a model of the user's own finds. Any Core ML object
/// detector (a compiled `.mlmodelc` whose output Vision reads as recognised objects) and detector.conf next to
/// loupe.conf, which says where the model is, which of its classes count and by what names, where on the photo it looks,
/// how sure a box must be, how far apart the classes of a combination may lie, the smallest frame, the margin, which
/// classes are framed with the head grown round them as a face is, and the modes: each a chain of targets (a class or
/// several joined by `+`, Vision's kinds too) and how much of the window the target's frame takes. `⌥C` turns it on and
/// off for the tab, `⌥G` goes through its modes (the keys `detector` and `detector-mode`, a tab's and a folder's like
/// the zoom keys).
public struct DetectorSetup: Equatable, Sendable {
    /// A mode: a chain (the first target found wins, `⇧Z` the next found) and how much of the window its frame takes.
    public struct Mode: Equatable, Sendable {
        public var name: String
        public var chain: [SubjectKind]
        /// 0.2…1, as `subject-size`.
        public var size: Double
        public var composition = CompositionOptions()
    }

    /// `detector`: on in a new tab.
    public var on = false
    /// `model`: the compiled model's path (`~` for home; relative: to detector.conf's folder); empty: none.
    public var model = ""
    /// `look`: where the model looks: the photo whole, and on each person Vision found (a small part of a person seen
    /// at the model's input size). At least one.
    public var lookWhole = true, lookPeople = true
    /// `mode`: the mode a tab starts in; empty: the first.
    public var mode = ""
    /// `score`: a box counts from this confidence.
    public var score = 0.5
    /// Legacy `reach`, accepted for compatibility; no longer filters complete groups.
    public var reach = 0.5
    /// Legacy `min-frame`; native max-zoom now limits automatic enlargement.
    public var minFrame = 0.2
    /// `margin`: room round a class's frame, each side, as a share of its size.
    public var margin = 0.08
    public var composition = CompositionOptions()
    /// `heads`: the classes framed as a face is, grown to the head with its hair (`SubjectFraming.head`).
    public var heads: [SubjectKind] = []
    /// `[classes]`: the model's labels that count, and the names the chains call them by, in the file's order.
    public var classes: [(label: String, kind: SubjectKind)] = []
    public var modes: [Mode] = []
    /// The model's file is there, as of reading detector.conf.
    public var installed = false

    public init() {}

    public static func == (a: DetectorSetup, b: DetectorSetup) -> Bool {
        a.on == b.on && a.model == b.model && a.lookWhole == b.lookWhole && a.lookPeople == b.lookPeople
            && a.mode == b.mode && a.score == b.score && a.reach == b.reach && a.minFrame == b.minFrame
            && a.margin == b.margin && a.composition == b.composition && a.heads == b.heads && a.classes.map(\.label) == b.classes.map(\.label)
            && a.classes.map(\.kind) == b.classes.map(\.kind) && a.modes == b.modes && a.installed == b.installed
    }

    /// detector.conf, next to loupe.conf (so `LOUPE_CONFIG_DIR` moves it too).
    public static var fileURL: URL { Config.directory.appendingPathComponent("detector.conf") }

    /// The model is set and its file is there.
    public var detects: Bool { installed && !classes.isEmpty }

    /// Detection identity excludes framing/profile choices, which do not change inference.
    public var analysisID: String {
        guard detects else { return "vision" }
        return "model:" + URL(fileURLWithPath: model).standardizedFileURL.path
            + "|" + classes.map { $0.label + "=" + $0.kind.rawValue }.joined(separator: ",")
            + "|whole=\(lookWhole)|people=\(lookPeople)"
    }

    /// The kinds the model gives, each once, in `[classes]`' order.
    public var kinds: [SubjectKind] {
        var seen: [SubjectKind] = []
        for c in classes where !seen.contains(c.kind) { seen.append(c.kind) }
        return seen
    }

    /// The model's file: `model` with `~` expanded, relative to `folder`.
    public func modelURL(relativeTo folder: URL = Config.directory) -> URL? {
        guard !model.isEmpty else { return nil }
        let path = (model as NSString).expandingTildeInPath
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
    }

    /// The mode named `name`, else the setup's own, else the first; nil without modes.
    public func mode(_ name: String) -> Mode? {
        modes.first { $0.name == name } ?? modes.first { $0.name == mode } ?? modes.first
    }

    /// The mode after `name`'s, round.
    public func next(after name: String) -> Mode? {
        guard let now = mode(name), let i = modes.firstIndex(of: now) else { return modes.first }
        return modes[(i + 1) % modes.count]
    }

    public static func load(from url: URL = fileURL) -> (DetectorSetup, [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (DetectorSetup(), []) }
        do {
            var (setup, warnings) = parse(try String(contentsOf: url, encoding: .utf8))
            if let model = setup.modelURL(relativeTo: url.deletingLastPathComponent()) {
                setup.model = model.path
                setup.installed = FileManager.default.fileExists(atPath: model.appendingPathComponent("coremldata.bin").path)
                if !setup.installed { warnings.append("detector.conf: no compiled model at \(model.path)") }
            }
            return (setup, warnings)
        } catch {
            return (DetectorSetup(), ["\(url.path): \(error.localizedDescription)"])
        }
    }

    /// The file's text: `key = value` lines, `#` comments; `[classes]` starts the model's labels (`LABEL = name`), any
    /// other `[name]` a mode. A wrong line is reported and skipped; a chain's target that names no class nor Vision's
    /// kind is reported and left out, a mode without a target left is left out.
    public static func parse(_ text: String) -> (DetectorSetup, [String]) {
        var setup = DetectorSetup()
        var warnings: [String] = []
        enum Section { case top, classes, mode }
        var section = Section.top
        var chains: [(mode: Mode, line: Int, targets: [SubjectKind])] = []
        for (number, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !line.isEmpty else { continue }
            let at = "detector.conf:\(number + 1)"
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                if name == "classes" {
                    section = .classes
                } else {
                    section = .mode
                    var mode = Mode(name: name, chain: [], size: 0.6)
                    mode.composition = setup.composition
                    chains.append((mode, number + 1, []))
                }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { warnings.append("\(at): expected key = value"); continue }
            let rawKey = line[..<equals].trimmingCharacters(in: .whitespaces)
            let key = rawKey.lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            var ok = true
            switch section {
            case .classes:
                // A label as the model spells it, and a name of one kind.
                if let kind = SubjectKind(rawValue: value), !kind.isCombination, kind.isCustom {
                    setup.classes.append((rawKey, kind))
                } else {
                    ok = false
                }
            case .mode:
                if let valid = chains[chains.count - 1].mode.composition.set(key, value) {
                    if !valid { warnings.append("\(at): bad value for \(rawKey): \(value)") }; continue
                }
                switch key {
                case "chain":
                    let kinds = value.split(separator: ",").map { SubjectKind(rawValue: String($0)) }
                    if kinds.isEmpty || kinds.contains(nil) { ok = false } else { chains[chains.count - 1].targets = kinds.compactMap { $0 } }
                case "size":
                    if let v = share(value), (0.2...1).contains(v) { chains[chains.count - 1].mode.size = v } else { ok = false }
                default:
                    warnings.append("\(at): unknown key \(key) in a mode"); continue
                }
            case .top:
                if let valid = setup.composition.set(key, value) {
                    if valid { setup.margin = setup.composition.margin }
                    else { warnings.append("\(at): bad value for \(rawKey): \(value)") }; continue
                }
                switch key {
                case "detector":
                    if let v = onOff(value) { setup.on = v } else { ok = false }
                case "model":
                    setup.model = value
                case "look":
                    let places = Set(value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    if places.isEmpty || !places.isSubset(of: ["whole", "people"]) { ok = false } else {
                        setup.lookWhole = places.contains("whole")
                        setup.lookPeople = places.contains("people")
                    }
                case "mode":
                    setup.mode = value.lowercased()
                case "score":
                    if let v = Double(value), (0...1).contains(v) { setup.score = v } else { ok = false }
                case "reach":
                    if let v = share(value), v > 0, v <= 1 { setup.reach = v; warnings.append("\(at): reach is deprecated; complete groups include all instances") } else { ok = false }
                case "min-frame":
                    if let v = share(value), (0...1).contains(v) { setup.minFrame = v; warnings.append("\(at): min-frame is deprecated; use max-zoom") } else { ok = false }
                case "margin":
                    if let v = share(value), (0...1).contains(v) { setup.margin = v } else { ok = false }
                case "heads":
                    let kinds = value.split(separator: ",").map { SubjectKind(rawValue: String($0)) }
                    if kinds.contains(nil) { ok = false } else { setup.heads = kinds.compactMap { $0 } }
                default:
                    warnings.append("\(at): unknown key \(key)"); continue
                }
            }
            if !ok { warnings.append("\(at): bad value for \(rawKey): \(value)") }
        }
        // The chains name the classes declared (anywhere in the file) or Vision's kinds.
        let known = Set(setup.kinds)
        for (mode, line, targets) in chains {
            var m = mode
            var seen = Set<String>()
            for t in targets {
                let canonical = t.parts.map(\.rawValue).sorted().joined(separator: "+")
                guard seen.insert(canonical).inserted else {
                    warnings.append("detector.conf:\(line): [\(m.name)] duplicate group \(t.rawValue)"); continue
                }
                if t.parts.allSatisfy({ !$0.isCustom || known.contains($0) }) {
                    m.chain.append(t)
                } else {
                    warnings.append("detector.conf:\(line): [\(m.name)] names no class in \(t.rawValue)")
                }
            }
            if m.chain.isEmpty { warnings.append("detector.conf:\(line): [\(m.name)] has no chain") } else { setup.modes.append(m) }
        }
        for h in setup.heads where !known.contains(h) { warnings.append("detector.conf: heads names no class \(h.rawValue)") }
        return (setup, warnings)
    }

    /// `text` (detector.conf) with `size` of the mode `name` set to `size` (0.2…1, whole percent): its `size` line
    /// replaced, its comment kept, else a line under the section's header. Nil when the file has no such mode.
    public static func settingSize(_ size: Double, of name: String, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        let header = "[\(name.lowercased())]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == header })
        else { return nil }
        let value = "\(Int((min(max(size, 0.2), 1) * 100).rounded()))%"
        var i = start + 1
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            let body = lines[i].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let code = String(body.first ?? "")
            if let equals = code.firstIndex(of: "="),
               code[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "size" {
                // The comment's own spacing stays: only the value between `=` and it changes.
                let tail = body.count > 1 ? String(code.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()) + "#" + body[1] : ""
                lines[i] = code[..<equals].trimmingCharacters(in: .whitespaces) + " = " + value + tail
                return lines.joined(separator: "\n")
            }
            i += 1
        }
        lines.insert("size = \(value)", at: start + 1)
        return lines.joined(separator: "\n")
    }

    /// Edit only named keys in one profile; keep comments, section order and every other setting.
    public static func settingValues(_ values: [String: String], of name: String, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { line in
            let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let header = code.trimmingCharacters(in: .whitespaces)
            guard header.hasPrefix("["), header.hasSuffix("]") else { return false }
            return header.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
        }) else { return nil }
        var pending = values
        var end = start + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            let parts = lines[end].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let code = String(parts[0])
            if let equals = code.firstIndex(of: "=") {
                let key = code[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                if let value = values[key] {
                    let spacing = String(code.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
                    lines[end] = "\(key) = \(value)" + (parts.count > 1 ? spacing + "#" + parts[1] : "")
                    pending[key] = nil
                }
            }
            end += 1
        }
        lines.insert(contentsOf: pending.keys.sorted().map { "\($0) = \(pending[$0]!)" }, at: start + 1)
        return lines.joined(separator: "\n")
    }

    /// `60%` or `0.6` → 0.6.
    static func share(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") { return Double(t.dropLast().trimmingCharacters(in: .whitespaces)).map { $0 / 100 } }
        return Double(t)
    }

    static func onOff(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "on": true
        case "off": false
        default: Config.bool(text)
        }
    }
}

/// What framing a custom class follows: detector.conf's numbers, which `SubjectBoxes.boxes` and `SubjectFraming` read
/// for the detector's kinds (the app sets them on every reload; Vision's kinds keep their own rules).
public struct DetectorFraming: Equatable, Sendable {
    public var score = 0.5
    public var reach = 0.5
    public var minFrame = 0.2
    public var margin = 0.08
    public var heads: Set<SubjectKind> = []
    /// The detector's kinds in detector.conf's order (Show Subjects lists them so).
    public var kinds: [SubjectKind] = []

    public init() {}

    public init(_ setup: DetectorSetup) {
        score = setup.score
        reach = setup.reach
        minFrame = setup.minFrame
        margin = setup.margin
        heads = Set(setup.heads)
        kinds = setup.kinds
    }
}

extension SubjectFraming {
    /// The custom detector's numbers, set by the app on the main thread when detector.conf is read; read by framing
    /// (main) and Show Subjects. A value, written whole.
    nonisolated(unsafe) public static var detector = DetectorFraming()

    /// Whether `kind`'s boxes frame with the head grown round them: Vision's faces and detector.conf's `heads`.
    static func framesHead(_ kind: SubjectKind) -> Bool { kind == .face || detector.heads.contains(kind) }

    /// Every valid instance of every required class. Presence is independent of spacing and head expansion.
    public static func pick(_ boxes: SubjectBoxes, _ kind: SubjectKind) -> [CGRect]? {
        var result: [CGRect] = []
        for part in kind.parts {
            let found = boxes.boxes(part).compactMap(validRect)
            guard !found.isEmpty else { return nil }
            result.append(contentsOf: kind.parts.count == 1 && framesHead(part) ? found.map(head) : found)
        }
        return result
    }
}

extension SubjectBoxes {
    /// The kinds to show and weigh: Vision's, then the detector's found on the photo, in detector.conf's order.
    public var kinds: [SubjectKind] {
        let found = Set(detections.map(\.kind))
        let ordered = SubjectFraming.detector.kinds.filter(found.contains)
        return SubjectKind.vision + ordered + found.subtracting(ordered).sorted { $0.rawValue < $1.rawValue }
    }
}

/// The Zoom menu's Custom Detector section (owner, 2026-10-28): its header says why the detector cannot be used, each
/// mode of detector.conf is an item whose tip reads its chain and size.
public enum DetectorMenu {
    public static func header(_ setup: DetectorSetup) -> String {
        if !setup.installed { return "Custom Detector — no model (detector.conf)" }
        if setup.classes.isEmpty { return "Custom Detector — no classes (detector.conf)" }
        if setup.modes.isEmpty { return "Custom Detector — no modes (detector.conf)" }
        return "Custom Detector"
    }

    public static func tip(_ mode: DetectorSetup.Mode) -> String {
        "\(mode.chain.map(\.rawValue).joined(separator: ", ")) · \(Int((mode.size * 100).rounded())) % of the window"
    }
}
