/// The browser's tab chords the menus do not carry (Safari, Chrome and Firefox agree): ⌘1…⌘8 a tab by its place, ⌘9
/// the last one, ⌥⌘→ / ⌥⌘← the next and previous. The main menu matches them before its items.
public enum BrowserTabKeys {
    public enum Key: Equatable, Sendable {
        case select(Int), last, next, previous
    }

    /// The top row's 1…8 by key code, so any layout (AZERTY types digits with Shift) has them.
    private static let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28]
    private static let nineCode: UInt16 = 25

    /// The chord's tab step, nil when it is not one: ⌘ with a digit and nothing else, or ⌥⌘ with ← or →.
    public static func match(keyCode: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false,
                             control: Bool = false) -> Key? {
        guard command, !shift, !control else { return nil }
        if option {
            switch keyCode {
            case 124: return .next
            case 123: return .previous
            default: return nil
            }
        }
        if let i = digitCodes.firstIndex(of: keyCode) { return .select(i) }
        return keyCode == nineCode ? .last : nil
    }

    /// The tab `key` goes to among `count` tabs, `selected` on screen; nil when there is none to go to (a lone tab, no
    /// tab at that place). The steps go round.
    public static func index(_ key: Key, selected: Int, count: Int) -> Int? {
        guard count > 1 else { return nil }
        switch key {
        case .select(let i): return i < count ? i : nil
        case .last: return count - 1
        case .next: return (selected + 1) % count
        case .previous: return (selected + count - 1) % count
        }
    }

    /// The cheat sheet's and the Key Bindings table's lines for them.
    public static let rows: [(input: String, title: String)] = [
        ("⌘1…⌘8", "Tab 1…8"),
        ("⌘9", "Last tab"),
        ("⌥⌘→", "Next tab"),
        ("⌥⌘←", "Previous tab"),
    ]
}

/// ⌥⌘1 / ⌥⌘2 / ⌥⌘3: how Home's browser draws a folder's folders and archives (posters, cards, list; folder cards
/// spec; ⌃⌘ digits were awkward to press). ⌘ digits stay the tabs' (`BrowserTabKeys`), on Home too, and ⌥ digits
/// Home's sort. By key code, like the tabs' digits.
public enum CardStyleKeys {
    private static let digitCodes: [UInt16] = [18, 19, 20]

    /// The style's index (`CardStyle.allCases`) for ⌥⌘ with 1, 2 or 3 and nothing else; nil for any other key.
    public static func match(keyCode: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false,
                             control: Bool = false) -> Int? {
        guard command, option, !shift, !control else { return nil }
        return digitCodes.firstIndex(of: keyCode)
    }
}

/// The tabs closed lately, newest last, for File › Reopen Closed Tab (⇧⌘T). A tab on Home has nothing to reopen.
public struct ClosedTabs: Sendable {
    public static let limit = 10
    private var tabs: [SessionSnapshot.Tab] = []

    public init() {}

    public var count: Int { tabs.count }

    public mutating func push(_ tab: SessionSnapshot.Tab) {
        if case .home = tab { return }
        tabs.append(tab)
        if tabs.count > Self.limit { tabs.removeFirst(tabs.count - Self.limit) }
    }

    public mutating func pop() -> SessionSnapshot.Tab? { tabs.popLast() }
}

/// A menu item's shortcut as the cheat sheet and the Key Bindings table write it (`⇧⌘T`).
public enum MenuShortcut {
    /// `key`: the item's key equivalent. A shifted bracket (`}` for ⇧⌘], as Safari's items have it) reads as ⇧ and
    /// the bracket.
    public static func text(key: String, command: Bool = false, shift: Bool = false, option: Bool = false,
                            control: Bool = false) -> String {
        let shifted: [String: String] = ["}": "]", "{": "["]
        let base = shifted[key] ?? key
        let shift = shift || shifted[key] != nil
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + base.uppercased()
    }
}
