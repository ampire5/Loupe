import LoupeCore
import SettingsKit

extension SettingsPanel {
    /// `#rrggbb` of a loupe.conf colour.
    static func hex(_ color: BackgroundColor) -> String {
        String(format: "#%02x%02x%02x", color.red, color.green, color.blue)
    }

    /// The `background` presets and their colours, for the colour well.
    static let backgroundNames = Dictionary(uniqueKeysWithValues: BackgroundColor.presets.map { ($0.name, hex($0.color)) })

    /// General (spec §5): launch and window, the folder, notifications.
    static let general = SettingsPage("general", "General", symbol: "gearshape", sections: [
        SettingsSection("Launch & Window", [
            SettingsCard([
                .choice("launch-reveal", "Full-screen launch", [
                    (word: "settled", title: "When settled"), (word: "immediate", title: "Immediately"),
                ], symbol: "play.rectangle",
                description: "When the photo appears at a launch back into full screen: once the window has settled, "
                    + "or during the animation. Default When settled."),
                .choice("icon-set", "Icons", [(word: "lucide", title: "Lucide"), (word: "sf", title: "SF Symbols")],
                        symbol: "star",
                        description: "The set the line icons are drawn from. Takes effect at the next launch. "
                            + "Default Lucide."),
                .choice("open-in", "Open files in", [
                    (word: "tab", title: "Tab"), (word: "window", title: "Window"),
                    (word: "replace", title: "Current tab"),
                ], symbol: "macwindow.on.rectangle",
                description: "Where a file that is not open yet goes: a new tab in the front window, a new window, or "
                    + "the current tab. Default Tab."),
                .choice("new-window-fullscreen", "New window from full screen", [
                    (word: "follow", title: "Full screen"), (word: "no", title: "Window"),
                ], symbol: "rectangle.on.rectangle",
                description: "A window opened from a full-screen one: full screen too, in a Space of its own, or an "
                    + "ordinary window. Default Full screen."),
                .color("background", "Background", names: backgroundNames, symbol: "square.fill",
                       description: "The colour around the photo, in a window and in full screen: black, dark-gray, "
                        + "medium-gray, light-gray, white, #RRGGBB or #RGB. Default #2a2a2a."),
                .choice("appearance", "Appearance", [
                    (word: "system", title: "System"), (word: "light", title: "Light"), (word: "dark", title: "Dark"),
                ], symbol: "circle.lefthalf.filled",
                description: "Light or dark windows and Home. The photo and everything over it stay dark."),
                .number("cursor-autohide", "Hide the cursor after", unit: "ms", step: 100, symbol: "cursorarrow",
                        description: "Without mouse movement over the photo (never over the strip); keys and scrolling "
                            + "do not bring it back. 1–600000 ms, or no; default 1000."),
            ]),
            SettingsCard([
                .icon("app-icon", "Dock icon", choices: { context?.iconChoices() ?? [] }, folder: context?.iconFolder,
                      current: { value in
                          guard let context else { return nil }
                          if let one = context.iconChoice { return one(value) }
                          return context.iconChoices().first { $0.word == value }
                      },
                      symbol: "app.badge",
                      description: "While Loupe runs (Finder always shows the owl): a built-in picture, or one of "
                        + "yours from ~/.config/loupe/icons: loose pictures, or pictures in a folder pack (choose the "
                        + "pack first); an Icon Composer .icon is compiled once with Xcode. Choose… adds loose pictures "
                        + "there too. A file path set in loupe.conf shows as its own picture. Default owl."),
            ]),
        ]),
        SettingsSection("Home", [
            SettingsCard([
                .choice("home-tab", "Home shows", [
                    (word: "recent", title: "Recent"), (word: "sessions", title: "Sessions"),
                    (word: "folders", title: "Folders"), (word: "stash", title: "Stash"),
                ], symbol: "house",
                description: "What a new tab, a new window or a launch without a photo shows first; choosing in the "
                    + "sidebar changes it. Stash only with a Stash address set. Default Recent."),
                .choice("home-start", "Start page", [
                    (word: "recent", title: "Recent"), (word: "sessions", title: "Sessions"),
                    (word: "folders", title: "Places"), (word: "stash", title: "Stash"),
                ], symbol: "house.fill",
                description: "Where the toolbar's house and ⇧⌘H on Home go. Stash only with a Stash address set. "
                    + "Default Recent."),
                .toggle("home-sidebar", "Sidebar", symbol: "sidebar.left",
                        description: "Home's sidebar of sources, places and folders. ⌃⌘S on Home. Default on."),
                .toggle("home-path-bar", "Path bar", symbol: "chevron.right.2",
                        description: "The folders from the places down to the one shown, under the grid; a click goes "
                            + "to one. ⌥⌘P on Home. Default on."),
                .number("home-sidebar-width", "Sidebar width", unit: "pt", step: 10, symbol: "rectangle.lefthalf.inset.filled",
                        description: "Dragging the sidebar's right edge sets it too. 180–1600 pt, shown at most a third of "
                            + "the window (400 pt in any window). Default 384."),
                .toggle("home-sidebar-compact", "Join single-folder chains", symbol: "arrow.right.to.line",
                        description: "A folder holding one folder only shows with it on one row, a › b › c, as in "
                            + "VS Code. Default on."),
                .choice("home-sidebar-indent", "Tree indent", [
                    (word: "compact", title: "Compact"), (word: "even", title: "Even"),
                ], symbol: "increase.indent",
                description: "Compact: 14 pt for the first three levels, 6 pt past them, with a line per level. "
                    + "Even: 14 pt at every level. Default Compact."),
                .toggle("home-sidebar-folders-first", "Folders before archives", symbol: "folder.fill",
                        description: "The tree lists a folder's subfolders first, then its archives, each by name. "
                            + "Off: all by name together. Default on."),
                .number("home-sidebar-reroot", "Restart the tree at depth", step: 1, symbol: "arrow.turn.left.up",
                        description: "The current folder this many levels under its place or deeper: the tree starts "
                            + "again further down, under one row of the folders left out (it opens the last of them). "
                            + "0 never, else 3–20. Default 0."),
                .number("browser-card-size", "Thumbnail size", unit: "pt", step: 20, symbol: "square.grid.3x3.square",
                        description: "The wanted thumbnail width on Home; the thumbnails grow to fill the width, "
                            + "folder and Recent cards are 1.6 times as wide. ⌘= / ⌘− there change the column count. "
                            + "60–480 pt, default 387."),
                .choice("grid-style", "Folders thumbnails", [
                    (word: "square", title: "Square"), (word: "aspect", title: "Aspect"),
                ], symbol: "photo.on.rectangle",
                description: "Square: each photo fills its square, cropped. Aspect: each photo whole inside its square. "
                    + "⌥T in Folders. Default Square."),
                .choice("grid-names", "Folders names", [
                    (word: "auto", title: "By size"), (word: "off", title: "Off"), (word: "photo", title: "On photo"),
                    (word: "below", title: "Below"),
                ], symbol: "character.textbox",
                description: "By size: names and facts under thumbnails from 160 pt, on hover on smaller ones. Or names "
                    + "on the thumbnails, under them, or none (the selected one shows in the bar). ⌥N in Folders. "
                    + "Default By size."),
                .choice("folder-cover", "Folder covers", [
                    (word: "grid", title: "Grid"), (word: "hero", title: "Hero"), (word: "stack", title: "Stack"),
                    (word: "single", title: "Single"),
                ], symbol: "rectangle.split.2x1",
                description: "How a folder's card shows what is inside. Narrow cards always show one photo. "
                    + "Default Hero."),
                .choice("folder-cards", "Folder cards", [
                    (word: "posters", title: "Posters"), (word: "cards", title: "Cards"), (word: "list", title: "List"),
                ], symbol: "rectangle.grid.1x2",
                description: "How folders and archives show in the browser: a big cover with a line of facts below, a "
                    + "compact card, or a list. Remembered for each folder, like its sort."),
                .choice("grid-style-memory", "Square or Aspect", [
                    (word: "tab", title: "Per tab"), (word: "folder", title: "Per folder"),
                    (word: "global", title: "Everywhere"),
                ], symbol: "rectangle.grid.2x2",
                description: "How the Square / Aspect choice (⌥T) is remembered. Per tab: each window or tab keeps its "
                    + "own until it closes, a new one starts from the Folders thumbnails setting. Per folder: saved for "
                    + "the folder and the ones under it, like its sort. Everywhere: changes the Folders thumbnails "
                    + "setting for all. "
                    + "Default Per tab."),
                .choice("session-restore", "At launch", [
                    (word: "none", title: "Home"), (word: "last", title: "Last Session"),
                ], symbol: "rectangle.stack.badge.play",
                description: "A launch without a photo: Home, or the windows and tabs that were open when Loupe last "
                    + "quit. Opening a photo from the Finder never restores anything. Default Home."),
                .number("recent-count", "Recent folders", unit: "folders", step: 4, symbol: "clock",
                        description: "How many recent folders, archives and Stash galleries Home shows. 0–200, "
                            + "0 = none; default 24."),
            ]),
        ]),
        SettingsSection("Folder", [
            SettingsCard([
                .number("folder-poll", "Re-read the folder every", unit: "ms", step: 500, symbol: "arrow.clockwise",
                        description: "A backup for the system's change notices (kqueue, SMB too), then 10× rarer. "
                            + "500–60000 ms, 0 = no polling; default 3000."),
                .choice("folder-view-memory", "Folder view memory", [
                    (word: "folder", title: "Every photo"), (word: "photo", title: "Last photo only"),
                    (word: "no", title: "Off"),
                ], symbol: "rectangle.stack",
                description: "The zoom and position saved on leaving a folder: for any photo opened there again, or "
                    + "only the one you left on. Default Every photo."),
                .toggle("archive-folders", "Zip archives as folders", symbol: "archivebox",
                        description: "Folder steps go into .zip files next to folders, and a zip opens like a folder. "
                            + "Default on."),
            ]),
            SettingsCard([
                .toggle("folder-scroll-gesture", "Folder gesture", symbol: "arrow.left.arrow.right",
                        description: "Hold a button and scroll sideways for the next or previous folder: trackpad click "
                            + "+ two-finger swipe, right button + wheel tilt. Default on.",
                        nested: [
                            .choice("folder-scroll-direction", "Direction", [
                                (word: "reversed", title: "Reversed"), (word: "natural", title: "Natural"),
                            ], description: "Reversed: fingers right or tilt left goes to the next folder; Natural: "
                                + "the other way. Default Natural."),
                            .number("folder-scroll-threshold", "Distance", unit: "pt", step: 5,
                                    description: "Sideways scroll for one folder (a notched wheel: its first notch). "
                                        + "10–400 pt, default 40."),
                            .number("folder-scroll-repeat", "Repeat pause", unit: "ms", step: 50,
                                    description: "Between steps while the button is held. 100–2000 ms, 0 = one step "
                                        + "per press; default 350."),
                        ]),
            ]),
        ]),
        SettingsSection("Notifications", rows: [
            .number("toast-duration", "Message duration", unit: "ms", step: 250, symbol: "text.bubble",
                    description: "How long the messages at the bottom of the window stay; they fade in 0.25 s. "
                        + "500–10000 ms, default 2000."),
            .toggle("folder-toast", "Folder name on entering", symbol: "rectangle.and.text.magnifyingglass",
                    description: "Entering another folder — a step, an open from Finder — says its name in a "
                        + "message; a Stash gallery says its title and its place in the list. Default on."),
            .toggle("config-warnings", "Config errors in the window", symbol: "exclamationmark.triangle",
                    description: "A problem in loupe.conf shows as a banner at the top of the window for 8 s, not "
                        + "only on stderr. Default on."),
        ]),
    ])
}
