import AppKit
import LoupeCore
import LoupeRender
import LoupeSettings
import SettingsKit

extension Notification.Name {
    /// Posted on the main thread after every config push (a reload, a menu toggle, a strip resize), for window state
    /// that follows a key outside the strip (`strip-loading-indicator`).
    static let settingsChanged = Notification.Name("local.loupe.settingsChanged")
    /// Posted on the main thread after a folder's saved values changed (`S`, `A`, a save as default), for every window:
    /// another one may show the same folder or one below it.
    static let folderSettingsChanged = Notification.Name("local.loupe.folderSettingsChanged")
    /// Posted on the main thread when a viewer window shows a photo from another folder (`object`: its controller).
    static let viewerFolderChanged = Notification.Name("local.loupe.viewerFolderChanged")
}

/// The app's current `Config` and input layout (`input.conf`), and the Zoom and Scaling menus that edit the config. The
/// files are read at launch and again whenever the app becomes active, so an edit made in a text editor takes effect on
/// switching back; a menu toggle re-reads the file first, then rewrites only its own key
/// (`ConfigText`), so hand-added stops and comments survive. Warnings go to stderr and,
/// with `config-warnings`, into every window (`ConfigWarningsOverlay`).
@MainActor final class Settings: NSObject, NSMenuItemValidation, NSMenuDelegate {
    static let shared = Settings()

    private(set) var config = Config()
    /// The settings window's store, told which keys a reload changed; nil until the window is first opened.
    weak var settingsStore: ConfigSettingsStore?
    /// The process-wide cache, given its `CacheLimits` on every reload that changes them.
    var cache: ImageCache<MetalPyramidLoader>? {
        didSet { pushLimits() }
    }
    private var pushedLimits: CacheLimits?
    /// `pyramid-filter` as the cache's loader reads it at each upload; set on every reload, so photos uploaded after
    /// an edit get the new filter (pyramids already built keep theirs).
    var pyramidFilter: PyramidFilterSetting?
    /// The app's thumbnail store, given `thumb-size` and `thumb-cache-size` on every reload that changes them.
    /// Set right after it was made from the current config, so the first push is the next change.
    var thumbnails: ThumbnailStore? {
        didSet { pushedThumbnailSettings = (size: config.thumbSize, limit: config.thumbCacheBytes) }
    }
    private var pushedThumbnailSettings: (size: Int, limit: Int)?
    /// The app's per-folder values; every change is announced as `.folderSettingsChanged`, on the main thread.
    var folderSettings: FolderSettings? {
        didSet {
            // `set` / `clear` call it on their caller's thread, which is the main one for the viewer's keys.
            folderSettings?.onChange = {
                guard Thread.isMainThread else {
                    DispatchQueue.main.async { NotificationCenter.default.post(name: .folderSettingsChanged, object: nil) }
                    return
                }
                NotificationCenter.default.post(name: .folderSettingsChanged, object: nil)
            }
        }
    }
    /// Every window's strip, told the strip keys on every reload.
    private let strips = NSHashTable<StripController>.weakObjects()
    /// `loupe.conf` (`Config.fileURL`, which `LOUPE_CONFIG_DIR` moves).
    let fileURL = Config.fileURL
    /// `input.conf`, next to loupe.conf (so `LOUPE_CONFIG_DIR` moves both).
    var inputFileURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent(InputConf.fileName) }
    /// The effective keyboard and mouse layout: the built-in one with `input.conf` on top, made again on every reload.
    /// The viewer's keys, the menus' key equivalents and the cheat sheet read it.
    private(set) var inputMap = InputMap.standard
    /// The `app-icon` last put in the Dock; nil until the first reload (the bundle's icon is showing).
    private var appliedIcon: String?
    /// The files' problems as of the last reload (what `Config.parse` reported, then `InputConf.parse`), for the
    /// windows' overlay; it is also what was last printed, so re-reading unchanged files on every activation stays
    /// quiet.
    private(set) var warnings: [String] = []

    /// `P`'s value of `pan-indicators` for this session, in every window, over loupe.conf's (M4b spec §5.4); nil:
    /// loupe.conf's. A reload keeps it; `⇧P` saves it and clears it.
    private(set) var panIndicatorsOverride: PanIndicatorMode?
    /// What the windows draw the pan indicators with.
    var panIndicators: PanIndicatorMode { panIndicatorsOverride ?? config.panIndicators }

    /// The checkbox stops, by menu item tag.
    private static let menuStops: [ZoomStop] = [.fitWidth, .fitHeight, .percent(100)]

    /// `pushToStrips: false` is for a caller that is about to change the config and pushes the result itself;
    /// `applyingIcon: false` (the launch) leaves the Dock icon to a later `applyAppIcon`.
    func reload(pushToStrips: Bool = true, applyingIcon: Bool = true) {
        let (loaded, configWarnings) = Config.load(from: fileURL)
        let previous = config
        config = loaded
        let (lines, inputWarnings) = Self.loadInput(from: inputFileURL)
        inputMap = InputMap(lines: lines)
        let found = configWarnings + HardwareAdvice.warnings(for: loaded, on: .current) + inputWarnings
        if found != warnings {
            for w in found { FileHandle.standardError.write(Data("loupe: \(w)\n".utf8)) }
            warnings = found
        }
        pushLimits()
        pyramidFilter?.set(config.pyramidFilter)
        JXLSetting.shared.options = JXLOptions(config: config)
        pushThumbnailSettings()
        applyAppearance()
        if applyingIcon { applyAppIcon() }
        if pushToStrips { pushToAllStrips() }
        settingsStore?.configDidReload(from: previous)
    }

    /// `input.conf`'s lines and problems; a missing file is the built-in layout, not an error, and one that cannot be
    /// read is reported (like loupe.conf in `Config.load`).
    private static func loadInput(from url: URL) -> (lines: [InputLine], warnings: [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], []) }
        do {
            return InputConf.parse(try String(contentsOf: url, encoding: .utf8))
        } catch {
            return ([], ["\(url.path): \(error.localizedDescription)"])
        }
    }

    private func pushToAllStrips() {
        for strip in strips.allObjects { strip.apply(config) }
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    func addStrip(_ strip: StripController) { strips.add(strip) }

    private func pushThumbnailSettings() {
        guard let thumbnails else { return }
        let settings = (size: config.thumbSize, limit: config.thumbCacheBytes)
        guard pushedThumbnailSettings.map({ $0 != settings }) ?? true else { return }
        pushedThumbnailSettings = settings
        Task { await thumbnails.setSettings(thumbSize: settings.size, limitBytes: settings.limit) }
    }

    /// `appearance`: the whole app's light or dark look (`nil`: follow macOS). Cheap when unchanged.
    func applyAppearance() {
        let appearance = config.appearance.prefersDark.flatMap { NSAppearance(named: $0 ? .darkAqua : .aqua) }
        if NSApp.appearance != appearance { NSApp.appearance = appearance }
    }

    /// `app-icon`: a picture from ~/.config/loupe/icons, a bundled alternate (`AppIcons/<name>.icns`, compiled by
    /// make-app.sh from Resources/Icons/Alternates) or a file path; `owl` with no file of that name is the bundle's
    /// icon. Only the running app's Dock icon changes; Finder keeps the bundle's. A missing picture (`swift run` has
    /// no bundle) keeps the current icon and says so once.
    func applyAppIcon() {
        let choice = config.appIcon
        guard choice != appliedIcon else { return }
        let previous = appliedIcon
        appliedIcon = choice
        if let url = Self.appIconURL(choice), let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
            return
        }
        // Your own .icon not compiled yet: compiled now, set when done if it is still the choice.
        if let package = Self.iconPackage(choice) {
            Task { @MainActor in
                guard let url = await IconPackage.compile(package), self.config.appIcon == choice,
                      let image = NSImage(contentsOf: url) else { return }
                NSApp.applicationIconImage = image
            }
            return
        }
        guard choice == AppIcon.bundle else {
            FileHandle.standardError.write(Data("loupe: app-icon=\(choice): no such picture (looked in \(Self.userIcons.path) and the app bundle)\n".utf8))
            return
        }
        // At launch the bundle's icon is already showing. Setting nil does not bring it back on macOS 26 (the Dock
        // keeps the alternate), so the bundle's icon is set explicitly, at 512 pt: NSWorkspace's image is 32 pt,
        // which the Dock and Cmd-Tab got as a pixelated bitmap.
        if previous != nil {
            let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            icon.size = NSSize(width: 512, height: 512)
            NSApp.applicationIconImage = icon
        }
    }

    /// View › App Icon… (⌃⌥⌘I): the picker window (SettingsKit) of `appIconChoices`; a click is applied at once and
    /// written to loupe.conf like a menu toggle.
    private lazy var iconPicker = IconPickerWindowController(
        choices: { Self.appIconChoices() },
        folder: Self.userIcons,
        current: { [unowned self] in config.appIcon },
        onPick: { [unowned self] word in change("app-icon") { $0.appIcon = word } })

    @objc func showIconPicker(_ sender: Any?) { iconPicker.show() }

    /// Where your own `app-icon` pictures go: ~/.config/loupe/icons/<name>.icns, .png or .icon (Icon Composer).
    static var userIcons: URL { Config.directory.appendingPathComponent("icons", isDirectory: true) }

    /// The file for an `app-icon` value: the path itself, else the user's picture of that name, else the bundled one.
    /// A `.icon` package gives its compiled .icns, nil until it is compiled (`iconPackage`, `IconPackage.compile`).
    static func appIconURL(_ value: String) -> URL? {
        let files = FileManager.default
        if let package = iconPackage(value) { return IconPackage.compiled(package) }
        if AppIcon.isPath(value) {
            let path = (value as NSString).expandingTildeInPath
            return files.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for ext in ["icns", "png"] {
            let url = userIcons.appendingPathComponent("\(value).\(ext)")
            if files.fileExists(atPath: url.path) { return url }
        }
        return Bundle.main.url(forResource: value, withExtension: "icns", subdirectory: "AppIcons")
    }

    /// The Icon Composer package an `app-icon` value names: a path to a `.icon`, or ~/.config/loupe/icons/<name>.icon
    /// when there is no <name>.icns or .png (those go first, as before).
    static func iconPackage(_ value: String) -> URL? {
        if AppIcon.isPath(value) {
            let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            return IconPackage.isPackage(url) ? url : nil
        }
        let files = FileManager.default
        guard !["icns", "png"].contains(where: { files.fileExists(atPath: userIcons.appendingPathComponent("\(value).\($0)").path) })
        else { return nil }
        let url = userIcons.appendingPathComponent("\(value).\(IconPackage.pathExtension)", isDirectory: true)
        return IconPackage.isPackage(url) ? url : nil
    }

    /// The `app-icon` pictures: built-ins, loose files, one pack for each folder in ~/.config/loupe/icons, and the
    /// current path if it is outside those. The grid makes each thumbnail at its size, off the main thread.
    static func appIconChoices() -> [IconChoice] {
        var words = [AppIcon.bundle]
        words += AppIcon.alternates.filter {
            Bundle.main.url(forResource: $0, withExtension: "icns", subdirectory: "AppIcons") != nil
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: userIcons, includingPropertiesForKeys: nil)) ?? []
        let extensions = ["png", "icns", "jpg", "jpeg", "heic", "tif", "tiff", IconPackage.pathExtension]
        let own = files.filter { ["png", "icns", IconPackage.pathExtension].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent.lowercased() }
            .filter { !$0.isEmpty }
        var choices = words.map {
            IconChoice(word: $0, file: iconFile($0), section: "Built-in")
        }
        for name in Set(own).sorted() where !words.contains(name) {
            choices.append(IconChoice(word: name, file: iconFile(name), section: "Yours"))
        }

        let packs = files.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !IconPackage.isPackage($0)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for pack in packs {
            let contents = (try? FileManager.default.contentsOfDirectory(at: pack, includingPropertiesForKeys: nil)) ?? []
            for file in contents.filter({ extensions.contains($0.pathExtension.lowercased()) })
                .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let path = file.standardizedFileURL.path
                choices.append(IconChoice(word: path, file: iconFile(path), section: pack.lastPathComponent,
                                          pack: pack.standardizedFileURL.path))
            }
        }

        let current = shared.config.appIcon
        if AppIcon.isPath(current), !choices.contains(where: { $0.word == current }) {
            choices.append(IconChoice(word: current, file: iconFile(current), section: "Other"))
        }
        return choices
    }

    /// The picture file of an `app-icon` value: its file (`appIconURL`), or for `owl` the bundle's own icon. An Icon
    /// Composer package not compiled yet has none: it is compiled now, and shows the next time the grid reads it.
    private static func iconFile(_ value: String) -> URL? {
        if appIconURL(value) == nil, let package = iconPackage(value) {
            Task { _ = await IconPackage.compile(package) }
            return nil
        }
        return appIconURL(value)
            ?? (value == AppIcon.bundle ? Bundle.main.url(forResource: "AppIcon", withExtension: "icns") : nil)
    }

    private func pushLimits() {
        guard let cache else { return }
        let limits = CacheLimits(config: config)
        guard limits != pushedLimits else { return }
        pushedLimits = limits
        Task { await cache.setLimits(limits) }
    }

    /// The Zoom menu itself, whose Keep Zoom and Position checkmark follows the main window each time it opens.
    private final class ZoomTopMenu: NSMenu {}

    /// Zoom: the viewer's zoom keys; Keep Zoom and Position (`L`, the main window's folder value) and its ⇧L, and
    /// Upscale Small Images in Fit (M4b spec §4.4); then the Zoom Stops section (Fit Width, Fit Height, 100 %, Haptic
    /// Feedback). The checkboxes without a key write loupe.conf.
    func makeZoomMenu() -> NSMenu {
        makeZoomMenu(includeToolbarActions: true)
    }

    /// The toolbar's Zoom Options: the menu without the entries the zoom block has.
    func makeZoomToolbarMenu() -> NSMenu {
        makeZoomMenu(includeToolbarActions: false)
    }

    private func makeZoomMenu(includeToolbarActions: Bool) -> NSMenu {
        let menu = ZoomTopMenu(title: "Zoom")
        menu.delegate = self   // `menuHasKeyEquivalent`
        let keys: [(String, KeyAction)] = includeToolbarActions ? [
            ("Fit", .fit), ("Actual Size", .actual100), ("200 %", .actual200), ("400 %", .actual400),
            ("Fit Width", .fitWidth), ("Fit Height", .fitHeight), ("Fill", .fill), ("Fit ↔ 100 %", .toggleFitActual),
            ("Zoom In", .zoomIn), ("Zoom Out", .zoomOut),
        ] : [
            ("200 %", .actual200), ("400 %", .actual400), ("Fit ↔ 100 %", .toggleFitActual),
        ]
        for (title, action) in keys { menu.addItem(.viewerKey(title, action)) }
        menu.addItem(.separator())
        menu.addItem(.viewerKey("Keep Zoom and Position", .toggleKeepZoom))
        menu.addItem(.viewerKey("Save Keep Zoom as Default", .saveKeepZoom))
        menu.addItem(.viewerKey("Keep Scale Instead of Share", .toggleZoomCarry))
        menu.addItem(.viewerKey("Save Share or Scale as Default", .saveZoomCarry))
        let upscale = menu.addItem(withTitle: "Upscale Small Images in Fit", action: #selector(toggleFitUpscale(_:)),
                                   keyEquivalent: "")
        upscale.target = self
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Zoom Stops"))
        for (tag, title) in ["Fit Width", "Fit Height", "100 %"].enumerated() {
            let item = menu.addItem(withTitle: title, action: #selector(toggleZoomStop(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
        }
        let haptics = menu.addItem(withTitle: "Haptic Feedback", action: #selector(toggleHaptics(_:)), keyEquivalent: "")
        haptics.target = self
        return menu
    }

    /// The menus are delegated here for their contents (`menuNeedsUpdate`) and so that they never match a key: the Zoom,
    /// Scaling and Colour menus have no ⌘ keys, only the viewer's plain ones, which they show and the viewer handles itself
    /// (`ViewerView.performKeyEquivalent`). Declining here keeps those keys typing in any other window (the Open panel's
    /// type-select) instead of a menu item taking them.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    /// The Scaling menu itself, whose radio sections are made again each time it opens.
    private final class ScalingTopMenu: NSMenu {}

    /// A Scaling submenu: its `key` is what its items write and what its radio follows.
    private final class ScalingMenu: NSMenu {
        var key = ""
    }

    /// The radio sections of the Scaling menu: header title, key.
    private static let scalingSections = [("Downscale", "downscale"), ("Upscale", "upscale"), ("Strong Upscale", "upscale-high")]
    /// The tag of the Scaling menu's section items, removed and made again by `menuNeedsUpdate`.
    private static let scalingSectionTag = 1

    /// Scaling (folder settings spec §6): the viewer's scaling keys; the Downscale, Upscale and Strong Upscale filters as
    /// radio sections and Anti-ringing; the thresholds and the pyramid filter as submenus; Reset Folder Scaling. A pick
    /// writes loupe.conf, like Zoom Stops; the sections and submenus are filled by `menuNeedsUpdate`, which also names
    /// the main window's folder value.
    func makeScalingMenu() -> NSMenu {
        let menu = ScalingTopMenu(title: "Scaling")
        menu.delegate = self
        let keys: [(String, KeyAction)] = [
            ("Next Filter", .cycleFilter), ("Save Filters as Default", .saveFilters),
            ("Anti-ringing for This Folder", .toggleAntiring), ("Save Anti-ringing as Default", .saveAntiring),
        ]
        for (title, action) in keys { menu.addItem(.viewerKey(title, action)) }
        menu.addItem(.separator())
        // The sections go here (`menuNeedsUpdate`), after the first separator.
        menu.addItem(.separator())
        let antiring = menu.addItem(withTitle: "Anti-ringing", action: #selector(toggleAntiring(_:)), keyEquivalent: "")
        antiring.target = self
        menu.addItem(.separator())
        func submenu(_ title: String, key: String) {
            let sub = ScalingMenu(title: title)
            sub.key = key
            sub.delegate = self
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        submenu("Strong Upscale From", key: "upscale-high-from")
        submenu("Pixel Art", key: "pixel-art")
        submenu("Pyramid Filter", key: "pyramid-filter")
        menu.addItem(.separator())
        // No target: the key window's controller answers and validates it (none, no item).
        menu.addItem(withTitle: "Reset Folder Scaling", action: #selector(ViewerWindowController.resetFolderScaling(_:)),
                     keyEquivalent: "")
        menuNeedsUpdate(menu)
        return menu
    }

    /// The Colour menu itself, whose checkmarks follow the main window each time it opens.
    private final class ColourTopMenu: NSMenu {}

    /// Colour (M3c spec §2.1): the viewer's colour keys with their checkmarks, the Method radios (the folder's
    /// `auto-color-method`, picked by `ViewerWindowController.pickColourMethod`) and Reset Folder Colour. Like the
    /// Scaling menu's Reset, the Method and Reset items have no target: the key window's controller answers and
    /// validates them (none, no item).
    func makeColourMenu() -> NSMenu {
        let menu = ColourTopMenu(title: "Colour")
        menu.delegate = self
        menu.addItem(.viewerKey("Auto Colour", .toggleAutoColor))
        let method = NSMenu(title: "Method")
        for (kind, title) in ColourKeys.menuMethods {
            let item = method.addItem(withTitle: title, action: #selector(ViewerWindowController.pickColourMethod(_:)),
                                      keyEquivalent: "")
            item.representedObject = kind.rawValue
        }
        let methodItem = NSMenuItem(title: "Method", action: nil, keyEquivalent: "")
        methodItem.submenu = method
        menu.addItem(methodItem)
        menu.addItem(.viewerKey("Vibrance", .toggleVibrance))
        menu.addItem(.separator())
        menu.addItem(.viewerKey("Save Auto Colour as Default", .saveAutoColor))
        menu.addItem(.viewerKey("Save Vibrance as Default", .saveVibrance))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reset Folder Colour", action: #selector(ViewerWindowController.resetFolderColour(_:)),
                     keyEquivalent: "")
        menuNeedsUpdate(menu)
        return menu
    }

    /// The radios follow loupe.conf, not the main window's folder values. Those show where the window's value for the
    /// key comes from a folder: in a section's header (`Upscale — this folder: ewa-lanczos`), as a submenu's inactive
    /// last line `This folder: <value>`.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let viewer = NSApp.mainWindow?.windowController as? ViewerWindowController
        if menu is ZoomTopMenu {
            // The main window's folder value over loupe.conf's, like the Colour menu.
            let effective = viewer?.effectiveConfig ?? config
            for item in menu.items {
                switch item.representedObject as? String {
                case KeyAction.toggleKeepZoom.rawValue: item.state = effective.keepZoomPosition ? .on : .off
                case KeyAction.toggleZoomCarry.rawValue: item.state = effective.keepZoomAs == .scale ? .on : .off
                default: break
                }
            }
            return
        }
        if menu is ColourTopMenu {
            // What the main window draws with (its folder's values on loupe.conf's), unlike the Scaling radios.
            let config = viewer?.colourConfig ?? self.config
            for item in menu.items {
                switch (item.representedObject as? String).flatMap(KeyAction.init(rawValue:)) {
                case .toggleAutoColor: item.state = config.autoColor ? .on : .off
                case .toggleVibrance: item.state = config.vibrance ? .on : .off
                default: break
                }
            }
            return
        }
        if menu is ScalingTopMenu {
            for item in menu.items where item.tag == Self.scalingSectionTag { menu.removeItem(item) }
            guard var index = menu.items.firstIndex(where: \.isSeparatorItem) else { return }
            index += 1
            for (title, key) in Self.scalingSections {
                let header = NSMenuItem.sectionHeader(title: viewer?.folderValueText(forKey: key)
                    .map { "\(title) — this folder: \($0)" } ?? title)
                for item in [header] + choiceItems(for: key) {
                    item.tag = Self.scalingSectionTag
                    menu.insertItem(item, at: index)
                    index += 1
                }
            }
            return
        }
        guard let menu = menu as? ScalingMenu else { return }
        menu.removeAllItems()
        for item in choiceItems(for: menu.key) { menu.addItem(item) }
        if let value = viewer?.folderValueText(forKey: menu.key) {
            menu.addItem(.separator())
            menu.addItem(withTitle: "This folder: \(value)", action: nil, keyEquivalent: "")
        }
    }

    /// `key`'s choices (`ScalingKeys.menuChoices`) as radio items on loupe.conf's value, picked by `pickScaling`.
    private func choiceItems(for key: String) -> [NSMenuItem] {
        let current = config.text(forKey: key) ?? ""
        return ScalingKeys.menuChoices(for: key, current: current).map { value in
            let item = NSMenuItem(title: ScalingKeys.menuTitle(key: key, value: value), action: #selector(pickScaling(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = [key, value]
            item.state = value == current ? .on : .off
            return item
        }
    }

    @objc private func pickScaling(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? [String], pick.count == 2 else { return }
        change(pick[0]) { _ = $0.set(pick[0], pick[1]) }
    }

    @objc private func toggleAntiring(_ sender: NSMenuItem) {
        change(ScalingKeys.antiringKey) { $0.lanczosAntiring.toggle() }
    }

    /// Checkmarks follow the config each time the menu opens.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleZoomStop(_:)):
            item.state = Self.menuStops.indices.contains(item.tag) && config.hasZoomStop(Self.menuStops[item.tag]) ? .on : .off
        case #selector(toggleHaptics(_:)):
            item.state = config.zoomStopHaptics ? .on : .off
        case #selector(toggleFitUpscale(_:)):
            item.state = config.fitUpscale ? .on : .off
        case #selector(pickPanIndicators(_:)):
            item.state = (item.representedObject as? String) == panIndicators.rawValue ? .on : .off
        case #selector(toggleAntiring(_:)):
            item.state = config.lanczosAntiring ? .on : .off
            // The checkmark is loupe.conf's; the main window's folder value, when it has one, is named in the title.
            let viewer = NSApp.mainWindow?.windowController as? ViewerWindowController
            item.title = viewer?.folderValueText(forKey: ScalingKeys.antiringKey)
                .map { "Anti-ringing (this folder: \($0))" } ?? "Anti-ringing"
        default: break
        }
        return true
    }

    @objc private func toggleZoomStop(_ sender: NSMenuItem) {
        guard Self.menuStops.indices.contains(sender.tag) else { return }
        change("zoom-stops") { $0.toggleZoomStop(Self.menuStops[sender.tag]) }
    }

    @objc private func toggleHaptics(_ sender: NSMenuItem) {
        change("zoom-stop-haptics") { $0.zoomStopHaptics.toggle() }
    }

    /// Zoom › Upscale Small Images in Fit: `fit-upscale` in loupe.conf, in every window at once (`.settingsChanged`).
    @objc private func toggleFitUpscale(_ sender: NSMenuItem) {
        change("fit-upscale") { $0.fitUpscale.toggle() }
    }

    // MARK: Pan indicators (M4b spec §5.4)

    /// `P`: the next mode (`auto → always → no`) for the session.
    func cyclePanIndicators() { setPanIndicators(panIndicators.next) }

    /// View › Pan Indicators: `mode` for the session, in every window.
    func setPanIndicators(_ mode: PanIndicatorMode) {
        panIndicatorsOverride = mode
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    /// `⇧P`: the session's mode into loupe.conf (`pan-indicators` only), which then is the windows' value again. False
    /// when the file could not be written; the session's mode stays.
    func savePanIndicators() -> Bool {
        guard saveAsDefault(["pan-indicators": panIndicators.rawValue]) else { return false }
        panIndicatorsOverride = nil
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        return true
    }

    /// View › Pan Indicators: Auto / Always / Off, checked at the session's mode, then the item that shows `P`.
    func makePanIndicatorsMenu() -> NSMenu {
        let menu = NSMenu(title: "Pan Indicators")
        let modes: [(PanIndicatorMode, String)] = [(.auto, "Auto"), (.always, "Always"), (.no, "Off")]
        for (mode, title) in modes {
            let item = menu.addItem(withTitle: title, action: #selector(pickPanIndicators(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
        }
        menu.addItem(.separator())
        menu.addItem(.viewerKey("Next Mode", .cyclePanIndicators))
        return menu
    }

    @objc private func pickPanIndicators(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(PanIndicatorMode.init(rawValue:)) else { return }
        setPanIndicators(mode)
    }

    /// The strip was resized by dragging its top edge: writes `strip-height` (and only it) and tells every
    /// strip, the dragged one included (it already has this height).
    func setStripHeight(_ pt: Int) {
        change("strip-height") { $0.stripHeight = Config.clampedStripHeight(Double(pt)) }
    }

    /// `⇧T`, View › Strip Beside the Photo and the strip's "where" button: writes `strip-window` (and only it, in the
    /// new spelling) and tells every strip, as the other View toggles do.
    func setStripWindow(_ mode: StripWindowMode) {
        change("strip-window") { $0.stripWindow = mode }
    }

    /// `⇧S` / `⇧A`: makes `values` (key → text, as in loupe.conf) the file's own, writing those keys and no others.
    /// False when the file could not be written; unlike a menu `change`, the session then goes back to the file's
    /// contents, so no window draws a default that was never saved.
    func saveAsDefault(_ values: [String: String]) -> Bool {
        // The texts come from `Config.text(forKey:)`, which `set` always takes.
        let saved = change(values.keys.sorted()) { config in for (key, value) in values { _ = config.set(key, value) } }
        if !saved { reload() }
        return saved
    }

    @discardableResult
    private func change(_ key: String, _ edit: (inout Config) -> Void) -> Bool { change([key], edit) }

    /// Applies `edit` to the file's current contents and writes `keys` back; false if the write failed. A failed
    /// write still changes this session's setting, and says why it was not saved. The strips hear of the result once,
    /// not of the file's old contents first (a strip being dragged would jump back for a moment).
    @discardableResult
    private func change(_ keys: [String], _ edit: (inout Config) -> Void) -> Bool {
        reload(pushToStrips: false)
        let before = config
        edit(&config)
        // The settings window follows this edit like any other change of the config (`reload` above saw none).
        // Announced from memory, not by re-reading: a failed write still changes the session, and the window shows it.
        defer { settingsStore?.configDidReload(from: before) }
        // `reload` set the file's old `pyramid-filter`; a menu pick of it must reach the loader too.
        pyramidFilter?.set(config.pyramidFilter)
        JXLSetting.shared.options = JXLOptions(config: config)
        applyAppearance()
        pushToAllStrips()
        do {
            try config.write(keys: keys, to: fileURL)
            return true
        } catch {
            FileHandle.standardError.write(Data("loupe: could not save \(fileURL.path): \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}
