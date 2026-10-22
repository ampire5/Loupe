import FilmstripModel
import Foundation
import HomeScreenModel
import LogiHIDPP

/// `appearance`: light or dark windows and Home (the photo and everything over it stay dark). `system` follows macOS.
public enum AppAppearance: String, Sendable {
    case system, light, dark

    /// Whether the app is forced dark (true), forced light (false) or follows macOS (nil, `system`).
    public var prefersDark: Bool? {
        switch self {
        case .system: return nil
        case .light: return false
        case .dark: return true
        }
    }
}

/// `strip-window`: the thumbnail strip in a window (fullscreen always shows it over the photo).
public enum StripWindowMode: String, Sendable {
    case over, beside, hidden
}

/// `strip-scroll-direction`: which way a two-finger swipe over the strip moves the selection (the kit's
/// `FilmstripScrollDirection`: `natural`, fingers left go to the next files, or `reversed`).
public typealias StripScrollDirection = FilmstripScrollDirection

/// `launch-reveal`: when the photo first appears at a launch that goes back into full screen. `settled` (the default):
/// once the window is in full screen, so the system's animation moves an empty window (the photo popping up in it and
/// growing with it read as a jump, user 2026-10-16); `immediate`: as soon as it is decoded, during the animation.
public enum LaunchReveal: String, Sendable {
    case settled, immediate
}

/// `open-in`: where a file that no open tab shows yet goes. `tab` (the default): a new tab in the front viewer window;
/// `window`: a new window; `replace`: the current tab shows it, as before tabs.
public enum OpenIn: String, Sendable {
    case tab, window, replace
}

/// `home-tab`: the Home source a new tab, a new window or a launch without a file shows (Home spec §2.1, Photos style
/// spec §3.1): Recent, Sessions, a folder (`folders`) or Stash; Loupe writes the last one chosen back.
public enum HomeTab: String, Sendable, Codable {
    case recent, sessions, folders, stash
}

/// `keep-zoom-as`: what a free zoom (a pinch, a wheel, `=` / `-`) keeps when another photo comes or the window changes
/// size (`ViewTransform.carryingZoom`). `share` (the default): the share of the picture in view, so a turned photo of the
/// same pixel count keeps its scale and a resize keeps the framing; `scale`: the scale itself, 80 % stays 80 %, also
/// across a resize and in the folder's saved view. A folder key: `K` switches it for the folder.
public enum ZoomCarry: String, Sendable {
    case share, scale
}

/// `home-sidebar-indent`: how Home's sidebar indents its folder tree. `compact` (the default): 14 pt for the first
/// three levels, 6 pt past them, with a guide line per level; `even`: 14 pt at every level, no guides.
public enum SidebarIndent: String, Sendable {
    case compact, even
}

/// `folder-cover`: how a folder's or a zip's card on Home shows what is inside (folder covers spec). `grid`: up to four
/// photos 2 × 2; `hero` (the default): a large one on top, up to three small under it; `stack`: three prints piled with a
/// slight turn; `single`: one photo fills the card. A card narrower than 110 pt always shows one photo. Recent's session
/// mosaics follow it too.
public enum FolderCoverLayout: String, Sendable, CaseIterable {
    case grid, hero, stack, single
}

/// `session-restore`: what a launch without a file opens (Home spec §2.6). `none` (the default): Home; `last`: Last
/// Session's windows and tabs.
public enum SessionRestore: String, Sendable {
    case none, last
}

/// `new-window-fullscreen`: how a new window opened from a full-screen one appears. `follow` (the default): in full
/// screen too, in a Space of its own; `no`: as an ordinary window.
public enum NewWindowFullScreen: String, Sendable {
    case follow, no
}

/// `cache-idle-keep`: what an idle tab's current photo keeps when `cache-idle-trim` lets go of the rest. `full` (the
/// default): the photo as it is, up to full resolution, so coming back needs no read or decode; `preview`: down to
/// its screen-size preview.
public enum CacheIdleKeep: String, Sendable {
    case full, preview
}

/// `folder-scroll-direction`: which way the held-button folder gesture goes. `natural`: fingers left go to the next
/// folder, as the three-finger swipe goes to the next photo, and on a mouse tilt right / side wheel right / ⇧+wheel
/// down does, as the vertical wheel's down; `reversed` (the default, user after M4a): both the other way, fingers
/// right and tilt left / side wheel left / ⇧+wheel up go to the next folder.
public enum FolderScrollDirection: String, Sendable {
    case natural, reversed

    /// The factor that turns a scroll event's deltas into `FolderScrollGesture`'s convention (`dx < 0` is next).
    /// `natural`: precise deltas go by the fingers (`FingerDirection`), a notch by the device's own sign, where
    /// negative is wheel down / tilt right, "next" like the vertical wheel (the opposite of the fingers' sign);
    /// `reversed` turns both.
    public func factor(precise: Bool, invertedFromDevice: Bool) -> Double {
        let fingers = FingerDirection.sign(invertedFromDevice: invertedFromDevice)
        let natural = precise ? fingers : -fingers
        return self == .natural ? natural : -natural
    }
}

/// `mx-panel-force`: how hard the MX Master 4's haptic panel must be pressed (M4c spec §10.3). `keep` (the default)
/// never writes it, `default` writes the mouse's factory value, `0…100` goes linearly over the mouse's range (0 the
/// lightest it takes, 100 the stiffest).
public enum PanelForceSetting: Equatable, Sendable {
    case keep, factory, percent(Int)

    /// The force to write, in the mouse's units, given what the mouse reports; nil for `keep`.
    public func value(range: ClosedRange<UInt16>, defaultValue: UInt16) -> UInt16? {
        switch self {
        case .keep: return nil
        case .factory: return defaultValue
        case .percent(let p):
            let span = Double(range.upperBound - range.lowerBound)
            return range.lowerBound + UInt16((Double(min(max(p, 0), 100)) * span / 100).rounded())
        }
    }

    /// The value as loupe.conf spells it.
    public var text: String {
        switch self {
        case .keep: return "keep"
        case .factory: return "default"
        case .percent(let p): return String(p)
        }
    }

    /// `keep`, `default` (any case) or a whole number 0…100; nil otherwise.
    public static func parse(_ text: String) -> PanelForceSetting? {
        switch text.lowercased() {
        case "keep": return .keep
        case "default": return .factory
        default:
            guard let p = Int(text), (0...100).contains(p) else { return nil }
            return .percent(p)
        }
    }
}

/// `app-icon`: the Dock icon while Loupe runs. A name or a path, so pictures can be added without a rebuild:
/// - a name is looked up as ~/.config/loupe/icons/<name>.icns, <name>.png or an Icon Composer <name>.icon (compiled
///   once with Xcode's actool) first (your own; it may also replace a bundled one), then among the icons in the app (Contents/Resources/AppIcons, from Resources/Icons/Alternates);
/// - a value with a `/` or starting with `~` is a path to any image file.
/// Names are case-insensitive; a name or file that is not there keeps the current icon and is reported once.
/// The PNG is shown as it is: give it the rounded square and its margins (an Icon Composer or ictool render).
public enum AppIcon {
    /// The bundle's own icon (Finder shows it too): a clear glass owl's head with a gold beak and a gold monocle,
    /// on plum.
    public static let bundle = "owl"
    /// The pictures in the app besides `owl`: the chrome woman's profile with pixels in her glasses (`profile`, the
    /// bundle icon until 2026-10-15), the hat with a feather under a loupe (`hat`), the white dress over the grate
    /// (oil, and the night scene), and glass and gold on plum: Aphrodite's head in a laurel wreath with a monocle
    /// (`aphrodite`).
    public static let alternates = ["profile", "hat", "grate", "night", "aphrodite"]

    /// Whether `value` names a file rather than an icon.
    public static func isPath(_ value: String) -> Bool { value.contains("/") || value.hasPrefix("~") }

    /// The value as stored: a path as written, a name lowercased; nil when it is neither (empty, or a name with
    /// characters other than letters, digits, `-`, `_` and `.`).
    static func normalized(_ value: String) -> String? {
        if isPath(value) { return value }
        let name = value.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return name
    }
}

/// What `Config.set` made of a `key=value` pair.
public enum SetResult: Equatable, Sendable {
    /// The value was taken.
    case ok
    /// A known key whose value is not valid; the config is unchanged.
    case badValue
    /// Not a loupe.conf key; the config is unchanged.
    case unknownKey
}

/// Settings from ~/.config/loupe/loupe.conf: mpv-style `key=value`, `#` comments. A missing file or key
/// means the default; the file is only created when a setting is changed from the menu.
public struct Config: Equatable, Sendable {
    public static let defaultZoomStops: [ZoomStop] = [.fitWidth, .fitHeight, .percent(100)]

    /// `zoom-stops`: where pinch and right-button zoom halt (spec §8.4), in file order, which decides
    /// which of two near-equal stops wins. A list with no known stop at all means the defaults (a typo
    /// like `fit_width` should not silently turn every stop off).
    public var zoomStops: [ZoomStop] {
        get { Self.resolve(zoomStopTokens).stops }
        set { zoomStopTokens = newValue.map(Self.text(of:)) }
    }
    /// `zoom-stops` as written in the file, unknown tokens included, so a menu toggle adds or removes only
    /// its own token and leaves a typo or a token from a newer Loupe where it was.
    private var zoomStopTokens = defaultZoomStops.map(Config.text(of:))
    /// `zoom-stop-haptics`: a trackpad tick when a gesture lands on a stop.
    public var zoomStopHaptics = true
    /// `zoom-animation`: milliseconds a zoom step (key, menu, double click, stop) glides, 0...1000 (`no`: 0, a jump;
    /// `yes`: the default).
    public var zoomAnimationMilliseconds = defaultZoomAnimationMilliseconds
    public static let defaultZoomAnimationMilliseconds = 150
    /// `zoom-rubber-band`: a pinch or right-button zoom past the limits stretches and springs back, instead of stopping.
    public var zoomRubberBand = true
    /// `keep-zoom-position`: a photo switch keeps the zoom mode and centre (folder key, `ZoomRules`).
    public var keepZoomPosition = true
    /// `keep-zoom-as`: what a kept free zoom keeps (`ZoomCarry`; folder key, `ZoomRules`).
    public var keepZoomAs = ZoomCarry.share
    /// `default-zoom-mode`: the mode a photo opens in when `keep-zoom-position` is off (folder key, `ZoomRules`).
    public var defaultZoomMode = ZoomMode.fit
    /// `fit-upscale`: Fit magnifies a photo smaller than the window (`no`: at most 100 %).
    public var fitUpscale = true
    /// `rmb-zoom-speed`: multiplier on the right-button zoom's rate (0.25...5); 1 is the M1 rate of 200 pt per
    /// doubling, the default 1.5 needs a third less travel.
    public var rmbZoomSpeed = 1.5
    /// `rmb-zoom-inertia`: the zoom keeps going, slowing down, after the right button is released mid-motion.
    public var rmbZoomInertia = false
    /// `thumb-wheel-zoom`: the MX Master's thumb wheel with no button held zooms smoothly at the pointer, right = in
    /// (`ThumbZoom`); `no` leaves it to the system's horizontal scrolling.
    public var thumbWheelZoom = true
    /// `thumb-zoom-speed`: doublings of the scale per turn of the thumb wheel (0.25...8).
    public var thumbZoomSpeed = 2.0
    /// `thumb-zoom-stops`: a `zoom-stops` stop only ticks the mouse (`tick`) or halts the turn (`halt`, as a pinch).
    public var thumbZoomStops = ThumbZoomStops.tick
    /// `thumb-zoom-invert`: the thumb wheel's zoom the other way, left = in.
    public var thumbZoomInvert = false
    /// `rubber-band`: panning past a photo's edge stretches it and springs back, instead of stopping dead.
    public var rubberBand = true
    /// `drag-inertia`: a left-button drag released mid-motion keeps gliding, slowing down.
    public var dragInertia = true
    /// `inertia-deceleration`: the glide's velocity multiplier per millisecond (0.99...0.999); closer to 1 glides
    /// further. 0.998 is UIScrollView's normal rate.
    public var inertiaDeceleration = 0.998
    /// `rmb-zoom-invert`: the right-button zoom runs the other way (drag down to zoom in).
    public var rmbZoomInvert = false
    /// `pan-indicators`: the position pills at the picture's edge (`PanIndicatorMode`).
    public var panIndicators = PanIndicatorMode.auto
    /// `pan-indicators-hide`: milliseconds the pills stay after the view stops moving (`auto`), 0...5000.
    public var panIndicatorsHideMilliseconds = 400
    /// `pan-indicators-fade`: milliseconds of the pills' fade, 0...2000.
    public var panIndicatorsFadeMilliseconds = 250
    /// `pan-indicators-on-switch`: a switch to another photo shows the pills like a pan (`auto`); `no` (the default):
    /// only panning and zooming the photo on screen do (M4b spec §5.2).
    public var panIndicatorsOnSwitch = false

    /// `spread`: two pages side by side (folder key; spec 2026-10-23-spread).
    public var spread = false
    /// `spread-shift`: the first page stands alone, pairs start from the second (folder key).
    public var spreadShift = false
    /// `spread-direction`: `rtl` puts the first page of a pair on the right (folder key).
    public var spreadRightToLeft = false
    /// `spread-landscape`: `alone` shows a landscape page by itself, `pair` pairs it like any other (folder key).
    public var spreadLandscapeAlone = true
    /// The pairing options the four spread keys give.
    public var spreadOptions: SpreadOptions {
        SpreadOptions(shift: spreadShift, rightToLeft: spreadRightToLeft, landscapeAlone: spreadLandscapeAlone)
    }

    // The cache settings (spec §3.5). `CacheLimits(config:)` is what the cache reads.
    /// `cache-full`: neighbours kept at full resolution, 0...2.
    public var cacheFull = 1
    /// `cache-previews`: photos kept at least at preview resolution, 1...200.
    public var cachePreviews = 20
    /// `cache-far-previews`: `coarse` (true) or `full`.
    public var cacheFarPreviewsCoarse = true
    /// `cache-files`: neighbours kept as compressed bytes, 0...50.
    public var cacheFiles = 24
    /// `cache-memory`: ceiling over all planned levels, in bytes; by default by the Mac's memory (`Machine`).
    public var cacheMemory = Machine.cacheMemory
    /// `cache-idle-trim`: minutes without use after which a tab's cache is trimmed, 0...1440 (0: never).
    public var cacheIdleTrimMinutes = 30
    /// `cache-idle-keep`: what an idle tab's current photo keeps when it is trimmed (`CacheIdleKeep`).
    public var cacheIdleKeep = CacheIdleKeep.full
    /// `show-blurry`.
    public var showBlurry = ShowBlurry.no
    /// `jxl-threads-current`: libjxl worker threads for the current photo's decode, 1...16; by default one per
    /// performance core (`Machine`).
    public var jxlThreadsCurrent = Machine.jxlThreadsCurrent
    /// `jxl-threads-other`: libjxl worker threads for neighbours and thumbnails, 1...16 (2 measured best,
    /// docs/bench/2026-10-20-jxl-tuning.md).
    public var jxlThreadsOther = 2
    /// `jxl-dc-preview`: first looks, coarse previews and thumbnails of JPEG XL from the 1:8 DC image.
    public var jxlDCPreview = true
    /// `wheel-step`: what a notched-wheel step waits for before the next notch may step (`StepGate`).
    public var wheelStep = StepWait.thumb
    /// `key-step`: the same for the keyboard's previous / next (a held key's repeats included).
    public var keyStep = StepWait.thumb
    /// `wheel-direction`: which way a wheel notch steps (`WheelDirection`).
    public var wheelDirection = WheelDirection.content
    /// `cursor-autohide`: milliseconds without mouse movement before the cursor hides over the picture
    /// (mpv's key and unit, 1...600000), or `no` (nil) to keep it visible.
    public var cursorAutohideMilliseconds: Int? = 1000

    // The thumbnail strip and thumbnail cache (M2.5 spec §7).
    /// `strip-window`: how the strip shows in a window; fullscreen always uses `over`.
    public var stripWindow = StripWindowMode.beside
    public static let stripHeightRange = 40...240

    /// A requested strip height (a drag's raw value, say) as a whole number of points inside `stripHeightRange`.
    public static func clampedStripHeight(_ requested: Double) -> Int {
        guard requested.isFinite else { return stripHeightRange.lowerBound }
        return min(max(Int(requested.rounded()), stripHeightRange.lowerBound), stripHeightRange.upperBound)
    }

    /// `strip-height`: cell height in points, 40...240 (also set by dragging the strip's top edge).
    public var stripHeight = 68
    public static let stripCellMaxRange = 0.5625...1.5
    /// `strip-cell-max`: how wide (width : height) a strip cell may grow when the strip has room, 0.5625 (9:16, never
    /// wider than the narrow cell) ...1.5 (3:2); never wider than the cell's photo. A number or `w:h` in loupe.conf.
    public var stripCellMax = 1.5
    /// `strip-corner-radius`: rounding of the cells' corners in points, 0...16 (0: square).
    public var stripCornerRadius = 3.0
    /// `strip-scroll-direction`: a two-finger swipe over the strip scrubs this way (`FilmstripScroll`).
    public var stripScrollDirection = StripScrollDirection.natural
    /// `strip-hide-delay`: milliseconds before the idle strip hides, 0...10000 (0: as soon as the mouse leaves).
    public var stripHideDelayMilliseconds = 200
    /// `strip-fade-in`: milliseconds of the strip's show fade, 0...2000 (0: it appears without animation).
    public var stripFadeInMilliseconds = 150
    /// `strip-fade-out`: milliseconds of the strip's hide fade, 0...2000 (0: it disappears without animation).
    public var stripFadeOutMilliseconds = 150
    /// `strip-jump-preview`: show the stretched thumbnail at once on a jump or scrub (`no`: a normal
    /// transition, as `show-blurry` says).
    public var stripJumpPreview = true
    /// `strip-loading-indicator`: a spinner while only the thumbnail is on screen.
    public var stripLoadingIndicator = false
    /// `thumb-size`: pixels on the long side, 256...1024 (part of the thumbnail cache key).
    public var thumbSize = 512
    /// `thumb-cache-size`: limit of the on-disk thumbnail database, in bytes; 0 keeps thumbnails in memory only.
    public var thumbCacheBytes = 2 << 30
    /// `folder-poll`: milliseconds between re-reads of the open folder while the app is active when it has no kqueue
    /// source, 500...60000, or 0 for none (kqueue and activation still re-read it; M2.5 spec §4.5). With kqueue the
    /// poll is a safety net, ten times rarer; `FolderPollSchedule` also stretches it on a slow share.
    public var folderPollMilliseconds = 3000
    /// `folder-view-memory`: `folder` (`yes`): a photo that arrives fresh (Finder, a launch, a folder step) opens in the
    /// zoom mode last used in its folder, and at its position when it has the same size; `photo`: only the folder's
    /// last photo does; `no`: never applied (it is still recorded, so turning it back on restores again).
    public var folderViewMemory = FolderViewMemory.folder
    /// `folder-scroll-gesture`: a horizontal scroll while a mouse button is held (trackpad click + two-finger swipe,
    /// right button + tilt / side wheel) steps to the next or previous folder (`FolderScrollGesture`).
    public var folderScrollGesture = true
    /// `folder-scroll-direction`: which way the fingers go to the next folder (`FolderScrollDirection`).
    public var folderScrollDirection = FolderScrollDirection.reversed
    public static let folderScrollThresholdRange = 10.0...400.0
    /// `folder-scroll-threshold`: horizontal travel in points, 10...400, that the held-button scroll needs before it
    /// steps (a notched wheel steps on its first horizontal notch regardless).
    public var folderScrollThreshold = 40.0
    /// `folder-scroll-repeat`: milliseconds, 100...2000, between folder steps while the button stays held (a further
    /// notch, a new swipe), or 0 for one step per press (Task 17d; Build 2.x behaved as 0).
    public var folderScrollRepeatMilliseconds = 350
    /// `archive-folders`: folder steps go into zip files next to folders (Stash spec §2.4).
    public var archiveFolders = true
    /// `folder-toast`: entering another folder (a step, an open from Finder or Stash) says its name in a toast; a
    /// Stash gallery says its title and place in the list.
    public var folderToast = true

    /// `mouse-long-press`: milliseconds a mouse button is held for its `-long` binding, 150...2000 (M4c spec §3.2).
    public var mouseLongPressMilliseconds = 400
    /// `mouse-move-step`: points of vertical mouse travel per step of a `+MOVE` binding, 4...200.
    public var mouseMoveStep = 20.0
    /// `mouse-haptics`: the mouse vibrates at all (`no`: never).
    public var mouseHaptics = true
    /// `mx-panel-force`: the haptic panel's force, written to the mouse when it connects and after a reload.
    public var mxPanelForce = PanelForceSetting.keep
    /// `mx-side-buttons`: how Loupe gets the MX Master's back / forward buttons (`SideButtonsMode`, M4c spec §12.1);
    /// applied at once by a reload.
    public var mxSideButtons = SideButtonsMode.watch
    /// `haptic-strength`: the mouse's normal haptic strength, 0…100, written when the mouse starts and after a reload
    /// that changes it; nil (`keep`, the default) never writes it (M4c spec §10.4). With `keep`, a strong play goes
    /// back to the strength the mouse reported at setup.
    public var hapticStrength: Int?
    /// `haptic-strong-strength`: 0…100, the strength of a `haptic-*` value that ends in `strong`.
    public var hapticStrongStrength = 80
    /// The `haptic-*` keys: a LogiHIDPP pattern, optionally strong, `nil` for `none` (M4c spec §5, §10.4).
    /// `haptic-zoom-stop`: a right-button zoom or a `zoom-step` meets a zoom stop.
    public var hapticZoomStop: HapticChoice? = HapticChoice(pattern: .subtleCollision)
    /// `haptic-limit`: a right-button zoom or a `zoom-step` reaches its limit, an `add` reaches the end of its range.
    public var hapticLimit: HapticChoice? = HapticChoice(pattern: .sharpCollision)
    /// `haptic-step`: a step of `add`.
    public var hapticStep: HapticChoice? = HapticChoice(pattern: .whisperCollision)
    /// `haptic-long-armed`: a held button whose long press fires on release reaches the long-press deadline (M4c spec §11).
    public var hapticLongArmed: HapticChoice? = HapticChoice(pattern: .dampStateChange)
    /// `haptic-detent`: an `add` step lands on or crosses 25 / 50 / 75 % of the key's range (M4c spec §11).
    public var hapticDetent: HapticChoice? = HapticChoice(pattern: .dampCollision)
    /// `haptic-toggle`: a toggling action (`toggle-*`, `cycle-*`).
    public var hapticToggle: HapticChoice? = HapticChoice(pattern: .sharpStateChange)
    /// `haptic-end`: a previous / next step by the wheel, a key or a mouse button stopped at an end of the folder.
    public var hapticEnd: HapticChoice? = HapticChoice(pattern: .sharpCollision, strong: true)

    /// `config-warnings`: loupe.conf problems are shown in the window as well as on stderr (Task 17c; `no`: stderr only).
    public var configWarnings = true
    /// `toast-duration`: milliseconds a toast (the key's one-line answer) stays before it fades, 500...10000.
    public var toastDurationMilliseconds = 2000

    /// `stats-progress`: the stats bar's background is filled left to right up to the folder position.
    public var statsProgress = true
    /// `stats-progress-opacity`: how strongly the filled part is lightened, as the opacity of white laid over the bar,
    /// 0.02...0.6 (user, Build 2 trial: the first fill, the bar's own grey a little more opaque, was hard to see).
    public var statsProgressOpacity = 0.15
    /// `stats-folder-name`: the open folder's name in the middle of the stats bar.
    public var statsFolderName = true

    /// `background`: the colour around the picture.
    public var background = BackgroundColor.default
    /// `launch-reveal`: the photo waits for the window to settle in full screen at launch (`LaunchReveal`).
    public var launchReveal = LaunchReveal.settled
    /// `open-in`: where a file that no open tab shows goes (`OpenIn`).
    public var openIn = OpenIn.tab
    /// `new-window-fullscreen`: a new window opened from a full-screen one goes to full screen too (`NewWindowFullScreen`).
    public var newWindowFullScreen = NewWindowFullScreen.follow
    /// `home-tab`: the source Home opens on (`HomeTab`).
    public var homeTab = HomeTab.recent
    /// `home-start`: Home's start page, where the toolbar's house and ⇧⌘H on Home go (`HomeTab`; `folders`: Places).
    public var homeStart = HomeTab.recent
    /// `home-sidebar`: Home's sidebar shown (⌃⌘S hides it and writes it back).
    public var homeSidebar = true
    /// `home-sidebar-width`: Home's sidebar width in points, 180...1600, shown at most a third of the window (never
    /// held under 400); dragging its edge writes it back.
    public var homeSidebarWidth = 236
    /// `home-sidebar-compact`: a folder holding one folder only shows with it on one row, `a › b › c`.
    public var homeSidebarCompact = true
    /// `home-sidebar-indent`: the sidebar tree's indent (`SidebarIndent`).
    public var homeSidebarIndent = SidebarIndent.compact
    /// `home-sidebar-folders-first`: the sidebar tree lists a folder's subfolders before its archives.
    public var homeSidebarFoldersFirst = true
    /// `home-sidebar-reroot`: the current folder this many levels under its place or deeper starts the sidebar tree
    /// again further down, under one row of the folders left out; 0 (the default) never, else 3...20.
    public var homeSidebarReroot = 0
    /// `browser-card-size`: the wanted photo slot width in the file browser (Home's Folders tab) in points, 60...480.
    public var browserCardSize = 220
    /// `grid-style`: each photo filling its square, cropped, or whole inside it (the default).
    public var gridStyle = GridStyle.aspect
    /// `grid-names`: file names off (the default), on the photo, or under it.
    public var gridNames = GridNames.off
    /// `folder-cover`: the layout of a folder's, a zip's or a session's card picture (`FolderCoverLayout`).
    public var folderCover = FolderCoverLayout.hero
    /// `recent-count`: how many recent folders Home shows, 0...200 (0: no Recent section).
    public var recentCount = 24
    /// `session-restore`: Home or Last Session at a launch without a file (`SessionRestore`).
    public var sessionRestore = SessionRestore.none

    /// `transparency`: what shows through a photo's transparent pixels (`TransparencySettings`, M3b spec §3).
    public var transparency = TransparencyMode.checker
    public static let checkerSizeRange = 2...64
    /// `checker-size`: the checkerboard's cell side in points, 2...64, the same on screen at every zoom.
    public var checkerSize = 8
    /// `checker-colors`: the checkerboard's cells.
    public var checkerColors = CheckerColors.light

    /// `upscale` / `downscale`: the resampling filter when the picture is magnified / reduced on screen (`metalfx` and
    /// `ewa-lanczos` only magnify, so they are `upscale` / `upscale-high` values and a warning as `downscale`).
    public var upscale = ResampleSettings().upscale
    /// `upscale-high` / `upscale-high-from`: the filter from that magnification (percent) up; 0 is off.
    public var upscaleHigh = ResampleSettings().upscaleHigh
    public var upscaleHighPercent = ResampleSettings().upscaleHighPercent
    public var downscale = ResampleSettings().downscale

    /// `lanczos-antiring`: clamp Lanczos upscaling to the range of its neighbourhood (less ringing, a bit softer).
    public var lanczosAntiring = false

    /// `pixel-art`: zoom in percent from which the picture is drawn nearest-neighbour; 0 is off.
    public var pixelArtPercent = 400

    /// `pyramid-filter`: how the pyramid levels are built; photos uploaded after a change get it. Lanczos-3 by spec §4's
    /// rule: +7 ms of GPU per 147 MP upload, +1.2 to +7 dB at Fit through level >= 1 (docs/bench/2026-10-15-m3a-pyramid.md).
    public var pyramidFilter = PyramidFilter.lanczos3

    /// `exif-orientation`: photos are shown turned and mirrored by their EXIF orientation (`no`: as stored, for every
    /// photo; applies on config reload without reopening the photo).
    public var exifOrientation = true

    // Automatic colour and vibrance (M3c spec §2.4); `ColorSettings(config:)` is what the picture reads.
    /// `auto-color`: each photo is corrected by Apple's automatic adjustments, by how much it needs them.
    public var autoColor = false
    /// `auto-color-method`: `apple` (the chain as it is) or `apple-luma` (curve and shadows on luminance only).
    public var autoColorMethod = AutoColorMethod.apple
    /// `auto-color-strength`: 0...1, the share of the correction mixed into the picture (in linear light).
    public var autoColorStrength = 1.0
    /// `auto-color-filters`: which parts of Apple's chain are applied, at least one; written `curve,shadows,vibrance`.
    public var autoColorFilters = Set(AutoColorFilter.allCases)
    /// `auto-color-vibrance-gain`: 0...4, multiplies the vibrance Apple chose (the result is capped at 1).
    public var autoColorVibranceGain = 1.0
    /// `auto-color-threshold`: 0...255, mean difference below which a photo is left alone; 0 corrects every photo.
    public var autoColorThreshold = 6.0
    /// `auto-color-full`: 0...255, the difference from which a photo gets the whole strength (a line from the threshold;
    /// at or below the threshold every photo that needs it gets the whole strength).
    public var autoColorFull = 12.0
    /// `auto-color-fade`: milliseconds of the transition when a photo's correction appears, 0...2000 (0: at once).
    public var autoColorFadeMilliseconds = 150
    /// `vibrance`: `CIVibrance` on every photo, whatever auto colour does.
    public var vibrance = false
    /// `vibrance-amount`: `CIVibrance.inputAmount`, 0...1.
    public var vibranceAmount = 0.5

    /// `appearance`: light, dark or the system's windows and Home (`AppAppearance`).
    public var appearance = AppAppearance.system
    /// `app-icon`: which icon the Dock shows (see `AppIcon`).
    public var appIcon = AppIcon.bundle
    /// `stash-url`: the Stash server whose WebUI Loupe shows (Stash spec §2.1); nil (empty) = no Stash at all.
    public var stashURL: URL?
    /// `stash-api-key`: Stash's API key when it has a login (empty: none).
    public var stashAPIKey = ""
    /// `stash-path-map`: extra rules `stashPrefix=localPrefix;…` tried before the mounted shares (`StashPathRule.parse`).
    public var stashPathMap = ""
    /// `stash-title`: a gallery with no title of its own is named after its file (`file`), or that name without the
    /// archive extension and with spaces for underscores (`tidy`, default).
    public var stashTitleTidy = true

    public init() {}

    /// ~/.config/loupe; `LOUPE_CONFIG_DIR` (debug, for scripted runs) points elsewhere.
    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["LOUPE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/loupe", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("loupe.conf") }

    /// Every key loupe.conf understands, in file order.
    public static let keys = ["zoom-stops", "zoom-stop-haptics",
                              "zoom-animation", "zoom-rubber-band", "keep-zoom-position", "keep-zoom-as", "default-zoom-mode", "fit-upscale",
                              "rmb-zoom-speed", "rmb-zoom-inertia",
                              "rubber-band", "drag-inertia", "inertia-deceleration", "rmb-zoom-invert",
                              "pan-indicators", "pan-indicators-hide", "pan-indicators-fade",
                              "pan-indicators-on-switch",
                              "spread", "spread-shift", "spread-direction", "spread-landscape",
                              "thumb-wheel-zoom", "thumb-zoom-speed", "thumb-zoom-stops", "thumb-zoom-invert",
                              "cache-full", "cache-previews", "cache-far-previews", "cache-files", "cache-memory", "cache-idle-trim", "cache-idle-keep",
                              "jxl-threads-current", "jxl-threads-other", "jxl-dc-preview",
                              "show-blurry",
                              "wheel-step", "key-step", "wheel-direction", "cursor-autohide", "launch-reveal", "open-in",
                              "new-window-fullscreen", "background",
                              "transparency", "checker-size", "checker-colors",
                              "upscale", "upscale-high", "upscale-high-from", "downscale", "lanczos-antiring", "pixel-art",
                              "pyramid-filter", "exif-orientation",
                              "auto-color", "auto-color-method", "auto-color-strength", "auto-color-filters",
                              "auto-color-vibrance-gain", "auto-color-threshold", "auto-color-full", "auto-color-fade",
                              "vibrance", "vibrance-amount",
                              "strip-window", "strip-height", "strip-cell-max", "strip-corner-radius", "strip-scroll-direction",
                              "strip-hide-delay", "strip-fade-in", "strip-fade-out",
                              "strip-jump-preview", "strip-loading-indicator",
                              "thumb-size", "thumb-cache-size", "folder-poll", "folder-view-memory",
                              "folder-scroll-gesture", "folder-scroll-direction", "folder-scroll-threshold", "folder-scroll-repeat",
                              "archive-folders", "folder-toast",
                              "mouse-long-press", "mouse-move-step", "mouse-haptics",
                              "mx-panel-force", "mx-side-buttons", "haptic-strength", "haptic-strong-strength",
                              "haptic-zoom-stop", "haptic-limit", "haptic-step", "haptic-toggle", "haptic-end",
                              "haptic-long-armed", "haptic-detent",
                              "stash-url", "stash-api-key", "stash-path-map", "stash-title",
                              "appearance", "home-tab", "home-start", "home-sidebar", "home-sidebar-width", "home-sidebar-compact", "home-sidebar-indent", "home-sidebar-folders-first", "home-sidebar-reroot", "browser-card-size", "grid-style", "grid-names", "folder-cover", "recent-count", "session-restore", "config-warnings", "toast-duration",
                              "stats-progress", "stats-progress-opacity", "stats-folder-name",
                              "app-icon"]

    /// The scaling filters a folder may set for itself. `pixel-art` and `pyramid-filter` stay global.
    public static let scalingFolderKeys = ["downscale", "upscale", "upscale-high", "lanczos-antiring"]
    /// The colour keys a folder may set for itself (M3c spec §2.4); the filters, gain, threshold, ramp and fade stay global.
    public static let colorFolderKeys = ["auto-color", "auto-color-method", "auto-color-strength", "vibrance",
                                         "vibrance-amount"]
    /// The zoom keys a folder may set for itself (M4b spec §4.1); `fit-upscale` stays global.
    public static let zoomFolderKeys = ["keep-zoom-position", "keep-zoom-as", "default-zoom-mode"]
    /// The two-page keys a folder sets for itself.
    public static let spreadFolderKeys = ["spread", "spread-shift", "spread-direction", "spread-landscape"]
    /// The keys a folder may set for itself.
    public static let folderKeys = scalingFolderKeys + colorFolderKeys + zoomFolderKeys + spreadFolderKeys

    /// This config with a folder's saved `key: text` values on top (only `folderKeys`). `rejected` lists
    /// `key=value` for every entry that is no folder key or whose value `set` refuses, sorted by key; those
    /// entries are skipped.
    public func applying(_ values: [String: String]) -> (config: Config, rejected: [String]) {
        var config = self
        var rejected: [String] = []
        for key in values.keys.sorted() {
            let value = values[key]!
            if !Self.folderKeys.contains(key) || config.set(key, value) != .ok { rejected.append("\(key)=\(value)") }
        }
        return (config, rejected)
    }

    public func hasZoomStop(_ stop: ZoomStop) -> Bool { zoomStops.contains(stop) }

    /// Menu checkbox: removes every token for `stop`, or appends one. Other tokens (hand-added
    /// percentages, unknown ones) stay where they are. From the defaults fallback, the defaults are
    /// written out first, so the toggle changes what is in effect.
    public mutating func toggleZoomStop(_ stop: ZoomStop) {
        var tokens = zoomStopTokens
        if Self.resolve(tokens).isFallback { tokens += Self.defaultZoomStops.map(Self.text(of:)) }
        if tokens.contains(where: { Self.zoomStop($0) == stop }) {
            tokens.removeAll { Self.zoomStop($0) == stop }
        } else {
            tokens.append(Self.text(of: stop))
        }
        zoomStopTokens = tokens
    }

    /// The value of `key` as it is written in the file.
    public func text(forKey key: String) -> String? {
        switch key {
        case "zoom-stops": return zoomStopTokens.isEmpty ? "none" : zoomStopTokens.joined(separator: ",")
        case "zoom-stop-haptics": return zoomStopHaptics ? "yes" : "no"
        case "zoom-animation": return String(zoomAnimationMilliseconds)
        case "zoom-rubber-band": return zoomRubberBand ? "yes" : "no"
        case "keep-zoom-position": return keepZoomPosition ? "yes" : "no"
        case "keep-zoom-as": return keepZoomAs.rawValue
        case "default-zoom-mode": return ZoomRules.text(of: defaultZoomMode)
        case "fit-upscale": return fitUpscale ? "yes" : "no"
        case "pan-indicators": return panIndicators.rawValue
        case "pan-indicators-hide": return String(panIndicatorsHideMilliseconds)
        case "pan-indicators-fade": return String(panIndicatorsFadeMilliseconds)
        case "pan-indicators-on-switch": return panIndicatorsOnSwitch ? "yes" : "no"
        case "spread": return spread ? "yes" : "no"
        case "spread-shift": return spreadShift ? "yes" : "no"
        case "spread-direction": return spreadRightToLeft ? "rtl" : "ltr"
        case "spread-landscape": return spreadLandscapeAlone ? "alone" : "pair"
        case "toast-duration": return String(toastDurationMilliseconds)
        case "mouse-long-press": return String(mouseLongPressMilliseconds)
        case "mouse-move-step": return formatNumber(mouseMoveStep)
        case "mouse-haptics": return mouseHaptics ? "yes" : "no"
        case "haptic-zoom-stop": return HapticChoice.text(hapticZoomStop)
        case "haptic-limit": return HapticChoice.text(hapticLimit)
        case "haptic-step": return HapticChoice.text(hapticStep)
        case "haptic-toggle": return HapticChoice.text(hapticToggle)
        case "haptic-end": return HapticChoice.text(hapticEnd)
        case "haptic-long-armed": return HapticChoice.text(hapticLongArmed)
        case "haptic-detent": return HapticChoice.text(hapticDetent)
        case "mx-panel-force": return mxPanelForce.text
        case "mx-side-buttons": return mxSideButtons.rawValue
        case "haptic-strength": return hapticStrength.map(String.init) ?? "keep"
        case "haptic-strong-strength": return String(hapticStrongStrength)
        case "rmb-zoom-speed": return formatNumber(rmbZoomSpeed)
        case "rmb-zoom-inertia": return rmbZoomInertia ? "yes" : "no"
        case "thumb-wheel-zoom": return thumbWheelZoom ? "yes" : "no"
        case "thumb-zoom-speed": return formatNumber(thumbZoomSpeed)
        case "thumb-zoom-stops": return thumbZoomStops.rawValue
        case "thumb-zoom-invert": return thumbZoomInvert ? "yes" : "no"
        case "rubber-band": return rubberBand ? "yes" : "no"
        case "drag-inertia": return dragInertia ? "yes" : "no"
        case "inertia-deceleration": return formatNumber(inertiaDeceleration)
        case "rmb-zoom-invert": return rmbZoomInvert ? "yes" : "no"
        case "cache-full": return String(cacheFull)
        case "cache-previews": return String(cachePreviews)
        case "cache-far-previews": return cacheFarPreviewsCoarse ? "coarse" : "full"
        case "cache-files": return String(cacheFiles)
        case "cache-memory": return Self.memoryText(cacheMemory)
        case "cache-idle-trim": return String(cacheIdleTrimMinutes)
        case "cache-idle-keep": return cacheIdleKeep.rawValue
        case "show-blurry": return showBlurry.rawValue
        case "jxl-threads-current": return String(jxlThreadsCurrent)
        case "jxl-threads-other": return String(jxlThreadsOther)
        case "jxl-dc-preview": return jxlDCPreview ? "yes" : "no"
        case "wheel-step": return wheelStep.rawValue
        case "wheel-direction": return wheelDirection.rawValue
        case "key-step": return keyStep.rawValue
        case "cursor-autohide": return cursorAutohideMilliseconds.map(String.init) ?? "no"
        case "strip-window": return stripWindow.rawValue
        case "strip-height": return String(stripHeight)
        case "strip-cell-max": return formatNumber(stripCellMax)
        case "strip-corner-radius": return formatNumber(stripCornerRadius)
        case "strip-scroll-direction": return stripScrollDirection.rawValue
        case "strip-hide-delay": return String(stripHideDelayMilliseconds)
        case "strip-fade-in": return String(stripFadeInMilliseconds)
        case "strip-fade-out": return String(stripFadeOutMilliseconds)
        case "strip-jump-preview": return stripJumpPreview ? "yes" : "no"
        case "strip-loading-indicator": return stripLoadingIndicator ? "yes" : "no"
        case "thumb-size": return String(thumbSize)
        case "thumb-cache-size": return Self.memoryText(thumbCacheBytes)
        case "folder-poll": return String(folderPollMilliseconds)
        case "folder-view-memory": return folderViewMemory.text
        case "folder-scroll-gesture": return folderScrollGesture ? "yes" : "no"
        case "folder-scroll-direction": return folderScrollDirection.rawValue
        case "folder-scroll-threshold": return formatNumber(folderScrollThreshold)
        case "folder-scroll-repeat": return String(folderScrollRepeatMilliseconds)
        case "archive-folders": return archiveFolders ? "yes" : "no"
        case "folder-toast": return folderToast ? "yes" : "no"
        case "config-warnings": return configWarnings ? "yes" : "no"
        case "stats-progress": return statsProgress ? "yes" : "no"
        case "stats-progress-opacity": return formatNumber(statsProgressOpacity)
        case "stats-folder-name": return statsFolderName ? "yes" : "no"
        case "background": return background.text
        case "launch-reveal": return launchReveal.rawValue
        case "open-in": return openIn.rawValue
        case "new-window-fullscreen": return newWindowFullScreen.rawValue
        case "home-tab": return homeTab.rawValue
        case "home-start": return homeStart.rawValue
        case "home-sidebar": return homeSidebar ? "yes" : "no"
        case "home-sidebar-width": return String(homeSidebarWidth)
        case "home-sidebar-compact": return homeSidebarCompact ? "yes" : "no"
        case "home-sidebar-indent": return homeSidebarIndent.rawValue
        case "home-sidebar-folders-first": return homeSidebarFoldersFirst ? "yes" : "no"
        case "home-sidebar-reroot": return String(homeSidebarReroot)
        case "browser-card-size": return String(browserCardSize)
        case "grid-style": return gridStyle.rawValue
        case "grid-names": return gridNames.rawValue
        case "folder-cover": return folderCover.rawValue
        case "recent-count": return String(recentCount)
        case "session-restore": return sessionRestore.rawValue
        case "transparency": return transparency.rawValue
        case "checker-size": return String(checkerSize)
        case "checker-colors": return checkerColors.text
        case "upscale": return upscale.text
        case "upscale-high": return upscaleHigh.text
        case "upscale-high-from": return String(upscaleHighPercent)
        case "downscale": return downscale.text
        case "lanczos-antiring": return lanczosAntiring ? "yes" : "no"
        case "pixel-art": return String(pixelArtPercent)
        case "pyramid-filter": return pyramidFilter.rawValue
        case "exif-orientation": return exifOrientation ? "yes" : "no"
        case "auto-color": return autoColor ? "yes" : "no"
        case "auto-color-method": return autoColorMethod.rawValue
        case "auto-color-strength": return formatNumber(autoColorStrength)
        case "auto-color-filters":
            return AutoColorFilter.allCases.filter(autoColorFilters.contains).map(\.rawValue).joined(separator: ",")
        case "auto-color-vibrance-gain": return formatNumber(autoColorVibranceGain)
        case "auto-color-threshold": return formatNumber(autoColorThreshold)
        case "auto-color-full": return formatNumber(autoColorFull)
        case "auto-color-fade": return String(autoColorFadeMilliseconds)
        case "vibrance": return vibrance ? "yes" : "no"
        case "vibrance-amount": return formatNumber(vibranceAmount)
        case "appearance": return appearance.rawValue
        case "app-icon": return appIcon
        case "stash-url": return stashURL?.absoluteString ?? ""
        case "stash-api-key": return stashAPIKey
        case "stash-path-map": return stashPathMap
        case "stash-title": return stashTitleTidy ? "tidy" : "file"
        default: return nil
        }
    }

    /// Writes only `keys` into the file at `url`, keeping everything else in it, and creates the
    /// directory if needed.
    public func write(keys: [String], to url: URL = Config.fileURL) throws {
        // Only a missing file starts empty; any other read failure must not clobber the file.
        let existing = FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8) : ""
        let values = keys.compactMap { key in text(forKey: key).map { (key: key, value: $0) } }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConfigText.setting(values, in: existing).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Defaults when the file is missing (not an error); a file that exists but cannot be read is reported.
    public static func load(from url: URL = Config.fileURL) -> (Config, [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (Config(), []) }
        do {
            return parse(try String(contentsOf: url, encoding: .utf8))
        } catch {
            return (Config(), ["\(url.path): \(error.localizedDescription)"])
        }
    }

    /// Applies one `key=value` setting, as the file or a folder's saved text gives it; the same checks as a line in
    /// loupe.conf. A refused value or an unknown key leaves the config as it was. `zoom-stops` always takes: `parse`
    /// reports its unknown tokens itself.
    public mutating func set(_ key: String, _ value: String) -> SetResult {
        switch key {
        case "zoom-stops":
            zoomStopTokens = Self.zoomStopTokens(value)
        case "zoom-stop-haptics":
            if let v = Self.bool(value) { zoomStopHaptics = v } else { return .badValue }
        case "zoom-animation":
            if let v = Int(value) {
                guard (0...1000).contains(v) else { return .badValue }
                zoomAnimationMilliseconds = v
            } else if let on = Self.bool(value) {
                zoomAnimationMilliseconds = on ? Self.defaultZoomAnimationMilliseconds : 0
            } else { return .badValue }
        case "zoom-rubber-band":
            if let v = Self.bool(value) { zoomRubberBand = v } else { return .badValue }
        case "keep-zoom-position":
            if let v = Self.bool(value) { keepZoomPosition = v } else { return .badValue }
        case "keep-zoom-as":
            if let v = ZoomCarry(rawValue: value.lowercased()) { keepZoomAs = v } else { return .badValue }
        case "default-zoom-mode":
            if let v = ZoomRules.parseMode(value) { defaultZoomMode = v } else { return .badValue }
        case "fit-upscale":
            if let v = Self.bool(value) { fitUpscale = v } else { return .badValue }
        case "pan-indicators":
            if let v = PanIndicatorMode(rawValue: value.lowercased()) { panIndicators = v } else { return .badValue }
        case "pan-indicators-hide":
            if let v = Int(value), (0...5000).contains(v) { panIndicatorsHideMilliseconds = v } else { return .badValue }
        case "pan-indicators-fade":
            if let v = Int(value), (0...2000).contains(v) { panIndicatorsFadeMilliseconds = v } else { return .badValue }
        case "pan-indicators-on-switch":
            if let v = Self.bool(value) { panIndicatorsOnSwitch = v } else { return .badValue }
        case "spread":
            if let v = Self.bool(value) { spread = v } else { return .badValue }
        case "spread-shift":
            if let v = Self.bool(value) { spreadShift = v } else { return .badValue }
        case "spread-direction":
            switch value.lowercased() {
            case "ltr": spreadRightToLeft = false
            case "rtl": spreadRightToLeft = true
            default: return .badValue
            }
        case "spread-landscape":
            switch value.lowercased() {
            case "alone": spreadLandscapeAlone = true
            case "pair": spreadLandscapeAlone = false
            default: return .badValue
            }
        case "toast-duration":
            if let v = Int(value), (500...10_000).contains(v) { toastDurationMilliseconds = v } else { return .badValue }
        case "mouse-long-press":
            if let v = Int(value), (150...2000).contains(v) { mouseLongPressMilliseconds = v } else { return .badValue }
        case "mouse-move-step":
            if let v = Double(value), (4...200).contains(v) { mouseMoveStep = v } else { return .badValue }
        case "mouse-haptics":
            if let v = Self.bool(value) { mouseHaptics = v } else { return .badValue }
        case "haptic-zoom-stop":
            if let v = HapticChoice.parse(value) { hapticZoomStop = v } else { return .badValue }
        case "haptic-limit":
            if let v = HapticChoice.parse(value) { hapticLimit = v } else { return .badValue }
        case "haptic-step":
            if let v = HapticChoice.parse(value) { hapticStep = v } else { return .badValue }
        case "haptic-toggle":
            if let v = HapticChoice.parse(value) { hapticToggle = v } else { return .badValue }
        case "haptic-end":
            if let v = HapticChoice.parse(value) { hapticEnd = v } else { return .badValue }
        case "haptic-long-armed":
            if let v = HapticChoice.parse(value) { hapticLongArmed = v } else { return .badValue }
        case "haptic-detent":
            if let v = HapticChoice.parse(value) { hapticDetent = v } else { return .badValue }
        case "mx-panel-force":
            if let v = PanelForceSetting.parse(value) { mxPanelForce = v } else { return .badValue }
        case "mx-side-buttons":
            if let v = SideButtonsMode(rawValue: value.lowercased()) { mxSideButtons = v } else { return .badValue }
        case "haptic-strength":
            if value.lowercased() == "keep" {
                hapticStrength = nil
            } else if let v = Int(value), (0...100).contains(v) {
                hapticStrength = v
            } else {
                return .badValue
            }
        case "haptic-strong-strength":
            if let v = Int(value), (0...100).contains(v) { hapticStrongStrength = v } else { return .badValue }
        case "rmb-zoom-speed":
            if let v = Double(value), (0.25...5).contains(v) { rmbZoomSpeed = v } else { return .badValue }
        case "rmb-zoom-inertia":
            if let v = Self.bool(value) { rmbZoomInertia = v } else { return .badValue }
        case "thumb-wheel-zoom":
            if let v = Self.bool(value) { thumbWheelZoom = v } else { return .badValue }
        case "thumb-zoom-speed":
            if let v = Double(value), (0.25...8).contains(v) { thumbZoomSpeed = v } else { return .badValue }
        case "thumb-zoom-stops":
            if let v = ThumbZoomStops(rawValue: value.lowercased()) { thumbZoomStops = v } else { return .badValue }
        case "thumb-zoom-invert":
            if let v = Self.bool(value) { thumbZoomInvert = v } else { return .badValue }
        case "rubber-band":
            if let v = Self.bool(value) { rubberBand = v } else { return .badValue }
        case "drag-inertia":
            if let v = Self.bool(value) { dragInertia = v } else { return .badValue }
        case "inertia-deceleration":
            if let v = Double(value), (0.99...0.999).contains(v) { inertiaDeceleration = v } else { return .badValue }
        case "rmb-zoom-invert":
            if let v = Self.bool(value) { rmbZoomInvert = v } else { return .badValue }
        case "cache-full":
            if let v = Int(value), (0...2).contains(v) { cacheFull = v } else { return .badValue }
        case "cache-previews":
            if let v = Int(value), (1...200).contains(v) { cachePreviews = v } else { return .badValue }
        case "cache-far-previews":
            switch value.lowercased() {
            case "coarse": cacheFarPreviewsCoarse = true
            case "full": cacheFarPreviewsCoarse = false
            default: return .badValue
            }
        case "cache-files":
            if let v = Int(value), (0...50).contains(v) { cacheFiles = v } else { return .badValue }
        case "cache-memory":
            if let v = Self.memoryBytes(value) { cacheMemory = v } else { return .badValue }
        case "cache-idle-trim":
            if let v = Int(value), (0...1440).contains(v) { cacheIdleTrimMinutes = v } else { return .badValue }
        case "cache-idle-keep":
            if let v = CacheIdleKeep(rawValue: value.lowercased()) { cacheIdleKeep = v } else { return .badValue }
        case "show-blurry":
            if let v = ShowBlurry(rawValue: value.lowercased()) { showBlurry = v } else { return .badValue }
        case "jxl-threads-current":
            if let v = Int(value), (1...16).contains(v) { jxlThreadsCurrent = v } else { return .badValue }
        case "jxl-threads-other":
            if let v = Int(value), (1...16).contains(v) { jxlThreadsOther = v } else { return .badValue }
        case "jxl-dc-preview":
            if let v = Self.bool(value) { jxlDCPreview = v } else { return .badValue }
        case "wheel-step":
            if let v = StepWait(text: value) { wheelStep = v } else { return .badValue }
        case "wheel-direction":
            if let v = WheelDirection(text: value) { wheelDirection = v } else { return .badValue }
        case "key-step":
            if let v = StepWait(text: value) { keyStep = v } else { return .badValue }
        case "cursor-autohide":
            if Self.bool(value) == false { cursorAutohideMilliseconds = nil }
            else if let v = Int(value), (1...600_000).contains(v) { cursorAutohideMilliseconds = v }
            else { return .badValue }
        case "strip-window":
            let word = value.lowercased()
            if let v = StripWindowMode(rawValue: Self.renamedValues["strip-window"]?[word] ?? word) { stripWindow = v } else { return .badValue }
        case "strip-height":
            if let v = Int(value), Self.stripHeightRange.contains(v) { stripHeight = v } else { return .badValue }
        case "strip-cell-max":
            if let v = Self.aspect(value), Self.stripCellMaxRange.contains(v) { stripCellMax = v } else { return .badValue }
        case "strip-corner-radius":
            if let v = Double(value), (0...16).contains(v) { stripCornerRadius = v } else { return .badValue }
        case "strip-scroll-direction":
            if let v = StripScrollDirection(rawValue: value.lowercased()) { stripScrollDirection = v }
            else { return .badValue }
        case "strip-hide-delay":
            if let v = Int(value), (0...10_000).contains(v) { stripHideDelayMilliseconds = v } else { return .badValue }
        case "strip-fade-in":
            if let v = Int(value), (0...2000).contains(v) { stripFadeInMilliseconds = v } else { return .badValue }
        case "strip-fade-out":
            if let v = Int(value), (0...2000).contains(v) { stripFadeOutMilliseconds = v } else { return .badValue }
        case "strip-jump-preview":
            if let v = Self.bool(value) { stripJumpPreview = v } else { return .badValue }
        case "strip-loading-indicator":
            if let v = Self.bool(value) { stripLoadingIndicator = v } else { return .badValue }
        case "thumb-size":
            if let v = Int(value), (256...1024).contains(v) { thumbSize = v } else { return .badValue }
        case "thumb-cache-size":
            // `0` is valid here (memory only), which `memoryBytes` rejects for cache-memory.
            if let v = Int(value), v == 0 { thumbCacheBytes = 0 }
            else if let v = Self.memoryBytes(value) { thumbCacheBytes = v }
            else { return .badValue }
        case "folder-poll":
            if let v = Int(value), v == 0 || (500...60_000).contains(v) { folderPollMilliseconds = v } else { return .badValue }
        case "folder-view-memory":
            if let v = FolderViewMemory(text: value) { folderViewMemory = v } else { return .badValue }
        case "folder-scroll-gesture":
            if let v = Self.bool(value) { folderScrollGesture = v } else { return .badValue }
        case "folder-scroll-direction":
            if let v = FolderScrollDirection(rawValue: value.lowercased()) { folderScrollDirection = v }
            else { return .badValue }
        case "folder-scroll-threshold":
            if let v = Double(value), Self.folderScrollThresholdRange.contains(v) { folderScrollThreshold = v }
            else { return .badValue }
        case "folder-scroll-repeat":
            if let v = Int(value), v == 0 || (100...2000).contains(v) { folderScrollRepeatMilliseconds = v }
            else { return .badValue }
        case "archive-folders":
            if let v = Self.bool(value) { archiveFolders = v } else { return .badValue }
        case "folder-toast":
            if let v = Self.bool(value) { folderToast = v } else { return .badValue }
        case "config-warnings":
            if let v = Self.bool(value) { configWarnings = v } else { return .badValue }
        case "stats-progress":
            if let v = Self.bool(value) { statsProgress = v } else { return .badValue }
        case "stats-progress-opacity":
            if let v = Double(value), (0.02...0.6).contains(v) { statsProgressOpacity = v } else { return .badValue }
        case "stats-folder-name":
            if let v = Self.bool(value) { statsFolderName = v } else { return .badValue }
        case "background":
            if let v = BackgroundColor(text: value) { background = v } else { return .badValue }
        case "launch-reveal":
            if let v = LaunchReveal(rawValue: value.lowercased()) { launchReveal = v } else { return .badValue }
        case "open-in":
            if let v = OpenIn(rawValue: value.lowercased()) { openIn = v } else { return .badValue }
        case "new-window-fullscreen":
            if let v = NewWindowFullScreen(rawValue: value.lowercased()) { newWindowFullScreen = v } else { return .badValue }
        case "home-tab":
            if let v = HomeTab(rawValue: value.lowercased()) { homeTab = v } else { return .badValue }
        case "home-start":
            if let v = HomeTab(rawValue: value.lowercased()) { homeStart = v } else { return .badValue }
        case "home-sidebar":
            if let v = Self.bool(value) { homeSidebar = v } else { return .badValue }
        case "home-sidebar-width":
            if let v = Int(value), (180...1600).contains(v) { homeSidebarWidth = v } else { return .badValue }
        case "home-sidebar-compact":
            if let v = Self.bool(value) { homeSidebarCompact = v } else { return .badValue }
        case "home-sidebar-indent":
            if let v = SidebarIndent(rawValue: value.lowercased()) { homeSidebarIndent = v } else { return .badValue }
        case "home-sidebar-folders-first":
            if let v = Self.bool(value) { homeSidebarFoldersFirst = v } else { return .badValue }
        case "home-sidebar-reroot":
            if let v = Int(value), v == 0 || (3...20).contains(v) { homeSidebarReroot = v } else { return .badValue }
        case "browser-card-size":
            if let v = Int(value), (60...480).contains(v) { browserCardSize = v } else { return .badValue }
        case "grid-style":
            if let v = GridStyle(rawValue: value.lowercased()) { gridStyle = v } else { return .badValue }
        case "grid-names":
            if let v = GridNames(rawValue: value.lowercased()) { gridNames = v } else { return .badValue }
        case "folder-cover":
            if let v = FolderCoverLayout(rawValue: value.lowercased()) { folderCover = v } else { return .badValue }
        case "recent-count":
            if let v = Int(value), (0...200).contains(v) { recentCount = v } else { return .badValue }
        case "session-restore":
            if let v = SessionRestore(rawValue: value.lowercased()) { sessionRestore = v } else { return .badValue }
        case "transparency":
            if let v = TransparencyMode(text: value) { transparency = v } else { return .badValue }
        case "checker-size":
            if let v = Int(value), Self.checkerSizeRange.contains(v) { checkerSize = v } else { return .badValue }
        case "checker-colors":
            if let v = CheckerColors(text: value) { checkerColors = v } else { return .badValue }
        case "upscale":
            if let v = UpscaleFilter(text: value) { upscale = v } else { return .badValue }
        case "upscale-high":
            if let v = UpscaleFilter(text: value) { upscaleHigh = v } else { return .badValue }
        case "upscale-high-from":
            if let v = Int(value), v == 0 || (100...6400).contains(v) { upscaleHighPercent = v } else { return .badValue }
        case "downscale":
            if let v = DownscaleFilter(text: value) { downscale = v } else { return .badValue }
        case "lanczos-antiring":
            if let v = Self.bool(value) { lanczosAntiring = v } else { return .badValue }
        case "pixel-art":
            if let v = Int(value), v == 0 || (100...6400).contains(v) { pixelArtPercent = v } else { return .badValue }
        case "pyramid-filter":
            if let v = PyramidFilter(text: value) { pyramidFilter = v } else { return .badValue }
        case "exif-orientation":
            if let v = Self.bool(value) { exifOrientation = v } else { return .badValue }
        case "auto-color":
            if let v = Self.bool(value) { autoColor = v } else { return .badValue }
        case "auto-color-method":
            if let v = AutoColorMethod(rawValue: value.lowercased()) { autoColorMethod = v } else { return .badValue }
        case "auto-color-strength":
            if let v = Double(value), (0...1).contains(v) { autoColorStrength = v } else { return .badValue }
        case "auto-color-filters":
            if let v = Self.autoColorFilters(value) { autoColorFilters = v } else { return .badValue }
        case "auto-color-vibrance-gain":
            if let v = Double(value), (0...4).contains(v) { autoColorVibranceGain = v } else { return .badValue }
        case "auto-color-threshold":
            if let v = Double(value), (0...255).contains(v) { autoColorThreshold = v } else { return .badValue }
        case "auto-color-full":
            if let v = Double(value), (0...255).contains(v) { autoColorFull = v } else { return .badValue }
        case "auto-color-fade":
            if let v = Int(value), (0...2000).contains(v) { autoColorFadeMilliseconds = v } else { return .badValue }
        case "vibrance":
            if let v = Self.bool(value) { vibrance = v } else { return .badValue }
        case "vibrance-amount":
            if let v = Double(value), (0...1).contains(v) { vibranceAmount = v } else { return .badValue }
        case "appearance":
            if let v = AppAppearance(rawValue: value.lowercased()) { appearance = v } else { return .badValue }
        case "app-icon":
            if let v = AppIcon.normalized(value) { appIcon = v } else { return .badValue }
        case "stash-url":
            if value.isEmpty {
                stashURL = nil
            } else if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host?.isEmpty == false {
                stashURL = url
            } else {
                return .badValue
            }
        case "stash-api-key": stashAPIKey = value
        case "stash-path-map": stashPathMap = value
        case "stash-title":
            switch value {
            case "tidy": stashTitleTidy = true
            case "file": stashTitleTidy = false
            default: return .badValue
            }
        default:
            return .unknownKey
        }
        return .ok
    }

    /// Parses config text. Lines with unknown keys or invalid values are ignored and reported; so are
    /// unknown `zoom-stops` tokens, while the rest of that list is kept.
    public static func parse(_ text: String) -> (Config, [String]) {
        var config = Config()
        var warnings: [String] = []
        for (number, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = stripComment(raw)
            guard !line.isEmpty else { continue }
            let location = "loupe.conf:\(number + 1)"
            guard let equals = line.firstIndex(of: "=") else {
                warnings.append("\(location): expected key=value")
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if retiredKeys.contains(key) {
                warnings.append("\(location): '\(key)' is no longer used")
                continue
            }
            let bad = "\(location): bad option '\(key)=\(value)'"
            switch config.set(key, value) {
            case .ok:
                if let new = renamedValues[key]?[value.lowercased()] {
                    warnings.append("\(location): '\(key)=\(value.lowercased())' is now '\(key)=\(new)'")
                }
                if key == "zoom-stops" {
                    let resolved = resolve(config.zoomStopTokens)
                    warnings += resolved.unknown.map { "\(location): unknown zoom stop '\($0)'" }
                    if resolved.isFallback { warnings.append("\(location): no known zoom stops, using the defaults") }
                }
            case .badValue, .unknownKey:
                warnings.append(bad)
            }
        }
        return (config, warnings)
    }

    /// `fit-width, fit-height,100%` → its trimmed tokens; empty or `none` is no tokens (no stops).
    private static func zoomStopTokens(_ value: String) -> [String] {
        let tokens = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return tokens.map { $0.lowercased() } == ["none"] ? [] : tokens
    }

    /// The stops `tokens` stand for. Tokens but none known (`isFallback`) means the defaults.
    private static func resolve(_ tokens: [String]) -> (stops: [ZoomStop], unknown: [String], isFallback: Bool) {
        var stops: [ZoomStop] = [], unknown: [String] = []
        for token in tokens {
            if let stop = zoomStop(token) { stops.append(stop) } else { unknown.append(token) }
        }
        if stops.isEmpty && !tokens.isEmpty { return (defaultZoomStops, unknown, true) }
        return (stops, unknown, false)
    }

    private static func zoomStop(_ token: String) -> ZoomStop? {
        switch token.lowercased() {
        case "fit-width": return .fitWidth
        case "fit-height": return .fitHeight
        default:
            guard token.hasSuffix("%"),
                  let p = Double(token.dropLast().trimmingCharacters(in: .whitespaces)), p.isFinite, p > 0 else { return nil }
            return .percent(p)
        }
    }

    private static func text(of stop: ZoomStop) -> String {
        switch stop {
        case .fitWidth: return "fit-width"
        case .fitHeight: return "fit-height"
        case .percent(let p): return formatNumber(p) + "%"
        }
    }

    /// `curve, Shadows` → its parts; nil when the list is empty or has a name that is not a part.
    private static func autoColorFilters(_ value: String) -> Set<AutoColorFilter>? {
        let names = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let filters = names.compactMap(AutoColorFilter.init(rawValue:))
        return filters.count == names.count ? Set(filters) : nil
    }

    /// `512M`, `3G` (either case) or plain bytes → bytes; zero, negative, fractional or overflowing is nil.
    private static func memoryBytes(_ value: String) -> Int? {
        var digits = value.lowercased()
        var unit = 1
        if digits.hasSuffix("g") { unit = 1 << 30; digits.removeLast() }
        else if digits.hasSuffix("m") { unit = 1 << 20; digits.removeLast() }
        guard let n = Int(digits), n > 0 else { return nil }
        let (bytes, overflow) = n.multipliedReportingOverflow(by: unit)
        return overflow ? nil : bytes
    }

    /// The shortest exact spelling of a byte count, so a value read as `3G` is written back as `3G`
    /// (and `0` stays `0`).
    private static func memoryText(_ bytes: Int) -> String {
        if bytes == 0 { return "0" }
        if bytes % (1 << 30) == 0 { return "\(bytes >> 30)G" }
        if bytes % (1 << 20) == 0 { return "\(bytes >> 20)M" }
        return String(bytes)
    }

    /// Keys loupe.conf may still hold from earlier versions: each line gets one warning and its value is ignored.
    public static let retiredKeys: Set<String> = ["strip-aspect", "strip-magnify", "strip-magnify-reach",
                                                  "strip-magnify-limit"]

    /// Values loupe.conf may still hold from earlier versions, by key: old word to new word. `set` reads the old word,
    /// `parse` warns about it.
    public static let renamedValues: [String: [String: String]] = [
        "strip-window": ["overlay": "over", "bar": "beside", "off": "hidden"],
    ]

    /// `1.5` or `3:2` (both sides positive) → width / height; nil for anything else or a non-finite result.
    private static func aspect(_ value: String) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        let result: Double?
        switch parts.count {
        case 1: result = Double(value)
        case 2:
            guard let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let h = Double(parts[1].trimmingCharacters(in: .whitespaces)), w > 0, h > 0 else { return nil }
            result = w / h
        default: result = nil
        }
        guard let result, result.isFinite else { return nil }
        return result
    }

    private static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return nil
        }
    }
}
