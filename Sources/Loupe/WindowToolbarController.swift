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

    /// Loupe's only bottom titlebar accessory is AppKit's native tab bar.
    /// A nonzero minimum would leave it independently visible while the toolbar
    /// slides over it. In auto mode both must reveal and hide as one header.
    func setFullScreenTabBarAutohiding(_ enabled: Bool, in window: NSWindow) {
        for accessory in window.titlebarAccessoryViewControllers where accessory.layoutAttribute == .bottom {
            let height: CGFloat = enabled ? 0 : accessory.view.frame.height
            if accessory.fullScreenMinHeight != height { accessory.fullScreenMinHeight = height }
        }
    }

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }

    func show(_ source: NSToolbar) {
        guard self.source !== source else { return }
        let delegate = source.delegate
        let identifiers = delegate?.toolbarDefaultItemIdentifiers?(source) ?? []
        let installed = toolbar.items.map { ItemIdentity($0.itemIdentifier, item: $0) }
        let installedIdentifiers = Set(installed.map(\.identifier))
        let requested = identifiers.map { identifier in
            let item = installedIdentifiers.contains(identifier)
                ? delegate?.toolbar?(source, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: false)
                : nil
            return ItemIdentity(identifier, item: item)
        }
        let changes = requested.difference(from: installed)

        // Release the destination's items from its own toolbar before mounting them here.
        for case let .remove(index, _, _) in changes { toolbar.removeItem(at: index) }
        for index in source.items.indices.reversed() { source.removeItem(at: index) }
        self.source = source
        toolbar.centeredItemIdentifiers = source.centeredItemIdentifiers
        for case let .insert(index, item, _) in changes {
            toolbar.insertItem(withItemIdentifier: item.identifier, at: index)
        }
    }

    private struct ItemIdentity: Equatable {
        let identifier: NSToolbarItem.Identifier
        let object: ObjectIdentifier?

        init(_ identifier: NSToolbarItem.Identifier, item: NSToolbarItem?) {
            self.identifier = identifier
            // System spacers are interchangeable. A custom item can carry its own view and action.
            object = identifier == .space || identifier == .flexibleSpace ? nil : item.map(ObjectIdentifier.init)
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
