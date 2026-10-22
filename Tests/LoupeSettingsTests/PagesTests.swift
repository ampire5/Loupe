import Testing
import AppKit
import SettingsKit
import LogiHIDPP
import LoupeCore
@testable import LoupeSettings

/// The settings pages as data (spec §5, §6): which keys they list and what kind of row each key gets.
@MainActor
struct PagesTests {
    private var rows: [SettingsRow] { SettingsPanel.pages().flatMap(\.rows) }

    private func row(_ key: String) -> SettingsRow? { rows.first { $0.key == key } }

    private func words(_ key: String) -> [String] {
        guard case .choice(let items) = row(key)?.kind else { return [] }
        return items.map(\.word)
    }

    /// Spec §5: the pages in order, and together every `Config.keys` key exactly once.
    @Test func pagesCoverEveryKeyOnce() {
        let pages = SettingsPanel.pages()
        #expect(pages.map(\.id) == ["general", "zoom-pan", "quality", "colour", "strip", "interface", "mouse",
                                    "key-bindings", "performance", "stash", "advanced"])
        let keys = pages.flatMap(\.keys)
        #expect(Config.keys.count == 124)
        #expect(Set(keys).count == keys.count, "a key is listed twice: \(keys.filter { k in keys.filter { $0 == k }.count > 1 })")
        #expect(Set(keys) == Set(Config.keys), "missing \(Set(Config.keys).subtracting(keys)), extra \(Set(keys).subtracting(Config.keys))")
    }

    /// Spec §5: the sections of each page, in order.
    @Test func sectionsAsInTheSpec() {
        let sections = Dictionary(uniqueKeysWithValues: SettingsPanel.pages().map { ($0.id, $0.sections.map(\.title)) })
        #expect(sections["colour"] == ["Auto Colour", "Vibrance"])
        #expect(sections["strip"] == ["Strip", "Thumbnails"])
        #expect(sections["interface"] == ["Stats Bar", "Two Pages"])
        #expect(sections["mouse"] == ["Buttons", "Wheel", "Haptics", "MX Master"])
        #expect(sections["performance"] == ["Cache", "Catalog", "JPEG XL", "Navigation"])
        #expect(sections["key-bindings"] == ["Keyboard", "Mouse"])
        #expect(sections["advanced"] == ["Files"])
        #expect(sections["stash"] == ["Library"])
    }

    /// A key that takes and writes back both `yes` and `no` is a switch (`show-blurry=no` is one of three words).
    @Test func boolKeysAreToggles() {
        func isBool(_ key: String) -> Bool {
            ["yes", "no"].allSatisfy { word in
                var config = Config()
                return config.set(key, word) == .ok && config.text(forKey: key) == word
            }
        }
        let defaults = Config()
        for row in rows {
            guard let key = row.key, let text = defaults.text(forKey: key), text == "yes" || text == "no",
                  isBool(key) else { continue }
            guard case .toggle = row.kind else {
                Issue.record("\(key) defaults to \(text) but is not a toggle")
                continue
            }
        }
    }

    /// The two-page rows say what their menu items and toasts say: Shift Pages (⌥D, «Pages shifted»).
    @Test func spreadShiftNamedAsItsMenuItem() {
        #expect(rows.first { $0.id == "spread-shift" }?.title == "Shift pages (first page alone)")
    }

    @Test func everyRowHasTitleAndDescription() {
        for row in rows {
            if case .custom = row.kind { continue }            // a table: no title or description shown
            #expect(!row.title.isEmpty, "\(row.id) has no title")
            #expect(!(row.description ?? "").isEmpty, "\(row.id) has no description")
        }
    }

    /// Every word of a pop-up is a value `Config.set` takes and writes back as is, and the key's default is one of
    /// them (so the pop-up never shows the default as an extra item).
    @Test func choiceKeysOfferEveryWord() {
        for row in rows {
            guard let key = row.key, case .choice(let items) = row.kind else { continue }
            #expect(Set(items.map(\.word)).count == items.count, "\(key): a word twice")
            #expect(Set(items.map(\.title)).count == items.count, "\(key): a title twice")
            for item in items {
                var config = Config()
                #expect(config.set(key, item.word) == .ok, "\(key)=\(item.word) is refused")
                #expect(config.text(forKey: key) == item.word, "\(key)=\(item.word) is written differently")
                #expect(!item.title.isEmpty)
            }
            let fallback = Config().text(forKey: key) ?? ""
            #expect(items.contains { $0.word == fallback }, "\(key): default \(fallback) is not in the pop-up")
        }
    }

    /// The pop-ups of the enumerations offer the whole set (spec §11).
    @Test func choicesOfferTheWholeSet() {
        func set(_ key: String) -> Set<String> { Set(words(key)) }
        #expect(set("launch-reveal") == ["settled", "immediate"])
        #expect(set("open-in") == ["tab", "window", "replace"])
        #expect(set("new-window-fullscreen") == ["follow", "no"])
        #expect(set("cache-idle-keep") == ["full", "preview"])
        #expect(set("folder-view-memory") == ["folder", "photo", "no"])
        #expect(set("folder-scroll-direction") == ["natural", "reversed"])
        #expect(set("pan-indicators") == Set(PanIndicatorMode.allCases.map(\.rawValue)))
        #expect(set("upscale") == Set(UpscaleFilter.cycle.map(\.text)))
        #expect(set("upscale-high") == Set(UpscaleFilter.cycle.map(\.text)))
        #expect(set("downscale") == Set(DownscaleFilter.cycle.map(\.text)))
        #expect(set("pyramid-filter") == ["lanczos3", "box"])
        #expect(set("transparency") == Set(TransparencyMode.allCases.map(\.rawValue)))
        #expect(set("default-zoom-mode").isSuperset(of: ["fit", "fit-width", "fit-height", "fill", "100%"]))
        #expect(set("auto-color-method") == Set(AutoColorMethod.allCases.map(\.rawValue)))
        #expect(set("strip-window") == ["beside", "over", "hidden"])
        #expect(set("strip-scroll-direction") == ["natural", "reversed"])
        #expect(set("wheel-direction") == Set(WheelDirection.allCases.map(\.rawValue)))
        #expect(set("mx-side-buttons") == Set(SideButtonsMode.allCases.map(\.rawValue)))
        #expect(set("cache-full") == ["0", "1", "2"])
        #expect(set("cache-far-previews") == ["coarse", "full"])
        #expect(set("show-blurry") == ["no", "fit", "always"])
        #expect(set("wheel-step") == Set(StepWait.allCases.map(\.rawValue)))
        #expect(set("key-step") == Set(StepWait.allCases.map(\.rawValue)))
        #expect(set("spread-direction") == ["ltr", "rtl"])
        #expect(set("spread-landscape") == ["alone", "pair"])
        // Every pattern, plain and strong, and none.
        let patterns = HapticPattern.all.map(\.configName)
        let haptics = Set(["none"] + patterns + patterns.map { $0 + " strong" })
        for key in Config.keys where key.hasPrefix("haptic-") && key != "haptic-strength" && key != "haptic-strong-strength" {
            #expect(set(key) == haptics, "\(key)")
        }
    }

    /// The auto colour parts: one switch per `AutoColorFilter`.
    @Test func autoColourFiltersAreFlags() {
        guard case .flags(_, let items) = row("auto-color-filters")?.kind else {
            Issue.record("auto-color-filters is not a flags row")
            return
        }
        #expect(items.map(\.word) == AutoColorFilter.allCases.map(\.rawValue))
    }

    /// Dependent rows sit under their main row (spec §6).
    @Test func dependentRowsAreNested() {
        func nested(_ key: String) -> [String] { row(key)?.nested.compactMap(\.key) ?? [] }
        #expect(nested("pan-indicators") == ["pan-indicators-hide", "pan-indicators-fade", "pan-indicators-on-switch"])
        #expect(nested("mouse-haptics") == ["haptic-zoom-stop", "haptic-limit", "haptic-step", "haptic-toggle",
                                            "haptic-long-armed", "haptic-detent", "haptic-end", "haptic-strength",
                                            "haptic-strong-strength"])
        #expect(nested("stats-progress") == ["stats-progress-opacity"])
        #expect(nested("vibrance") == ["vibrance-amount"])
        #expect(nested("auto-color") == ["auto-color-method", "auto-color-strength", "auto-color-filters",
                                         "auto-color-vibrance-gain", "auto-color-threshold", "auto-color-full",
                                         "auto-color-fade"])
    }

    /// Which values of a main row grey its nested rows (spec §6).
    @Test func offValuesDimTheNestedRows() {
        let pan = row("pan-indicators")
        #expect(pan?.turnsNestedOff(value: "no") == true)
        #expect(pan?.turnsNestedOff(value: "auto") == false)
        #expect(pan?.turnsNestedOff(value: "always") == false)
        #expect(row("mouse-haptics")?.turnsNestedOff(value: "no") == true)
        #expect(row("stats-progress")?.turnsNestedOff(value: "no") == true)
        // A folder can switch auto colour and vibrance on (c, v) while loupe.conf has them off: their rows stay usable.
        #expect(row("auto-color")?.turnsNestedOff(value: "no") == false)
        #expect(row("vibrance")?.turnsNestedOff(value: "no") == false)
    }

    /// Colour rows: one well for the background, two for the checkerboard; every name `Config` takes is resolved to
    /// the colours it writes back as that name.
    @Test func colourRowsKnowTheNames() {
        guard case .color(let one) = row("background")?.kind, case .color(let two) = row("checker-colors")?.kind else {
            Issue.record("background / checker-colors are not colour rows")
            return
        }
        #expect(one == 1)
        #expect(two == 2)
        #expect(Set(row("background")?.colorNames.keys.map { $0 } ?? []) == Set(BackgroundColor.presets.map(\.name)))
        #expect(Set(row("checker-colors")?.colorNames.keys.map { $0 } ?? []) == ["light", "dark"])
        for key in ["background", "checker-colors"] {
            for (name, colours) in row(key)?.colorNames ?? [:] {
                var config = Config()
                #expect(config.set(key, colours) == .ok, "\(key)=\(colours)")
                #expect(config.text(forKey: key) == name, "\(key)=\(colours) is not \(name)")
            }
        }
    }

    /// `app-icon` is an icon pop-up whose items come from the app (the context).
    @Test func appIconAsksTheContext() {
        guard case .icon(let choices) = row("app-icon")?.kind else {
            Issue.record("app-icon is not an icon row")
            return
        }
        let saved = SettingsPanel.context
        defer { SettingsPanel.context = saved }
        SettingsPanel.context = SettingsPanelContext(configURL: URL(fileURLWithPath: "/tmp/loupe.conf"),
                                                     inputURL: URL(fileURLWithPath: "/tmp/input.conf"),
                                                     iconChoices: { [(word: "owl", image: nil), (word: "hat", image: nil)] })
        #expect(choices().map(\.word) == ["owl", "hat"])
        SettingsPanel.context = nil
        #expect(choices().isEmpty)
    }

    /// Every row's SF Symbol exists, and no two rows (or a row and a page) share one: a symbol tells them apart.
    @Test func rowSymbolsExistAndDiffer() {
        let pages = SettingsPanel.pages()
        var seen: [String: String] = [:]
        for page in pages {
            #expect(NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil) != nil, "page \(page.id)")
            seen[page.symbol] = "page \(page.id)"
        }
        for page in pages {
            for row in page.rows {
                guard let symbol = row.symbol else { continue }
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(row.id): \(symbol)")
                if let other = seen[symbol] { Issue.record("\(row.id) and \(other) share \(symbol)") }
                seen[symbol] = row.id
            }
        }
    }

    /// The rows of one page have distinct ids (keyless rows go by title).
    @Test func rowIDsAreUniqueWithinAPage() {
        for page in SettingsPanel.pages() {
            let ids = page.rows.map(\.id)
            #expect(Set(ids).count == ids.count, "\(page.id)")
        }
    }

    /// Advanced: the three file buttons.
    @Test func advancedHasTheFileButtons() {
        let page = SettingsPanel.pages().first { $0.id == "advanced" }
        let buttons = page?.rows.compactMap { row -> String? in
            if case .button(let title, _) = row.kind { return title }
            return nil
        }
        #expect(buttons == ["Open", "Open", "Reveal in Finder"])
    }

    /// Open input.conf: a missing file is made from the template; an existing one is left as it is.
    @Test func missingFileIsMadeFromTheTemplate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-adv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("input.conf")
        try SettingsPanel.makeIfMissing(url, contents: InputConfTemplate.text)
        #expect(try String(contentsOf: url, encoding: .utf8) == InputConfTemplate.text)
        try "f fullscreen\n".write(to: url, atomically: true, encoding: .utf8)
        try SettingsPanel.makeIfMissing(url, contents: InputConfTemplate.text)
        #expect(try String(contentsOf: url, encoding: .utf8) == "f fullscreen\n")
    }
}
