import AppKit

/// One NSToolbar for the window's lifetime. Switch items instead of replacing
/// NSWindow.toolbar, preserving AppKit's full-screen auto-hide host and layout.
@MainActor final class WindowToolbarController: NSObject, NSToolbarDelegate {
    // AppKit synchronizes insert/remove operations across equal identifiers even
    // when autosaving is off. Each window switches Home/viewer independently.
    let toolbar = NSToolbar(identifier: "loupe.window.\(UUID().uuidString)")
    private var source: NSToolbar?
    private var fullScreenAutohiding: Bool?

    /// Photos uses these AppKit toolbar operations through UXKit. Keep this
    /// compatibility boundary here: no UXKit linkage and no content-view replica.
    /// See docs/bench/2026-10-30-photos-toolbar.md for the inspected call chain.
    var supportsFullScreenAutohiding: Bool {
        toolbar.responds(to: NSSelectorFromString("_enableFullScreenAutohiding"))
            && toolbar.responds(to: NSSelectorFromString("_disableFullScreenAutohiding"))
    }

    func setFullScreenAutohiding(_ enabled: Bool) {
        guard fullScreenAutohiding != enabled, supportsFullScreenAutohiding else { return }
        let selector = NSSelectorFromString(enabled ? "_enableFullScreenAutohiding" : "_disableFullScreenAutohiding")
        toolbar.perform(selector)
        fullScreenAutohiding = enabled
    }

    /// AppKit itself applies the delegate's initial policy during entry. Do not
    /// enable/disable its native host a second time when didEnter is delivered.
    func prepareForFullScreen(autohiding: Bool) { fullScreenAutohiding = autohiding }

    func resetFullScreenAutohiding() { fullScreenAutohiding = nil }

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }

    func show(_ source: NSToolbar) {
        guard self.source !== source else { return }
        // Source controllers retain their items and update them directly. Return
        // those same items, preserving actions, selection, and cached custom views.
        for index in toolbar.items.indices.reversed() { toolbar.removeItem(at: index) }
        for index in source.items.indices.reversed() { source.removeItem(at: index) }
        self.source = source
        toolbar.centeredItemIdentifiers = source.centeredItemIdentifiers
        let identifiers = source.delegate?.toolbarDefaultItemIdentifiers?(source) ?? []
        for (index, identifier) in identifiers.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
    }

    /// A source can change one retained group while another source is parked.
    func replaceItem(_ old: NSToolbarItem.Identifier, with new: NSToolbarItem.Identifier, source: NSToolbar) {
        guard self.source === source,
              let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == old }) else { return }
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: new, at: index)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        guard let source else { return [] }
        return source.delegate?.toolbarDefaultItemIdentifiers?(source) ?? []
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        guard let source else { return [] }
        return source.delegate?.toolbarAllowedItemIdentifiers?(source) ?? []
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let source else { return nil }
        return source.delegate?.toolbar?(source, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: flag)
    }
}
