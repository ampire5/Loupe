import AppKit

/// One NSToolbar for the window's lifetime. Switch items instead of replacing
/// NSWindow.toolbar, preserving AppKit's full-screen auto-hide host and layout.
@MainActor final class WindowToolbarController: NSObject, NSToolbarDelegate {
    // Equal identifiers synchronize item mutations between independently navigated windows.
    let toolbar = NSToolbar(identifier: "loupe.window.\(UUID().uuidString)")
    private var source: NSToolbar?

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
