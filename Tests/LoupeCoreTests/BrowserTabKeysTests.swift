import Testing
@testable import LoupeCore

struct BrowserTabKeysTests {
    /// ⌘1…⌘8 pick a tab by place, ⌘9 the last one, by the key's code (any layout); ⌥⌘→ / ⌥⌘← step, as in Firefox and
    /// Chrome.
    @Test func chords() {
        #expect(BrowserTabKeys.match(keyCode: 18, command: true) == .select(0))      // 1
        #expect(BrowserTabKeys.match(keyCode: 28, command: true) == .select(7))      // 8
        #expect(BrowserTabKeys.match(keyCode: 25, command: true) == .last)           // 9
        #expect(BrowserTabKeys.match(keyCode: 124, command: true, option: true) == .next)
        #expect(BrowserTabKeys.match(keyCode: 123, command: true, option: true) == .previous)
        // Other modifiers, or none: not ours.
        #expect(BrowserTabKeys.match(keyCode: 18) == nil)
        #expect(BrowserTabKeys.match(keyCode: 18, command: true, shift: true) == nil)
        #expect(BrowserTabKeys.match(keyCode: 18, command: true, option: true) == nil)
        #expect(BrowserTabKeys.match(keyCode: 124, command: true) == nil)
        #expect(BrowserTabKeys.match(keyCode: 124, command: true, option: true, control: true) == nil)
        // The keypad's 1 is not a tab.
        #expect(BrowserTabKeys.match(keyCode: 83, command: true) == nil)
    }

    @Test func tabIndex() {
        #expect(BrowserTabKeys.index(.select(0), selected: 2, count: 4) == 0)
        #expect(BrowserTabKeys.index(.select(5), selected: 2, count: 4) == nil)    // no 6th tab
        #expect(BrowserTabKeys.index(.last, selected: 0, count: 4) == 3)
        #expect(BrowserTabKeys.index(.next, selected: 3, count: 4) == 0)           // round
        #expect(BrowserTabKeys.index(.previous, selected: 0, count: 4) == 3)
        #expect(BrowserTabKeys.index(.next, selected: 0, count: 1) == nil)         // one tab: nothing to do
        #expect(BrowserTabKeys.index(.last, selected: 0, count: 1) == nil)
    }
}

/// ⌃⌘1–⌃⌘3 pick how Home draws a folder's cards (posters, cards, list), by the key's code; ⌘ digits stay the tabs'.
struct CardStyleKeysTests {
    @Test func chords() {
        #expect(CardStyleKeys.match(keyCode: 18, command: true, control: true) == 0)   // ⌃⌘1
        #expect(CardStyleKeys.match(keyCode: 19, command: true, control: true) == 1)
        #expect(CardStyleKeys.match(keyCode: 20, command: true, control: true) == 2)   // ⌃⌘3
        #expect(CardStyleKeys.match(keyCode: 21, command: true, control: true) == nil) // ⌃⌘4: none
        #expect(CardStyleKeys.match(keyCode: 18, command: true) == nil)                // ⌘1: a tab
        #expect(CardStyleKeys.match(keyCode: 18, control: true) == nil)
        #expect(CardStyleKeys.match(keyCode: 18, command: true, shift: true, control: true) == nil)
        #expect(CardStyleKeys.match(keyCode: 18, command: true, option: true, control: true) == nil)
        // Not a tab chord either: the two never meet.
        #expect(BrowserTabKeys.match(keyCode: 18, command: true, control: true) == nil)
    }
}

struct ClosedTabsTests {
    @Test func reopensNewestFirst() {
        var closed = ClosedTabs()
        closed.push(.file(path: "/a/1.jpg", view: nil))
        closed.push(.home(.recent))                                                 // nothing to reopen
        closed.push(.file(path: "/b/2.jpg", view: "fit"))
        #expect(closed.count == 2)
        #expect(closed.pop() == .file(path: "/b/2.jpg", view: "fit"))
        #expect(closed.pop() == .file(path: "/a/1.jpg", view: nil))
        #expect(closed.pop() == nil)
    }

    @Test func keepsTen() {
        var closed = ClosedTabs()
        for i in 0..<12 { closed.push(.file(path: "/\(i).jpg", view: nil)) }
        #expect(closed.count == 10)
        var last: SessionSnapshot.Tab?
        while let tab = closed.pop() { last = tab }
        #expect(last == .file(path: "/2.jpg", view: nil))
    }
}

struct MenuShortcutTests {
    @Test func text() {
        #expect(MenuShortcut.text(key: "t", command: true) == "⌘T")
        #expect(MenuShortcut.text(key: "o", command: true, shift: true, option: true, control: true) == "⌃⌥⇧⌘O")
        // The shifted bracket a ⇧⌘] item carries reads as the bracket.
        #expect(MenuShortcut.text(key: "}", command: true) == "⇧⌘]")
        #expect(MenuShortcut.text(key: "[", command: true) == "⌘[")
    }
}
