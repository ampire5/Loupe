import Foundation
import HomeScreenModel
import Testing
@testable import LoupeCore

/// `grid-style-memory`: how Home's Square / Aspect toggle is remembered — for the tab (the default), for the folder and
/// the ones under it (like `folder-cards`), or everywhere (loupe.conf's `grid-style`).
@Suite struct GridStyleMemoryTests {
    private func dir(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// A folder's own, else its nearest ancestor's, else loupe.conf's; text that is no style falls back.
    @Test func folderStyleInherits() {
        let settings = FolderSettings(database: nil)
        #expect(GridStyle.settingKey == "grid-style")
        #expect(GridStyle.forFolder(dir("/photos/a"), settings: settings, fallback: .aspect) == .aspect)
        #expect(GridStyle.forFolder(dir("/photos/a"), settings: settings, fallback: .square) == .square)
        settings.set(GridStyle.settingKey, "square", for: dir("/photos"))
        #expect(GridStyle.forFolder(dir("/photos/a/b"), settings: settings, fallback: .aspect) == .square)
        settings.set(GridStyle.settingKey, "aspect", for: dir("/photos/a"))
        #expect(GridStyle.forFolder(dir("/photos/a/b"), settings: settings, fallback: .square) == .aspect)
        #expect(GridStyle.forFolder(dir("/photos"), settings: settings, fallback: .aspect) == .square)
        settings.set(GridStyle.settingKey, "round", for: dir("/other"))
        #expect(GridStyle.forFolder(dir("/other"), settings: settings, fallback: .square) == .square)
        #expect(GridStyle.forFolder(dir("/photos"), settings: nil, fallback: .aspect) == .aspect)
    }

    /// `tab`: a new tab starts from loupe.conf's; a toggle is the tab's own and writes nothing; another tab and another
    /// folder do not see it.
    @Test func tabKeepsItsOwn() {
        let settings = FolderSettings(database: nil)
        var tab = TabGridStyle(), other = TabGridStyle()
        #expect(tab.style(memory: .tab, global: .aspect, folder: dir("/a"), settings: settings) == .aspect)
        #expect(tab.choose(.square, memory: .tab, folder: dir("/a")) == .none)
        #expect(tab.style(memory: .tab, global: .aspect, folder: dir("/a"), settings: settings) == .square)
        #expect(tab.style(memory: .tab, global: .aspect, folder: dir("/b"), settings: settings) == .square)
        #expect(tab.style(memory: .tab, global: .aspect, folder: nil, settings: settings) == .square)
        #expect(other.style(memory: .tab, global: .aspect, folder: dir("/a"), settings: settings) == .aspect)
        #expect(settings.count == 0)
        // A folder's saved style is the `folder` memory's, not the tab's.
        settings.set(GridStyle.settingKey, "square", for: dir("/c"))
        #expect(other.style(memory: .tab, global: .aspect, folder: dir("/c"), settings: settings) == .aspect)
        #expect(other.choose(.aspect, memory: .tab, folder: nil) == .none)
    }

    /// `folder`: the toggle is saved for the folder, its subfolders follow until they have their own; off a folder it
    /// holds for the tab, as `tab` does.
    @Test func folderSavesForTheFolder() {
        let settings = FolderSettings(database: nil)
        var tab = TabGridStyle()
        #expect(tab.choose(.square, memory: .folder, folder: dir("/photos")) == .folder(dir("/photos"), .square))
        settings.set(GridStyle.settingKey, "square", for: dir("/photos"))
        #expect(tab.style(memory: .folder, global: .aspect, folder: dir("/photos/a"), settings: settings) == .square)
        #expect(tab.style(memory: .folder, global: .aspect, folder: dir("/else"), settings: settings) == .aspect)
        // The folder choice is no tab choice: back on `tab`, the tab still starts from loupe.conf's.
        #expect(tab.style(memory: .tab, global: .aspect, folder: dir("/photos"), settings: settings) == .aspect)
        #expect(tab.choose(.square, memory: .folder, folder: nil) == .none)
        #expect(tab.style(memory: .folder, global: .aspect, folder: nil, settings: settings) == .square)
    }

    /// `global`: today's behaviour, loupe.conf's `grid-style` everywhere, a toggle saved there.
    @Test func globalWritesTheDefault() {
        let settings = FolderSettings(database: nil)
        settings.set(GridStyle.settingKey, "square", for: dir("/photos"))
        var tab = TabGridStyle()
        _ = tab.choose(.square, memory: .tab, folder: nil)
        #expect(tab.style(memory: .global, global: .aspect, folder: dir("/photos"), settings: settings) == .aspect)
        #expect(tab.choose(.square, memory: .global, folder: dir("/photos")) == .global(.square))
    }

    /// A session's tab gives its own Square / Aspect back only under `tab`; under `folder` and `global` it is not the
    /// tab's to keep.
    @Test func sessionRestoresTheTabsOwnInTabModeOnly() {
        let settings = FolderSettings(database: nil)
        var tab = TabGridStyle()
        tab.restore(.square, memory: .tab)
        #expect(tab.own == .square)
        #expect(tab.style(memory: .tab, global: .aspect, folder: dir("/photos"), settings: settings) == .square)
        for memory in [GridStyleMemory.folder, .global] {
            var other = TabGridStyle()
            other.restore(.square, memory: memory)
            #expect(other.own == nil)
        }
        var none = TabGridStyle()
        none.restore(nil, memory: .tab)
        #expect(none.own == nil)
    }
}
