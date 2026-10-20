import AppKit
import SettingsKit

/// What the pages need from the app beyond the store. The settings code never reaches `Settings.shared`: the app
/// passes everything in.
public struct SettingsPanelContext {
    /// `loupe.conf`.
    public var configURL: URL
    /// `input.conf`.
    public var inputURL: URL
    /// The `app-icon` pop-up's items (a value and its picture): the built-in icons and the pictures in
    /// ~/.config/loupe/icons. Asked each time the pop-up is shown or opened.
    public var iconChoices: @MainActor () -> [(word: String, image: NSImage?)]
    /// The Latin character a key code types, with or without Shift, on the ASCII-capable layout
    /// (`KeyboardLayout.translate`): the key recorder binds a letter by it.
    public var translateKey: (UInt16, Bool) -> String?
    /// Re-reads input.conf into the app (`Settings.reload()`) after the Key Bindings page wrote it.
    public var reloadInput: @MainActor () -> Void
    /// The menus' shortcuts for the Key Bindings page (`MenuShortcuts.rows`).
    public var menuRows: @MainActor () -> [(input: String, title: String)]
    /// The thumbnail catalog's folder (`Caches/Loupe`) for the Catalog card; nil: thumbnails only in memory.
    public var catalogDirectory: URL?

    public init(configURL: URL, inputURL: URL,
                iconChoices: @escaping @MainActor () -> [(word: String, image: NSImage?)] = { [] },
                translateKey: @escaping (UInt16, Bool) -> String? = { _, _ in nil },
                reloadInput: @escaping @MainActor () -> Void = {},
                menuRows: @escaping @MainActor () -> [(input: String, title: String)] = { [] },
                catalogDirectory: URL? = nil) {
        self.configURL = configURL
        self.inputURL = inputURL
        self.iconChoices = iconChoices
        self.translateKey = translateKey
        self.reloadInput = reloadInput
        self.menuRows = menuRows
        self.catalogDirectory = catalogDirectory
    }
}

/// The settings window (⌘,): one per app, made on the first `show`, never at launch (spec §12).
@MainActor public enum SettingsPanel {
    /// Frame autosave name of the window.
    static let autosaveName = "LoupeSettings"
    /// `UserDefaults` key of the open page.
    static let lastPageDefaultsKey = "settingsLastPage"

    private static var controller: SettingsWindowController?
    private static var model: SettingsModel?
    private static var terminateObserver: NSObjectProtocol?
    /// The context of the last `show`: what the pages' closures (icon choices, the Advanced buttons) ask.
    static var context: SettingsPanelContext?
    /// The Key Bindings tables' source, made on the first `show` over the context's input.conf.
    static var bindingSource: InputBindingSource?

    /// The pages in spec §5 order.
    public static func pages() -> [SettingsPage] {
        [general, zoomPan, quality, colour, strip, interface, mouse, keyBindings, performance, stash, advanced]
    }

    /// The folder notes ask the store again: the app calls it when the main window or its folder changed, or a
    /// folder's values did. Nothing before the window was first shown.
    public static func refreshFolderOverrides() {
        model?.refreshFolderOverrides()
    }

    /// Brings the window to the front, making it on the first call (on the page it was last on). Later calls keep
    /// the first store.
    /// - Parameter page: a page id to open, or nil for the page the window is on.
    public static func show(store: ConfigSettingsStore, context: SettingsPanelContext, page: String? = nil) {
        self.context = context
        if bindingSource?.fileURL != context.inputURL {
            bindingSource = InputBindingSource(fileURL: context.inputURL, reload: context.reloadInput,
                                               translateKey: context.translateKey, menuRows: context.menuRows)
        }
        if controller == nil {
            let model = SettingsModel(store: store)
            self.model = model
            controller = SettingsWindowController(pages: pages(), model: model, autosaveName: autosaveName,
                                                  lastPageDefaultsKey: lastPageDefaultsKey, style: .glass)
            // No tab bar, + or Window menu tab items: the app answers `newWindowForTab:` with viewer tabs.
            controller?.window?.tabbingMode = .disallowed
            // ⌘Q while a field is being edited: its text is written first, as on ⌘W.
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { _ in
                MainActor.assumeIsolated { controller?.endEditing() }
            }
        }
        model?.refreshFolderOverrides()
        controller?.show(page: page)
    }

    /// Closes the window if it is open; a field being edited is written first (the window's close does that).
    /// The app calls it when the photo window closes, so that closing the photo window still quits Loupe.
    public static func close() {
        guard let window = controller?.window, window.isVisible else { return }
        controller?.close()
    }
}
