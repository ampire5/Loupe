import Testing
import LogiHIDPP
import Foundation
@testable import LoupeCore

// MARK: Defaults and loading

@Test func configDefaults() {
    let c = Config()
    #expect(c.zoomStops == [.fitWidth, .fitHeight, .percent(100)])
    #expect(c.zoomStopHaptics)
    let (parsed, warnings) = Config.parse("")
    #expect(parsed == c && warnings.isEmpty)
}

@Test func missingFileGivesDefaultsWithoutWarningsAndIsNotCreated() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-config-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("loupe.conf")
    let (c, warnings) = Config.load(from: url)
    #expect(c == Config() && warnings.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

@Test func configFileLivesInDotConfigLoupe() {
    #expect(Config.fileURL.path.hasSuffix("/.config/loupe/loupe.conf"))
}

// MARK: Parsing

@Test func parsesZoomStopsAndHaptics() {
    let (c, warnings) = Config.parse("zoom-stops=fit-height, 200% ,fit-width\nzoom-stop-haptics=no\n")
    #expect(warnings.isEmpty)
    #expect(c.zoomStops == [.fitHeight, .percent(200), .fitWidth])
    #expect(!c.zoomStopHaptics)
}

@Test func missingKeysKeepTheirDefaults() {
    #expect(Config.parse("zoom-stop-haptics=no").0.zoomStops == Config().zoomStops)
    #expect(Config.parse("zoom-stops=50%").0.zoomStopHaptics)
}

@Test func parsesPercentStops() {
    #expect(Config.parse("zoom-stops=150%").0.zoomStops == [.percent(150)])
    #expect(Config.parse("zoom-stops=33.3%").0.zoomStops == [.percent(33.3)])
    #expect(Config.parse("zoom-stops=FIT-WIDTH,25 %").0.zoomStops == [.fitWidth, .percent(25)])
}

@Test func unknownZoomStopTokensAreIgnoredAndReported() {
    let (c, warnings) = Config.parse("zoom-stops=fit-width,bogus,50,0%,-5%,abc%,nan%,inf%,100%")
    #expect(c.zoomStops == [.fitWidth, .percent(100)])
    #expect(warnings.count == 7)
    #expect(warnings.first == "loupe.conf:1: unknown zoom stop 'bogus'")
}

@Test func emptyOrNoneZoomStopsMeansNoStops() {
    #expect(Config.parse("zoom-stops=").0.zoomStops.isEmpty)
    #expect(Config.parse("zoom-stops=none").0.zoomStops.isEmpty)
}

@Test func commentsAndBlankLinesAreSkipped() {
    let text = "# Loupe\n\n  # indented comment\nzoom-stops=100%  # just actual size\nzoom-stop-haptics=yes#not a comment\n"
    let (c, warnings) = Config.parse(text)
    #expect(c.zoomStops == [.percent(100)])
    // `#` not preceded by whitespace is part of the value, which then is not a valid yes/no.
    #expect(warnings == ["loupe.conf:5: bad option 'zoom-stop-haptics=yes#not a comment'"])
}

/// A `#` that begins the value is the value's, with or without spaces around `=`; a later ` #` is a comment.
@Test func hashThatBeginsTheValueIsNotAComment() {
    let grey = BackgroundColor(red: 0x33, green: 0x33, blue: 0x33)
    for line in ["background = #333", "background=#333", "background =   #333", "background\t=\t#333"] {
        let (c, warnings) = Config.parse(line)
        #expect(c.background == grey && warnings.isEmpty, "\(line)")
    }
    for line in ["background = #333 # dark", "background=#333  # dark", "background = #333\t# dark"] {
        let (c, warnings) = Config.parse(line)
        #expect(c.background == grey && warnings.isEmpty, "\(line)")
    }
    #expect(Config.parse("  # background = #333").0.background == .default)    // a commented-out line stays one
    // A `#` with nothing right after it is a comment after an empty value, as before.
    #expect(Config.parse("background = # note").1 == ["loupe.conf:1: bad option 'background='"])
    #expect(Config.parse("background=# note").1 == ["loupe.conf:1: bad option 'background='"])
    #expect(Config.parse("background = #").1 == ["loupe.conf:1: bad option 'background='"])
    #expect(Config.parse("zoom-stops = # none for now").0.zoomStops.isEmpty)
    #expect(ConfigText.setting([("background", "#444444")], in: "background = # note\n") == "background=#444444 # note\n")
    #expect(Config.parse("zoom-stops=100% # just actual size").0.zoomStops == [.percent(100)])
    // The menu rewrites such a line in place, keeping only the real comment.
    #expect(ConfigText.setting([("background", "#444444")], in: "background = #333 # dark\n")
            == "background=#444444 # dark\n")
    #expect(ConfigText.setting([("background", "#444444")], in: "background = #333\n") == "background=#444444\n")
}

@Test func unknownKeysAndBadLinesAreReported() {
    let (c, warnings) = Config.parse("zoom-speed=3\njust text\nzoom-stop-haptics=maybe")
    #expect(c == Config())
    #expect(warnings == ["loupe.conf:1: bad option 'zoom-speed=3'", "loupe.conf:2: expected key=value",
                         "loupe.conf:3: bad option 'zoom-stop-haptics=maybe'"])
}

// MARK: Writing

@Test func valuesAreWrittenInTheFileFormat() {
    var c = Config()
    #expect(c.text(forKey: "zoom-stops") == "fit-width,fit-height,100%")
    #expect(c.text(forKey: "zoom-stop-haptics") == "yes")
    c.zoomStops = [.percent(33.3), .percent(200)]
    #expect(c.text(forKey: "zoom-stops") == "33.3%,200%")
    c.zoomStops = []
    #expect(c.text(forKey: "zoom-stops") == "none")
    #expect(Config.parse("zoom-stops=none").0.zoomStops == c.zoomStops)
    #expect(c.text(forKey: "nope") == nil)
}

@Test func togglingAStopKeepsHandAddedOnes() {
    var c = Config.parse("zoom-stops=fit-width,50%,fit-height,100%,200%").0
    c.toggleZoomStop(.fitHeight)
    #expect(c.zoomStops == [.fitWidth, .percent(50), .percent(100), .percent(200)])
    c.toggleZoomStop(.percent(100))
    #expect(c.zoomStops == [.fitWidth, .percent(50), .percent(200)])
    c.toggleZoomStop(.fitHeight)
    #expect(c.zoomStops == [.fitWidth, .percent(50), .percent(200), .fitHeight])
    #expect(c.hasZoomStop(.fitHeight) && !c.hasZoomStop(.percent(100)))
}

@Test func editingRewritesTheLineInPlaceAndKeepsComments() {
    let text = """
    # my Loupe settings
    zoom-stop-haptics=yes   # buzz

    # stops I like
    zoom-stops=fit-width,fit-height,100%,200%  # with 200
    # zoom-stops=fit-width

    """
    var c = Config.parse(text).0
    c.toggleZoomStop(.fitHeight)
    c.zoomStopHaptics = false
    let edited = ConfigText.setting([("zoom-stops", c.text(forKey: "zoom-stops")!),
                                     ("zoom-stop-haptics", c.text(forKey: "zoom-stop-haptics")!)], in: text)
    #expect(edited == """
    # my Loupe settings
    zoom-stop-haptics=no # buzz

    # stops I like
    zoom-stops=fit-width,100%,200% # with 200
    # zoom-stops=fit-width

    """)
    #expect(Config.parse(edited).0 == c)
}

@Test func editingAppendsMissingKeysBeforeTheTrailingNewline() {
    let edited = ConfigText.setting([("zoom-stops", "100%")], in: "# hi\nzoom-stop-haptics=no\n")
    #expect(edited == "# hi\nzoom-stop-haptics=no\nzoom-stops=100%\n")
}

@Test func editingAnEmptyFileStartsWithAHeader() {
    let edited = ConfigText.setting([("zoom-stops", "100%")], in: "")
    #expect(edited == ConfigText.header + "\nzoom-stops=100%\n")
}

@Test func writeCreatesTheDirectoryAndKeepsTheRestOfTheFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("sub/loupe.conf")
    var c = Config()
    c.toggleZoomStop(.percent(100))
    try c.write(keys: ["zoom-stops"], to: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == ConfigText.header + "\nzoom-stops=fit-width,fit-height\n")

    try "# keep me\nzoom-stops=100%\n".write(to: url, atomically: true, encoding: .utf8)
    c.zoomStopHaptics = false
    try c.write(keys: ["zoom-stop-haptics"], to: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == "# keep me\nzoom-stops=100%\nzoom-stop-haptics=no\n")
    let (loaded, warnings) = Config.load(from: url)
    #expect(warnings.isEmpty && loaded.zoomStops == [.percent(100)] && !loaded.zoomStopHaptics)
}

// MARK: Fix round 1

@Test func editingRewritesTheLastOccurrenceBecauseThatIsTheOneThatCounts() {
    let text = "zoom-stops=fit-width\n# zoom-stops=50%\nzoom-stops=200%  # wins\n"
    #expect(Config.parse(text).0.zoomStops == [.percent(200)])
    let edited = ConfigText.setting([("zoom-stops", "100%")], in: text)
    #expect(edited == "zoom-stops=fit-width\n# zoom-stops=50%\nzoom-stops=100% # wins\n")
    #expect(Config.parse(edited).0.zoomStops == [.percent(100)])
}

@Test func aZoomStopListWithOnlyUnknownTokensFallsBackToTheDefaults() {
    let (c, warnings) = Config.parse("zoom-stops=fit_width, 100")
    #expect(c.zoomStops == Config.defaultZoomStops)
    #expect(warnings == ["loupe.conf:1: unknown zoom stop 'fit_width'", "loupe.conf:1: unknown zoom stop '100'",
                         "loupe.conf:1: no known zoom stops, using the defaults"])
}

@Test func aMenuToggleKeepsUnknownTokensInPlace() {
    var c = Config.parse("zoom-stops=fit-width,  later-stop,fit-height,25 %,100%").0
    #expect(c.zoomStops == [.fitWidth, .fitHeight, .percent(25), .percent(100)])
    c.toggleZoomStop(.fitHeight)
    #expect(c.text(forKey: "zoom-stops") == "fit-width,later-stop,25 %,100%")
    c.toggleZoomStop(.fitHeight)
    #expect(c.text(forKey: "zoom-stops") == "fit-width,later-stop,25 %,100%,fit-height")
}

@Test func aMenuToggleFromTheFallbackStartsFromTheDefaultsAndKeepsTheUnknownTokens() {
    var c = Config.parse("zoom-stops=fit_width").0
    #expect(c.hasZoomStop(.fitWidth))   // the defaults are in effect
    c.toggleZoomStop(.fitWidth)
    #expect(c.zoomStops == [.fitHeight, .percent(100)])
    #expect(c.text(forKey: "zoom-stops") == "fit_width,fit-height,100%")
    #expect(Config.parse("zoom-stops=" + c.text(forKey: "zoom-stops")!).0 == c)
}

// MARK: Cache keys

@Test func cacheKeys() {
    let d = Config()
    #expect(d.cacheFull == 1 && d.cachePreviews == 20 && d.cacheFarPreviewsCoarse && d.cacheFiles == 24)
    #expect(d.cacheMemory == Machine.cacheMemory && d.showBlurry == .no)

    var (c, w) = Config.parse("cache-memory=512M\ncache-full=2\ncache-previews=50\ncache-far-previews=full\ncache-files=0\nshow-blurry=fit")
    #expect(w.isEmpty)
    #expect(c.cacheMemory == 512 << 20 && c.cacheFull == 2 && c.cachePreviews == 50)
    #expect(!c.cacheFarPreviewsCoarse && c.cacheFiles == 0 && c.showBlurry == .fit)

    #expect(Config.parse("cache-memory=3G").0.cacheMemory == 3 << 30)
    #expect(Config.parse("cache-memory=1048576").0.cacheMemory == 1 << 20)
    #expect(Config.parse("cache-memory=2g").0.cacheMemory == 2 << 30)

    for bad in ["cache-memory=0", "cache-memory=-1G", "cache-memory=lots", "cache-memory=G", "cache-previews=0", "cache-previews=201",
                "cache-full=3", "cache-full=-1", "cache-files=51", "cache-far-previews=maybe", "show-blurry=yes"] {
        (c, w) = Config.parse(bad)
        #expect(w == ["loupe.conf:1: bad option '\(bad)'"], "\(bad)")
        #expect(c == Config(), "\(bad)")
    }
}

@Test func cacheKeysAreWrittenBack() throws {
    var c = Config()
    c.cacheMemory = 512 << 20
    #expect(c.text(forKey: "cache-memory") == "512M")
    c.cacheMemory = 2 << 30
    #expect(c.text(forKey: "cache-memory") == "2G")
    c.cacheMemory = 1_000_000
    #expect(c.text(forKey: "cache-memory") == "1000000")
    c.cacheFarPreviewsCoarse = false
    c.showBlurry = .always
    #expect(c.text(forKey: "cache-far-previews") == "full" && c.text(forKey: "show-blurry") == "always")
    #expect(c.text(forKey: "cache-full") == "1" && c.text(forKey: "cache-previews") == "20" && c.text(forKey: "cache-files") == "24")
    for key in ["cache-full", "cache-previews", "cache-far-previews", "cache-files", "cache-memory", "show-blurry"] {
        #expect(Config.keys.contains(key))
    }
    // Round trip through the file text.
    let text = Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    let (back, warnings) = Config.parse(text)
    #expect(warnings.isEmpty && back == c)
}

/// `wheel-step`: what a wheel step waits for before the next notch may step (`StepGate`), right after
/// `show-blurry` in the file.
@Test func wheelStepKey() throws {
    #expect(Config().wheelStep == .thumb)
    for wait in StepWait.allCases {
        let (c, w) = Config.parse("wheel-step=\(wait.rawValue.uppercased())")
        #expect(w.isEmpty && c.wheelStep == wait, "\(wait)")
        #expect(c.text(forKey: "wheel-step") == wait.rawValue)
    }
    let (c, w) = Config.parse("wheel-step=fast")
    #expect(w == ["loupe.conf:1: bad option 'wheel-step=fast'"])
    #expect(c == Config())
    let blurry = try #require(Config.keys.firstIndex(of: "show-blurry"))
    #expect(Config.keys[blurry + 1] == "wheel-step")
    var written = Config()
    written.wheelStep = .coarse
    let text = Config.keys.compactMap { k in written.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    let (back, warnings) = Config.parse(text)
    #expect(warnings.isEmpty && back == written)
}

/// `key-step`: the same for the keyboard's previous / next, right after `wheel-step` in the file.
@Test func keyStepKey() throws {
    #expect(Config().keyStep == .thumb)
    for wait in StepWait.allCases {
        let (c, w) = Config.parse("key-step=\(wait.rawValue.uppercased())")
        #expect(w.isEmpty && c.keyStep == wait && c.wheelStep == .thumb, "\(wait)")
        #expect(c.text(forKey: "key-step") == wait.rawValue)
    }
    let (c, w) = Config.parse("key-step=fast")
    #expect(w == ["loupe.conf:1: bad option 'key-step=fast'"])
    #expect(c == Config())
    let wheel = try #require(Config.keys.firstIndex(of: "wheel-step"))
    #expect(Config.keys[wheel + 1] == "key-step")
    var written = Config()
    written.keyStep = .sharp
    let text = Config.keys.compactMap { k in written.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    let (back, warnings) = Config.parse(text)
    #expect(warnings.isEmpty && back == written)
}

@Test func cacheLimitsFollowConfig() {
    #expect(CacheLimits(config: Config()) == CacheLimits())
    var c = Config()
    c.cacheFull = 2; c.cachePreviews = 7; c.cacheFarPreviewsCoarse = false; c.cacheFiles = 3; c.cacheMemory = 1 << 30; c.showBlurry = .fit
    let l = CacheLimits(config: c)
    #expect(l.full == 2 && l.previews == 7 && !l.farPreviewsCoarse && l.files == 3 && l.memory == 1 << 30 && l.showBlurry == .fit)
}

@Test func windowKeysParse() {
    let d = Config()
    #expect(d.openIn == .tab && d.newWindowFullScreen == .follow && d.cacheIdleTrimMinutes == 30 && d.cacheIdleKeep == .full)
    #expect(d.text(forKey: "open-in") == "tab" && d.text(forKey: "new-window-fullscreen") == "follow")
    #expect(d.text(forKey: "cache-idle-trim") == "30" && d.text(forKey: "cache-idle-keep") == "full")

    #expect(Config.parse("open-in=window").0.openIn == .window)
    #expect(Config.parse("open-in=WINDOW").0.openIn == .window)
    #expect(Config.parse("open-in=replace").0.openIn == .replace)
    #expect(Config.parse("open-in=new").1.count == 1)
    var c = Config()
    #expect(c.set("open-in", "new") == .badValue && c.openIn == .tab)
    #expect(Config.parse("new-window-fullscreen=no").0.newWindowFullScreen == .no)
    #expect(Config.parse("cache-idle-keep=preview").0.cacheIdleKeep == .preview)

    #expect(Config.parse("cache-idle-trim=0").0.cacheIdleTrimMinutes == 0)
    #expect(Config.parse("cache-idle-trim=45").0.cacheIdleTrimMinutes == 45)
    #expect(Config.parse("cache-idle-trim=1440").0.cacheIdleTrimMinutes == 1440)
    for bad in ["cache-idle-trim=-1", "cache-idle-trim=1441", "cache-idle-trim=soon", "new-window-fullscreen=yes",
                "cache-idle-keep=none"] {
        #expect(Config.parse(bad).1.count == 1, "\(bad)")
    }
}

@Test func cacheLimitsIdleTrim() {
    #expect(CacheLimits(config: Config()).idleTrim == .seconds(1800))
    #expect(CacheLimits(config: Config()).idleKeep == .full)
    var c = Config()
    c.cacheIdleTrimMinutes = 0
    #expect(CacheLimits(config: c).idleTrim == nil)
    c.cacheIdleTrimMinutes = 30
    c.cacheIdleKeep = .preview
    let l = CacheLimits(config: c)
    #expect(l.idleTrim == .seconds(1800) && l.idleKeep == .preview)
}

@Test func hapticsValueIsNotACacheValue() {
    let (c, w) = Config.parse("zoom-stop-haptics=2")
    #expect(w == ["loupe.conf:1: bad option 'zoom-stop-haptics=2'"])
    #expect(c.cacheFull == 1 && c.zoomStopHaptics)
}

// MARK: Cursor

@Test func cursorAutohideParsesMillisecondsOrNo() {
    #expect(Config().cursorAutohideMilliseconds == 1000)
    #expect(Config.parse("cursor-autohide=2500").0.cursorAutohideMilliseconds == 2500)
    #expect(Config.parse("cursor-autohide=no").0.cursorAutohideMilliseconds == nil)
    for bad in ["cursor-autohide=-5", "cursor-autohide=1.5", "cursor-autohide=always", "cursor-autohide=600001"] {
        let (c, w) = Config.parse(bad)
        #expect(c.cursorAutohideMilliseconds == 1000 && w.count == 1, "\(bad)")
    }
    var c = Config()
    #expect(c.text(forKey: "cursor-autohide") == "1000")
    c.cursorAutohideMilliseconds = nil
    #expect(c.text(forKey: "cursor-autohide") == "no")
    #expect(Config.parse("cursor-autohide=no").0 == c)
}

// MARK: Strip and thumbnails

@Test func appearanceWords() {
    #expect(Config().appearance == .system && Config().text(forKey: "appearance") == "system")
    for (word, value) in [("light", AppAppearance.light), ("dark", .dark), ("system", .system)] {
        let (c, w) = Config.parse("appearance=\(word)")
        #expect(c.appearance == value && w.isEmpty && c.text(forKey: "appearance") == word)
    }
    let (c, w) = Config.parse("appearance=sepia")
    #expect(c.appearance == .system && w == ["loupe.conf:1: bad option 'appearance=sepia'"])
    let keys = Config.keys
    let appearance = keys.firstIndex(of: "appearance")!
    #expect(keys[appearance - 1] == "stash-title" && keys[appearance + 1] == "home-tab")
}

@Test func stripWindowWords() {
    #expect(Config().stripWindow == .beside && Config().text(forKey: "strip-window") == "beside")
    for (word, mode) in [("over", StripWindowMode.over), ("beside", .beside), ("hidden", .hidden)] {
        let (c, w) = Config.parse("strip-window=\(word)")
        #expect(c.stripWindow == mode && w.isEmpty)
    }
}

@Test func stripWindowOldWordsStillWork() {
    for (old, new, mode) in [("overlay", "over", StripWindowMode.over), ("bar", "beside", .beside), ("off", "hidden", .hidden)] {
        let (c, w) = Config.parse("strip-window=\(old)")
        #expect(c.stripWindow == mode)
        #expect(w == ["loupe.conf:1: 'strip-window=\(old)' is now 'strip-window=\(new)'"])
    }
    var c = Config(); #expect(c.set("strip-window", "overlay") == .ok && c.stripWindow == .over)
}

@Test func stripAndThumbKeysParse() {
    let text = """
    strip-window=beside
    strip-height=96
    strip-cell-max=1
    strip-corner-radius=6.5
    strip-scroll-direction=reversed
    strip-hide-delay=3000
    strip-fade-in=80
    strip-fade-out=400
    strip-jump-preview=no
    strip-loading-indicator=yes
    thumb-size=768
    thumb-cache-size=512M
    """
    let (c, w) = Config.parse(text)
    var expected = Config()
    expected.stripWindow = .beside
    expected.stripHeight = 96
    expected.stripCellMax = 1
    expected.stripCornerRadius = 6.5
    expected.stripScrollDirection = .reversed
    expected.stripHideDelayMilliseconds = 3000
    expected.stripFadeInMilliseconds = 80
    expected.stripFadeOutMilliseconds = 400
    expected.stripJumpPreview = false
    expected.stripLoadingIndicator = true
    expected.thumbSize = 768
    expected.thumbCacheBytes = 512 << 20
    #expect(c == expected && w.isEmpty)
    #expect(Config.parse("strip-window=hidden").0.stripWindow == .hidden)
    #expect(Config.parse("strip-window=over").0.stripWindow == .over)
}

@Test func stripAndThumbDefaults() {
    let c = Config()
    #expect(c.stripWindow == .beside && c.stripHeight == 68 && c.stripHideDelayMilliseconds == 200)
    #expect(c.stripCellMax == 1.5 && c.stripCornerRadius == 3 && c.stripScrollDirection == .natural)
    #expect(c.stripJumpPreview && !c.stripLoadingIndicator)
    #expect(c.thumbSize == 512 && c.thumbCacheBytes == 2 << 30)
}

@Test func stripAndThumbKeyRanges() {
    let defaults = Config()
    for bad in ["strip-height=39", "strip-height=241", "strip-cell-max=0.5", "strip-cell-max=1.6", "strip-cell-max=2:1",
                "strip-cell-max=nan", "strip-cell-max=0:1", "strip-cell-max=wide", "strip-corner-radius=-1", "strip-corner-radius=16.5",
                "strip-corner-radius=round", "strip-corner-radius=nan", "strip-hide-delay=-1", "strip-hide-delay=10001",
                "thumb-size=255", "thumb-size=1025", "strip-window=dock", "strip-jump-preview=maybe",
                "strip-loading-indicator=maybe", "thumb-cache-size=-1", "strip-scroll-direction=left"] {
        let (c, w) = Config.parse(bad)
        #expect(c == defaults && w.count == 1, "\(bad)")
    }
    for good in ["strip-height=40", "strip-height=240", "strip-cell-max=0.5625", "strip-cell-max=1.5",
                 "strip-cell-max=3:4", "strip-cell-max=1", "strip-corner-radius=0", "strip-corner-radius=16",
                 "strip-corner-radius=3.5", "strip-hide-delay=0", "strip-hide-delay=10000",
                 "thumb-size=256", "thumb-size=1024", "strip-scroll-direction=natural", "strip-scroll-direction=Reversed"] {
        #expect(Config.parse(good).1.isEmpty, "\(good)")
    }
}

@Test func stripHidesQuicklyByDefault() {
    #expect(Config().stripHideDelayMilliseconds == 200)
    #expect(Config().text(forKey: "strip-hide-delay") == "200")
    #expect(Config().stripFadeOutMilliseconds == 150)
    #expect(Config().text(forKey: "strip-fade-out") == "150")
}

@Test func stripHideDelayAcceptsZero() {
    let (c, w) = Config.parse("strip-hide-delay=0")
    #expect(c.stripHideDelayMilliseconds == 0 && w.isEmpty)
    #expect(Config.parse("strip-hide-delay=199").1.isEmpty)
}

@Test func stripFadeKeysParseAndRoundTrip() throws {
    let defaults = Config()
    #expect(defaults.stripFadeInMilliseconds == 150 && defaults.stripFadeOutMilliseconds == 150)
    let (c, w) = Config.parse("strip-fade-in=0\nstrip-fade-out=2000")
    #expect(c.stripFadeInMilliseconds == 0 && c.stripFadeOutMilliseconds == 2000 && w.isEmpty)
    #expect(c.text(forKey: "strip-fade-in") == "0" && c.text(forKey: "strip-fade-out") == "2000")
    let hide = try #require(Config.keys.firstIndex(of: "strip-hide-delay"))
    #expect(Config.keys[hide + 1] == "strip-fade-in")
    #expect(Config.keys[hide + 2] == "strip-fade-out")
}

@Test func stripFadeRejectsOutOfRange() {
    let defaults = Config()
    for bad in ["strip-fade-in=-1", "strip-fade-in=2001", "strip-fade-in=slow", "strip-fade-in=1.5",
                "strip-fade-out=-1", "strip-fade-out=2001", "strip-fade-out=slow"] {
        let (c, w) = Config.parse(bad)
        #expect(c == defaults && w.count == 1, "\(bad)")
    }
}

@Test func thumbCacheSizeZeroMeansMemoryOnly() {
    let (c, w) = Config.parse("thumb-cache-size=0")
    #expect(c.thumbCacheBytes == 0 && w.isEmpty)
    #expect(c.text(forKey: "thumb-cache-size") == "0")
    #expect(Config.parse("thumb-cache-size=2G").0.thumbCacheBytes == 2 << 30)
    // cache-memory still rejects zero.
    #expect(Config.parse("cache-memory=0").1.count == 1)
}

@Test func stripKeysRoundTrip() throws {
    var c = Config()
    c.stripWindow = .hidden
    c.stripHeight = 120
    c.stripCellMax = 0.75
    c.stripCornerRadius = 0
    c.stripScrollDirection = .reversed
    c.stripHideDelayMilliseconds = 250
    c.stripJumpPreview = false
    c.stripLoadingIndicator = true
    c.thumbSize = 1024
    c.thumbCacheBytes = 3 << 29
    let keys = ["strip-window", "strip-height", "strip-cell-max", "strip-corner-radius",
                "strip-scroll-direction", "strip-hide-delay", "strip-jump-preview", "strip-loading-indicator", "thumb-size", "thumb-cache-size"]
    for key in keys { #expect(Config.keys.contains(key), "\(key)") }
    let text = keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    #expect(text.contains("thumb-cache-size=1536M"))
    #expect(text.contains("strip-cell-max=0.75\n"))
    let height = try #require(Config.keys.firstIndex(of: "strip-height"))
    #expect(Config.keys[height + 1] == "strip-cell-max")
    #expect(Config.keys[height + 2] == "strip-corner-radius")
    #expect(Config.keys[height + 3] == "strip-scroll-direction")
    #expect(text.contains("strip-scroll-direction=reversed\n"))
    #expect(text.contains("strip-corner-radius=0\n"))
    var fractional = Config()
    fractional.stripCornerRadius = 6.5
    #expect(fractional.text(forKey: "strip-corner-radius") == "6.5")
    let (parsed, w) = Config.parse(text)
    #expect(parsed == c && w.isEmpty)
}

@Test func stripCellMaxParsesNumberAndRatio() {
    #expect(Config().stripCellMax == 1.5)
    #expect(Config.stripCellMaxRange == 0.5625...1.5)
    var c = Config()
    #expect(c.set("strip-cell-max", "3:2") == .ok && c.stripCellMax == 1.5)
    #expect(c.set("strip-cell-max", "9:16") == .ok && c.stripCellMax == 0.5625)
    #expect(c.set("strip-cell-max", "1") == .ok && c.stripCellMax == 1)
    for bad in ["0.5", "2:1", "x", "3:", ":2", "-3:-2", "inf"] {
        #expect(c.set("strip-cell-max", bad) == .badValue, "\(bad)")
        #expect(c.stripCellMax == 1, "\(bad)")
    }
    c.stripCellMax = 1.5
    #expect(c.text(forKey: "strip-cell-max") == "1.5")
}

@Test func retiredStripKeysWarnOnce() {
    let (c, w) = Config.parse("strip-magnify=2\nstrip-aspect=crop")
    #expect(w == ["loupe.conf:1: 'strip-magnify' is no longer used", "loupe.conf:2: 'strip-aspect' is no longer used"])
    #expect(c == Config())
    #expect(Config.retiredKeys == ["strip-aspect", "strip-magnify", "strip-magnify-reach", "strip-magnify-limit"])
    for key in Config.retiredKeys { #expect(!Config.keys.contains(key), "\(key)") }
}

@Test func stripDefaults() {
    #expect(Config().stripWindow == .beside)
    #expect(Config().stripHeight == 68)
    #expect(Config().stripCornerRadius == 3)
}

@Test func dragHeightIsRoundedAndClampedToTheStripRange() {
    #expect(Config.clampedStripHeight(100.4) == 100 && Config.clampedStripHeight(100.5) == 101)
    #expect(Config.clampedStripHeight(-50) == 40 && Config.clampedStripHeight(39.6) == 40)
    #expect(Config.clampedStripHeight(240.4) == 240 && Config.clampedStripHeight(5000) == 240)
    #expect(Config.clampedStripHeight(.nan) == 40 && Config.clampedStripHeight(.infinity) == 40)
    #expect(Config.clampedStripHeight(64) == 64)
}

// MARK: Stats bar

@Test func statsBarKeys() throws {
    let defaults = Config()
    #expect(defaults.statsProgress && defaults.statsFolderName)
    #expect(defaults.text(forKey: "stats-progress") == "yes" && defaults.text(forKey: "stats-folder-name") == "yes")
    let (c, w) = Config.parse("stats-progress=no\nstats-folder-name=no")
    #expect(!c.statsProgress && !c.statsFolderName && w.isEmpty)
    #expect(c.text(forKey: "stats-progress") == "no" && c.text(forKey: "stats-folder-name") == "no")
    for bad in ["stats-progress=maybe", "stats-folder-name=big"] {
        let (parsed, warnings) = Config.parse(bad)
        #expect(parsed == defaults && warnings.count == 1, "\(bad)")
    }
    // Near the end, just before app-icon.
    let icon = try #require(Config.keys.firstIndex(of: "app-icon"))
    #expect(Config.keys[icon - 3] == "stats-progress" && Config.keys[icon - 2] == "stats-progress-opacity"
            && Config.keys[icon - 1] == "stats-folder-name")
    let text = Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    #expect(Config.parse(text) == (c, []))
}

// MARK: App icon

@Test func appIconKey() {
    #expect(Config().appIcon == "owl")
    #expect(Config.keys.last == "app-icon")
    for choice in [AppIcon.bundle] + AppIcon.alternates + ["my-own_1.2", "~/Pictures/icon.png", "/tmp/My Icon.icns"] {
        var c = Config()
        c.appIcon = choice
        let text = "app-icon=" + (c.text(forKey: "app-icon") ?? "")
        let (parsed, w) = Config.parse(text)
        #expect(parsed == c && w.isEmpty, "\(text)")
    }
    #expect(Config.parse("app-icon=Profile").0.appIcon == "profile")
    #expect(Config.parse("app-icon=Hat").0.appIcon == "hat")
    // A name not in the app is fine: it may be a picture in ~/.config/loupe/icons.
    #expect(Config.parse("app-icon=sunset").0.appIcon == "sunset")
    // Paths keep their case.
    #expect(Config.parse("app-icon=~/Icons/Owl.PNG").0.appIcon == "~/Icons/Owl.PNG")
    let (c, w) = Config.parse("app-icon=two words")
    #expect(c.appIcon == "owl" && w == ["loupe.conf:1: bad option 'app-icon=two words'"])
}

// MARK: Right-button zoom

@Test func rmbZoomKeysDefaultParseAndRoundTrip() {
    let d = Config()
    #expect(d.rmbZoomSpeed == 1.5 && !d.rmbZoomInertia)
    #expect(d.text(forKey: "rmb-zoom-speed") == "1.5" && d.text(forKey: "rmb-zoom-inertia") == "no")
    let (c, w) = Config.parse("rmb-zoom-speed=2.25\nrmb-zoom-inertia=yes\n")
    #expect(w.isEmpty && c.rmbZoomSpeed == 2.25 && c.rmbZoomInertia)
    #expect(c.text(forKey: "rmb-zoom-speed") == "2.25" && c.text(forKey: "rmb-zoom-inertia") == "yes")
    #expect(Config.parse("rmb-zoom-speed=0.25").0.rmbZoomSpeed == 0.25)
    #expect(Config.parse("rmb-zoom-speed=5").0.rmbZoomSpeed == 5)
    for key in ["rmb-zoom-speed", "rmb-zoom-inertia"] { #expect(Config.keys.contains(key)) }
    let text = Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    #expect(Config.parse(text) == (c, []))
}

@Test func rmbZoomKeysRejectBadValues() {
    for bad in ["rmb-zoom-speed=0.24", "rmb-zoom-speed=5.1", "rmb-zoom-speed=0", "rmb-zoom-speed=-1",
                "rmb-zoom-speed=nan", "rmb-zoom-speed=fast", "rmb-zoom-inertia=maybe"] {
        let (c, w) = Config.parse(bad)
        #expect(c == Config() && w.count == 1, "\(bad)")
    }
}

// MARK: Thumb-wheel zoom

@Test func thumbZoomKeysDefaultParseAndRoundTrip() {
    let d = Config()
    #expect(d.thumbWheelZoom && d.thumbZoomSpeed == 2 && d.thumbZoomStops == .tick && !d.thumbZoomInvert)
    #expect(Config.parse("thumb-zoom-invert=yes").0.thumbZoomInvert)
    #expect(d.text(forKey: "thumb-wheel-zoom") == "yes" && d.text(forKey: "thumb-zoom-speed") == "2"
            && d.text(forKey: "thumb-zoom-stops") == "tick")
    let (c, w) = Config.parse("thumb-wheel-zoom=no\nthumb-zoom-speed=0.75\nthumb-zoom-stops=HALT\n")
    #expect(w.isEmpty && !c.thumbWheelZoom && c.thumbZoomSpeed == 0.75 && c.thumbZoomStops == .halt)
    #expect(Config.parse("thumb-zoom-speed=8").0.thumbZoomSpeed == 8)
    let text = Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    #expect(Config.parse(text) == (c, []))
}

@Test func thumbZoomKeysRejectBadValues() {
    for bad in ["thumb-zoom-speed=0.2", "thumb-zoom-speed=8.5", "thumb-zoom-speed=nan", "thumb-wheel-zoom=maybe",
                "thumb-zoom-stops=stop"] {
        let (c, w) = Config.parse(bad)
        #expect(c == Config() && w.count == 1, "\(bad)")
    }
}

// MARK: Archives

@Test func archiveFoldersDefaultParseAndRoundTrip() {
    #expect(Config().archiveFolders && Config().text(forKey: "archive-folders") == "yes")
    let (c, w) = Config.parse("archive-folders=no")
    #expect(w.isEmpty && !c.archiveFolders && c.text(forKey: "archive-folders") == "no")
    #expect(Config.parse("archive-folders=maybe").1.count == 1)
}

// MARK: Stash

@Test func stashKeysDefaultParseAndRoundTrip() {
    let d = Config()
    #expect(d.stashURL == nil && d.stashAPIKey.isEmpty && d.stashPathMap.isEmpty)
    #expect(d.text(forKey: "stash-url") == "" && d.text(forKey: "stash-api-key") == "" && d.text(forKey: "stash-path-map") == "")
    let (c, w) = Config.parse("stash-url=http://localhost:9999\nstash-api-key=abc\nstash-path-map=S:\\=/Volumes/S$;X:\\=/x\n")
    #expect(w.isEmpty && c.stashURL == URL(string: "http://localhost:9999"))
    #expect(c.stashAPIKey == "abc" && c.stashPathMap == "S:\\=/Volumes/S$;X:\\=/x")
    #expect(c.text(forKey: "stash-url") == "http://localhost:9999")
    #expect(Config.parse("stash-url=").0.stashURL == nil)
    let text = Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    #expect(Config.parse(text) == (c, []))
}

@Test func folderToastAndStashTitleKeys() {
    let d = Config()
    #expect(d.folderToast && d.stashTitleTidy)
    #expect(d.text(forKey: "folder-toast") == "yes" && d.text(forKey: "stash-title") == "tidy")
    let (c, w) = Config.parse("folder-toast=no\nstash-title=file")
    #expect(w.isEmpty && !c.folderToast && !c.stashTitleTidy && c.text(forKey: "stash-title") == "file")
}

@Test func stashURLRejectsBadValues() {
    for bad in ["stash-url=ftp://x", "stash-url=not a url", "stash-url=http://"] {
        let (c, w) = Config.parse(bad)
        #expect(c == Config() && w.count == 1, "\(bad)")
    }
}

// MARK: Rubber band, drag inertia, invert

@Test func inputFeelKeysDefaultParseAndRoundTrip() {
    let d = Config()
    #expect(d.rubberBand && d.dragInertia && d.inertiaDeceleration == 0.998 && !d.rmbZoomInvert)
    #expect(d.text(forKey: "rubber-band") == "yes" && d.text(forKey: "drag-inertia") == "yes")
    #expect(d.text(forKey: "inertia-deceleration") == "0.998" && d.text(forKey: "rmb-zoom-invert") == "no")
    let (c, w) = Config.parse("rubber-band=no\ndrag-inertia=no\ninertia-deceleration=0.995\nrmb-zoom-invert=yes\n")
    #expect(w.isEmpty && !c.rubberBand && !c.dragInertia && c.inertiaDeceleration == 0.995 && c.rmbZoomInvert)
    #expect(c.text(forKey: "inertia-deceleration") == "0.995" && c.text(forKey: "rmb-zoom-invert") == "yes")
    #expect(Config.parse("inertia-deceleration=0.99").0.inertiaDeceleration == 0.99)
    #expect(Config.parse("inertia-deceleration=0.999").0.inertiaDeceleration == 0.999)
    let text = Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    #expect(Config.parse(text) == (c, []))
}

@Test func inputFeelKeysSitAfterRmbZoomInertia() throws {
    let at = try #require(Config.keys.firstIndex(of: "rmb-zoom-inertia"))
    #expect(Array(Config.keys[(at + 1)...(at + 4)])
            == ["rubber-band", "drag-inertia", "inertia-deceleration", "rmb-zoom-invert"])
}

@Test func inputFeelKeysRejectBadValues() {
    for bad in ["rubber-band=maybe", "drag-inertia=2", "rmb-zoom-invert=flip", "inertia-deceleration=0.98",
                "inertia-deceleration=1", "inertia-deceleration=0.9991", "inertia-deceleration=nan",
                "inertia-deceleration=fast"] {
        let (c, w) = Config.parse(bad)
        #expect(c == Config() && w.count == 1, "\(bad)")
        #expect(c.inertiaDeceleration == 0.998)
    }
}

// MARK: Folder view memory

@Test func folderViewMemoryKey() throws {
    #expect(Config().folderViewMemory == .folder)
    #expect(Config().text(forKey: "folder-view-memory") == "folder")
    let poll = try #require(Config.keys.firstIndex(of: "folder-poll"))
    #expect(Config.keys[poll + 1] == "folder-view-memory")
    for (text, memory) in [("folder", FolderViewMemory.folder), ("photo", .photo), ("no", .off), ("yes", .folder)] {
        let (c, w) = Config.parse("folder-view-memory=\(text)\n")
        #expect(w.isEmpty && c.folderViewMemory == memory, "\(text)")
    }
    #expect(Config.parse("folder-view-memory=photo\n").0.text(forKey: "folder-view-memory") == "photo")
    #expect(Config.parse("folder-view-memory=no\n").0.text(forKey: "folder-view-memory") == "no")
    #expect(Config.parse("folder-view-memory=yes\n").0.text(forKey: "folder-view-memory") == "folder")
    let (d, dw) = Config.parse("folder-view-memory=maybe\n")
    #expect(d == Config() && dw.count == 1)
}

// MARK: Folder polling

@Test func folderPollKey() {
    #expect(Config().folderPollMilliseconds == 3000)
    #expect(Config().text(forKey: "folder-poll") == "3000")
    #expect(Config.keys.contains("folder-poll") && Config.keys.last == "app-icon")
    for (text, value) in [("folder-poll=0", 0), ("folder-poll=500", 500), ("folder-poll=60000", 60_000), ("folder-poll=1200", 1200)] {
        let (c, w) = Config.parse(text)
        #expect(c.folderPollMilliseconds == value && w.isEmpty, "\(text)")
        #expect(c.text(forKey: "folder-poll") == String(value))
    }
    for bad in ["folder-poll=499", "folder-poll=1", "folder-poll=60001", "folder-poll=-1", "folder-poll=no", "folder-poll=1.5"] {
        let (c, w) = Config.parse(bad)
        #expect(c == Config() && w.count == 1, "\(bad)")
    }
    var c = Config()
    c.folderPollMilliseconds = 0
    let text = Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    #expect(Config.parse(text) == (c, []))
}

// MARK: Background

@Test func backgroundDefaultsToADarkerGreyThanMediumGray() {
    #expect(Config().background == BackgroundColor(gray: 0x2a))
    #expect(Config().text(forKey: "background") == "#2a2a2a")
}

@Test func backgroundParsesPresetsAndHex() {
    #expect(Config.parse("background=Black").0.background == BackgroundColor(gray: 0))
    #expect(Config.parse("background=white").0.background == BackgroundColor(gray: 0xff))
    #expect(Config.parse("background=#202428").0.background == BackgroundColor(red: 0x20, green: 0x24, blue: 0x28))
    #expect(Config.parse("background=#abc").0.background == BackgroundColor(red: 0xaa, green: 0xbb, blue: 0xcc))
    for bad in ["grey", "#12345", "#gggggg", "202428", ""] {
        let (c, w) = Config.parse("background=\(bad)")
        #expect(c.background == .default && w == ["loupe.conf:1: bad option 'background=\(bad)'"], "\(bad)")
    }
}

@Test func backgroundRoundTrips() {
    for color in BackgroundColor.presets.map(\.color) + [BackgroundColor(red: 1, green: 0x80, blue: 0xfe)] {
        var c = Config()
        c.background = color
        let (parsed, w) = Config.parse("background=" + (c.text(forKey: "background") ?? ""))
        #expect(parsed == c && w.isEmpty)
    }
    #expect(BackgroundColor(red: 1, green: 0x80, blue: 0xfe).text == "#0180fe")
}

@Test func backgroundLinearUndoesTheSRGBCurve() {
    #expect(BackgroundColor(gray: 0).linear.red == 0)
    #expect(abs(BackgroundColor(gray: 0xff).linear.green - 1) < 1e-12)
    #expect(abs(BackgroundColor(gray: 0x33).linear.blue - 0.0331) < 0.0005)   // sRGB 0.2 → linear ≈ 0.0331
}

// MARK: Folder step by a held button and a horizontal scroll

@Test func folderScrollKeysDefaultParseAndRoundTrip() throws {
    let d = Config()
    #expect(d.folderScrollGesture && d.folderScrollThreshold == 40)
    #expect(d.text(forKey: "folder-scroll-gesture") == "yes" && d.text(forKey: "folder-scroll-threshold") == "40")
    let poll = try #require(Config.keys.firstIndex(of: "folder-poll"))
    #expect(Config.keys[poll + 2] == "folder-scroll-gesture" && Config.keys[poll + 4] == "folder-scroll-threshold")
    #expect(Config.keys.last == "app-icon")
    let (c, w) = Config.parse("folder-scroll-gesture=no\nfolder-scroll-threshold=72.5\n")
    #expect(w.isEmpty && !c.folderScrollGesture && c.folderScrollThreshold == 72.5)
    #expect(c.text(forKey: "folder-scroll-gesture") == "no" && c.text(forKey: "folder-scroll-threshold") == "72.5")
    #expect(Config.parse("folder-scroll-threshold=10").0.folderScrollThreshold == 10)
    #expect(Config.parse("folder-scroll-threshold=400").0.folderScrollThreshold == 400)
    let text = Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    #expect(Config.parse(text) == (c, []))
}

@Test func folderScrollKeysRejectBadValues() {
    for bad in ["folder-scroll-threshold=9.9", "folder-scroll-threshold=401", "folder-scroll-threshold=0",
                "folder-scroll-threshold=-40", "folder-scroll-threshold=nan", "folder-scroll-threshold=far",
                "folder-scroll-gesture=maybe"] {
        let (c, w) = Config.parse(bad)
        #expect(c == Config() && w.count == 1, "\(bad)")
    }
}

@Test func folderScrollRepeatKey() throws {
    let d = Config()
    #expect(d.folderScrollRepeatMilliseconds == 350 && d.text(forKey: "folder-scroll-repeat") == "350")
    let threshold = try #require(Config.keys.firstIndex(of: "folder-scroll-threshold"))
    #expect(Config.keys[threshold + 1] == "folder-scroll-repeat")
    let (c, w) = Config.parse("folder-scroll-repeat=600")
    #expect(w.isEmpty && c.folderScrollRepeatMilliseconds == 600 && c.text(forKey: "folder-scroll-repeat") == "600")
    #expect(Config.parse("folder-scroll-repeat=0").0.folderScrollRepeatMilliseconds == 0)      // one step per press
    #expect(Config.parse("folder-scroll-repeat=100").0.folderScrollRepeatMilliseconds == 100)
    #expect(Config.parse("folder-scroll-repeat=2000").0.folderScrollRepeatMilliseconds == 2000)
    let text = Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    #expect(Config.parse(text) == (c, []))
    for bad in ["99", "1", "2001", "-350", "350.5", "fast", "no"] {
        let (b, bw) = Config.parse("folder-scroll-repeat=" + bad)
        #expect(b == Config() && bw.count == 1, "\(bad)")
    }
}

@Test func folderScrollDirectionKey() throws {
    let d = Config()
    #expect(d.folderScrollDirection == .reversed && d.text(forKey: "folder-scroll-direction") == "reversed")
    let gesture = try #require(Config.keys.firstIndex(of: "folder-scroll-gesture"))
    #expect(Config.keys[gesture + 1] == "folder-scroll-direction")
    let (c, w) = Config.parse("folder-scroll-direction=Natural")
    #expect(w.isEmpty && c.folderScrollDirection == .natural && c.text(forKey: "folder-scroll-direction") == "natural")
    let text = Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")
    #expect(Config.parse(text) == (c, []))
    for bad in ["left", "yes", ""] {
        let (b, bw) = Config.parse("folder-scroll-direction=" + bad)
        #expect(b == Config() && bw.count == 1, "\(bad)")
    }
}

@Test func statsProgressOpacityKey() {
    #expect(Config().statsProgressOpacity == 0.15)
    #expect(Config.parse("stats-progress-opacity=0.3").0.statsProgressOpacity == 0.3)
    for bad in ["0", "0.7", "x"] {
        let (c, w) = Config.parse("stats-progress-opacity=\(bad)")
        #expect(c.statsProgressOpacity == 0.15 && w.count == 1, "\(bad)")
    }
    var c = Config()
    c.statsProgressOpacity = 0.25
    #expect(Config.parse("stats-progress-opacity=" + (c.text(forKey: "stats-progress-opacity") ?? "")).0 == c)
}

// MARK: Config warnings

@Test func configWarningsKey() throws {
    #expect(Config().configWarnings && Config().text(forKey: "config-warnings") == "yes")
    let (c, w) = Config.parse("config-warnings=no")
    #expect(!c.configWarnings && w.isEmpty && c.text(forKey: "config-warnings") == "no")
    // A bad value keeps the default (yes), so the problem is shown.
    let (bad, warnings) = Config.parse("config-warnings=maybe")
    #expect(bad.configWarnings && warnings == ["loupe.conf:1: bad option 'config-warnings=maybe'"])
    // Then `toast-duration` (M4b), before the stats keys.
    let key = try #require(Config.keys.firstIndex(of: "config-warnings"))
    #expect(Config.keys[key + 1] == "toast-duration" && Config.keys[key + 2] == "stats-progress")
}

// MARK: Resampling keys

@Test func resampleKeysParse() {
    let (c, warnings) = Config.parse("upscale=mitchell\ndownscale=catmull-rom\nlanczos-antiring=yes\npixel-art=800")
    #expect(warnings.isEmpty)
    #expect(c.upscale == .kernel(.mitchell) && c.downscale == .kernel(.catmullRom))
    #expect(c.lanczosAntiring && c.pixelArtPercent == 800)
    let d = Config()
    #expect(d.upscale == .kernel(.lanczos3) && d.downscale == .kernel(.lanczos3))
    #expect(!d.lanczosAntiring && d.pixelArtPercent == 400)
    #expect(Config.parse("upscale=bilinear\ndownscale=lanczos2").0.upscale == .bilinear)
    let (h, hw) = Config.parse("upscale-high=catmull-rom\nupscale-high-from=450")
    #expect(hw.isEmpty && h.upscaleHigh == .kernel(.catmullRom) && h.upscaleHighPercent == 450)
    #expect(d.upscaleHigh == .kernel(.mitchell) && d.upscaleHighPercent == 300)
    #expect(Config.parse("upscale-high-from=0").0.upscaleHighPercent == 0)
}

@Test func resampleCaseAndNoOldName() {
    let (c, warnings) = Config.parse("upscale=Lanczos3")
    #expect(warnings.isEmpty && c.upscale == .kernel(.lanczos3))
    #expect(c.text(forKey: "upscale") == "lanczos3")
    #expect(Config.parse("downscale=LANCZOS3").0.downscale == .kernel(.lanczos3))
    // `lanczos` without the 3 is not a filter name (no old names kept: the app is in development).
    #expect(Config.parse("upscale=lanczos").1.count == 1 && Config.parse("downscale=lanczos").1.count == 1)
}

@Test func resampleKeyRanges() {
    for bad in ["upscale=bicubic", "downscale=metalfx", "lanczos-antiring=maybe",
                "pixel-art=99", "pixel-art=6401", "pixel-art=-1",
                "upscale-high=bicubic", "upscale-high-from=99", "upscale-high-from=6401", "upscale-high-from=abc"] {
        let (c, w) = Config.parse(bad)
        #expect(c == Config() && w == ["loupe.conf:1: bad option '\(bad)'"], "\(bad)")
    }
    let (c, w) = Config.parse("pixel-art=0")
    #expect(w.isEmpty && c.pixelArtPercent == 0)
    #expect(Config.parse("pixel-art=100").1.isEmpty && Config.parse("pixel-art=6400").1.isEmpty)
}

@Test func metalfxValue() {
    // A magnifying filter only (spec §3.5, §5): valid for upscale and upscale-high, a warning for downscale.
    let (c, w) = Config.parse("upscale=metalfx\nupscale-high=MetalFX")
    #expect(w.isEmpty && c.upscale == .metalfx && c.upscaleHigh == .metalfx)
    #expect(c.text(forKey: "upscale") == "metalfx" && c.text(forKey: "upscale-high") == "metalfx")
    let (d, dw) = Config.parse("downscale=metalfx")
    #expect(d == Config() && dw == ["loupe.conf:1: bad option 'downscale=metalfx'"])
    #expect(ResampleSettings(config: c).upscale == .metalfx)
}

@Test func ewaLanczosValue() {
    // Magnifying only, like metalfx: valid for upscale and upscale-high (also as `ewa`), a warning for downscale.
    let (c, w) = Config.parse("upscale=ewa-lanczos\nupscale-high=ewa-lanczos")
    #expect(w.isEmpty && c.upscale == .ewaLanczos && c.upscaleHigh == .ewaLanczos)
    #expect(c.text(forKey: "upscale") == "ewa-lanczos" && c.text(forKey: "upscale-high") == "ewa-lanczos")
    let (e, ew) = Config.parse("upscale=EWA")
    #expect(ew.isEmpty && e.upscale == .ewaLanczos)
    let (d, dw) = Config.parse("downscale=ewa-lanczos")
    #expect(d == Config() && dw == ["loupe.conf:1: bad option 'downscale=ewa-lanczos'"])
    #expect(ResampleSettings(config: c).upscaleHigh == .ewaLanczos)
}

@Test func resampleKeysRoundTrip() throws {
    var c = Config()
    c.upscale = .bilinear
    c.downscale = .kernel(.catmullRom)
    c.lanczosAntiring = true
    c.pixelArtPercent = 0
    c.upscaleHigh = .kernel(.lanczos2)
    c.upscaleHighPercent = 0
    c.pyramidFilter = .box
    let keys = ["upscale", "upscale-high", "upscale-high-from", "downscale", "lanczos-antiring", "pixel-art",
                "pyramid-filter"]
    let text = keys.map { "\($0)=\(c.text(forKey: $0) ?? "")" }.joined(separator: "\n")
    let (parsed, w) = Config.parse(text)
    #expect(w.isEmpty && parsed == c)
    // After `background` and the transparency keys (`transparencyKeys`).
    let checkerColors = try #require(Config.keys.firstIndex(of: "checker-colors"))
    #expect(Array(Config.keys[(checkerColors + 1)...(checkerColors + 7)]) == keys)
}

@Test func transparencyKeys() throws {
    // M3b spec §3: verbatim keys, values and defaults; right after `background`.
    let c = Config()
    #expect(c.transparency == .checker && c.checkerSize == 8 && c.checkerColors == .light)
    #expect(c.text(forKey: "transparency") == "checker" && c.text(forKey: "checker-size") == "8")
    #expect(c.text(forKey: "checker-colors") == "light")
    let background = try #require(Config.keys.firstIndex(of: "background"))
    #expect(Array(Config.keys[(background + 1)...(background + 3)]) == ["transparency", "checker-size", "checker-colors"])

    for mode in TransparencyMode.allCases {
        let (parsed, w) = Config.parse("transparency=\(mode.rawValue.uppercased())")
        #expect(w.isEmpty && parsed.transparency == mode && parsed.text(forKey: "transparency") == mode.rawValue)
    }
    #expect(Config.parse("checker-size=2").0.checkerSize == 2 && Config.parse("checker-size=64").0.checkerSize == 64)
    #expect(Config.parse("checker-colors=Dark").0.checkerColors == .dark)
    #expect(CheckerColors.light == CheckerColors(BackgroundColor(gray: 0xff), BackgroundColor(gray: 0xcc)))
    #expect(CheckerColors.dark == CheckerColors(BackgroundColor(gray: 0x33), BackgroundColor(gray: 0x26)))
    let (custom, w) = Config.parse("checker-colors = #102030,#abc")
    #expect(w.isEmpty && custom.checkerColors == CheckerColors(BackgroundColor(red: 0x10, green: 0x20, blue: 0x30),
                                                                BackgroundColor(red: 0xaa, green: 0xbb, blue: 0xcc)))
    #expect(custom.text(forKey: "checker-colors") == "#102030,#aabbcc")
    // ` #` starts a comment in loupe.conf, so a space after the comma cuts the value (and says so).
    #expect(Config.parse("checker-colors=#102030, #abc").1 == ["loupe.conf:1: bad option 'checker-colors=#102030,'"])
    // A custom pair that is a named one is written by its name.
    #expect(Config.parse("checker-colors=#ffffff,#cccccc").0.text(forKey: "checker-colors") == "light")

    for bad in ["transparency=grid", "transparency=", "checker-size=1", "checker-size=65", "checker-size=8.5",
                "checker-size=pt", "checker-colors=white,black", "checker-colors=#fff", "checker-colors=#fff,#000,#888",
                "checker-colors=#fff,", "checker-colors=#ggg,#000", "checker-colors=medium"] {
        let (c, w) = Config.parse(bad)
        #expect(c == Config() && w == ["loupe.conf:1: bad option '\(bad)'"], "\(bad)")
    }

    var changed = Config()
    changed.transparency = .white
    changed.checkerSize = 24
    changed.checkerColors = CheckerColors(BackgroundColor(gray: 0x10), BackgroundColor(red: 1, green: 2, blue: 3))
    let keys = ["transparency", "checker-size", "checker-colors"]
    let (parsed, w2) = Config.parse(keys.map { "\($0)=\(changed.text(forKey: $0) ?? "")" }.joined(separator: "\n"))
    #expect(w2.isEmpty && parsed == changed)
}

@Test func transparencySettingsFromConfig() {
    var c = Config()
    let white = SIMD3<Float>(repeating: 1), cc = Float(BackgroundColor(gray: 0xcc).linear.red)
    #expect(TransparencySettings(config: c) == TransparencySettings())
    let checker = TransparencySettings(config: c)
    #expect(checker.mode == .checker && checker.checkerSizePt == 8)
    #expect(checker.colors.0 == white && checker.colors.1 == SIMD3(repeating: cc))
    c.background = BackgroundColor(gray: 0x80)
    c.transparency = .background
    let grey = Float(BackgroundColor(gray: 0x80).linear.red)
    let solid = TransparencySettings(config: c)
    #expect(solid.colors.0 == SIMD3(repeating: grey) && solid.colors.1 == SIMD3(repeating: grey))
    c.transparency = .black
    #expect(TransparencySettings(config: c).colors.0 == SIMD3(repeating: 0))
    c.transparency = .white
    #expect(TransparencySettings(config: c).colors.1 == white)
    c.checkerSize = 16
    #expect(TransparencySettings(config: c) != TransparencySettings(mode: .white))
}

@Test func pyramidFilterKey() {
    // Lanczos-3 by measurement (spec §4, docs/bench/2026-10-15-m3a-pyramid.md).
    #expect(Config().pyramidFilter == .lanczos3 && Config().text(forKey: "pyramid-filter") == "lanczos3")
    #expect(Config.parse("pyramid-filter=lanczos3").0.pyramidFilter == .lanczos3)
    #expect(Config.parse("pyramid-filter=box").0.pyramidFilter == .box)
    let (c, w) = Config.parse("pyramid-filter=Lanczos3")
    #expect(w.isEmpty && c.pyramidFilter == .lanczos3 && c.text(forKey: "pyramid-filter") == "lanczos3")
    #expect(Config.parse("pyramid-filter=BOX").0.text(forKey: "pyramid-filter") == "box")
    // Only the two pyramid filters: the frame kernels are not offered for building levels.
    for bad in ["pyramid-filter=mitchell", "pyramid-filter=lanczos", "pyramid-filter=bilinear", "pyramid-filter="] {
        let (c, w) = Config.parse(bad)
        #expect(c == Config() && w == ["loupe.conf:1: bad option '\(bad)'"], "\(bad)")
    }
    let pixelArt = Config.keys.firstIndex(of: "pixel-art")
    #expect(pixelArt.map { Config.keys[$0 + 1] } == "pyramid-filter")
}

@Test func configExifOrientation() {
    // Spec M3b §2.1: on by default; `no` shows every photo as stored.
    #expect(Config().exifOrientation && Config().text(forKey: "exif-orientation") == "yes")
    #expect(Config.parse("exif-orientation=yes").0.exifOrientation)
    let (off, w) = Config.parse("exif-orientation=no")
    #expect(w.isEmpty && !off.exifOrientation && off.text(forKey: "exif-orientation") == "no")
    #expect(Config.parse("exif-orientation=No").0.exifOrientation == false)
    let (c, bad) = Config.parse("exif-orientation=sideways")
    #expect(c == Config() && bad == ["loupe.conf:1: bad option 'exif-orientation=sideways'"])
    // Round trip through the text form.
    var changed = Config()
    changed.exifOrientation = false
    #expect(Config.parse("exif-orientation=\(changed.text(forKey: "exif-orientation") ?? "")").0 == changed)
    #expect(Config.keys.firstIndex(of: "pyramid-filter").map { Config.keys[$0 + 1] } == "exif-orientation")
}

@Test func settingsFromConfig() {
    var c = Config()
    c.upscale = .kernel(.mitchell)
    c.downscale = .bilinear
    c.lanczosAntiring = true
    c.pixelArtPercent = 1600
    c.upscaleHigh = .bilinear
    c.upscaleHighPercent = 500
    #expect(ResampleSettings(config: c)
            == ResampleSettings(upscale: .kernel(.mitchell), upscaleHigh: .bilinear, upscaleHighPercent: 500,
                                downscale: .bilinear, antiringing: true, pixelArtPercent: 1600))
    #expect(ResampleSettings(config: Config()) == ResampleSettings())
}

// MARK: Per-key setter and folder overlay

/// One valid and one invalid sample value per key (nil: the key has no invalid value).
private let keySamples: [String: (valid: String, invalid: String?)] = [
    // Unknown tokens are warned about by `parse`, not refused: the list always takes (spec §8.4).
    "zoom-stops": ("fit-height, 200%", nil),
    "zoom-stop-haptics": ("no", "maybe"), "rmb-zoom-speed": ("2", "9"), "rmb-zoom-inertia": ("yes", "maybe"),
    "thumb-wheel-zoom": ("no", "maybe"), "thumb-zoom-speed": ("4", "9"), "thumb-zoom-stops": ("halt", "stop"),
    "thumb-zoom-invert": ("yes", "maybe"),
    "archive-folders": ("no", "maybe"),
    "stash-url": ("http://localhost:9999", "ftp://x"), "stash-api-key": ("k", nil), "stash-path-map": ("S:\\=/Volumes/S$", nil),
    "stash-title": ("file", "raw"),
    "rubber-band": ("no", "maybe"), "drag-inertia": ("no", "maybe"), "inertia-deceleration": ("0.99", "0.98"),
    "rmb-zoom-invert": ("yes", "maybe"),
    "zoom-animation": ("300", "1001"), "zoom-rubber-band": ("no", "maybe"), "keep-zoom-position": ("no", "maybe"), "keep-zoom-as": ("scale", "pixels"),
    "default-zoom-mode": ("fill", "110"), "fit-upscale": ("no", "maybe"),
    "pan-indicators": ("always", "sometimes"), "pan-indicators-hide": ("800", "5001"), "pan-indicators-on-switch": ("yes", "maybe"),
    "launch-reveal": ("immediate", "later"),
    "open-in": ("window", "new"), "new-window-fullscreen": ("no", "yes"), "appearance": ("dark", "sepia"),
    "home-tab": ("stash", "grid"), "home-start": ("folders", "home"), "home-sidebar": ("no", "maybe"), "home-sidebar-width": ("180", "1601"), "home-sidebar-compact": ("no", "maybe"), "home-sidebar-indent": ("even", "wide"), "home-sidebar-folders-first": ("no", "maybe"), "home-sidebar-reroot": ("3", "2"), "browser-card-size": ("60", "59"), "grid-style": ("square", "round"), "grid-names": ("photo", "above"), "recent-count": ("12", "201"), "session-restore": ("last", "always"),
    "cache-idle-trim": ("45", "1441"), "cache-idle-keep": ("preview", "none"),
    "jxl-threads-current": ("6", "17"), "jxl-threads-other": ("3", "0"), "jxl-dc-preview": ("no", "maybe"),
    "pan-indicators-fade": ("500", "2001"), "toast-duration": ("3000", "499"),
    "cache-full": ("2", "3"), "cache-previews": ("10", "0"), "cache-far-previews": ("full", "mid"),
    "cache-files": ("5", "51"), "cache-memory": ("2G", "0"), "show-blurry": ("fit", "sometimes"),
    "wheel-step": ("sharp", "slow"), "key-step": ("coarse", "slow"), "wheel-direction": ("device", "up"), "cursor-autohide": ("1500", "-1"),
    "background": ("#102030", "mauve"), "transparency": ("white", "grid"), "checker-size": ("16", "1"),
    "checker-colors": ("dark", "#fff"),
    "upscale": ("mitchell", "metalfxx"), "upscale-high": ("ewa-lanczos", "ewa-x"),
    "upscale-high-from": ("500", "50"), "downscale": ("bilinear", "metalfx"), "lanczos-antiring": ("yes", "maybe"),
    "pixel-art": ("1600", "50"), "pyramid-filter": ("box", "mitchell"), "exif-orientation": ("no", "maybe"),
    "strip-window": ("over", "wide"), "strip-height": ("120", "10"), "strip-cell-max": ("1", "2"),
    "strip-corner-radius": ("8", "99"), "strip-scroll-direction": ("reversed", "sideways"),
    "strip-hide-delay": ("800", "-1"), "strip-fade-in": ("100", "5000"), "strip-fade-out": ("100", "5000"),
    "strip-jump-preview": ("no", "maybe"), "strip-loading-indicator": ("yes", "maybe"),
    "thumb-size": ("768", "100"), "thumb-cache-size": ("0", "-5"), "folder-poll": ("2000", "100"), "folder-view-memory": ("no", "maybe"),
    "folder-scroll-gesture": ("no", "maybe"), "folder-scroll-direction": ("natural", "left"), "folder-scroll-threshold": ("100", "1"),
    "folder-scroll-repeat": ("500", "50"), "config-warnings": ("no", "maybe"), "folder-toast": ("no", "maybe"),
    "mouse-long-press": ("500", "149"), "mouse-move-step": ("30", "3"), "mouse-haptics": ("no", "maybe"),
    "haptic-zoom-stop": ("knock", "bzzz"), "haptic-limit": ("none", "bzzz"), "haptic-step": ("0x0c", "15"),
    "haptic-toggle": ("damp-collision", "bzzz"), "haptic-end": ("knock", "strong"),
    "haptic-long-armed": ("knock", "bzzz"), "haptic-detent": ("none", "bzzz"),
    "mx-panel-force": ("0", "101"), "mx-side-buttons": ("take", "steal"), "haptic-strength": ("35", "101"), "haptic-strong-strength": ("81", "keep"),
    "stats-progress": ("no", "maybe"), "stats-progress-opacity": ("0.3", "0.9"), "stats-folder-name": ("no", "maybe"),
    "app-icon": ("profile", "two words"),
    "auto-color": ("yes", "maybe"), "auto-color-method": ("apple-luma", "oil"), "auto-color-strength": ("0.5", "1.5"),
    "auto-color-filters": ("curve", "curve,red"), "auto-color-vibrance-gain": ("2", "5"),
    "auto-color-threshold": ("10", "300"), "auto-color-full": ("20", "-1"), "auto-color-fade": ("300", "3000"),
    "vibrance": ("yes", "maybe"), "vibrance-amount": ("0.8", "-1"),
]

@Test func setMatchesParse() {
    #expect(Set(keySamples.keys) == Set(Config.keys), "every key has samples")
    for key in Config.keys {
        let samples = keySamples[key]!
        for (value, valid) in [(samples.valid, true), (samples.invalid, false)] {
            guard let value else { continue }
            let (parsed, warnings) = Config.parse("\(key)=\(value)")
            var set = Config()
            let result = set.set(key, value)
            #expect(result == (valid ? .ok : .badValue), "\(key)=\(value)")
            #expect((result == .ok) == warnings.isEmpty, "\(key)=\(value): \(warnings)")
            #expect(set == parsed, "\(key)=\(value)")
            if valid { #expect(set != Config(), "\(key)=\(value) changes the config") }
        }
    }
}

@Test func setUnknownKey() {
    var c = Config()
    #expect(c.set("no-such-key", "1") == .unknownKey)
    #expect(c == Config())
    // The same line through parse keeps today's text.
    #expect(Config.parse("no-such-key=1").1 == ["loupe.conf:1: bad option 'no-such-key=1'"])
}

@Test func folderKeysAreTheScalingFiltersAndColour() {
    #expect(Config.scalingFolderKeys == ["downscale", "upscale", "upscale-high", "lanczos-antiring"])
    #expect(Config.colorFolderKeys == ["auto-color", "auto-color-method", "auto-color-strength", "vibrance", "vibrance-amount"])
    #expect(Config.zoomFolderKeys == ["keep-zoom-position", "keep-zoom-as", "default-zoom-mode"])
    #expect(Config.folderKeys == Config.scalingFolderKeys + Config.colorFolderKeys + Config.zoomFolderKeys)
    #expect(Config.folderKeys.allSatisfy(Config.keys.contains))
}

@Test func applyingFolderKeys() {
    let (c, rejected) = Config().applying(["upscale-high": "ewa-lanczos", "lanczos-antiring": "yes"])
    #expect(rejected.isEmpty)
    #expect(c.upscaleHigh == .ewaLanczos && c.lanczosAntiring)
    var expected = Config()
    expected.upscaleHigh = .ewaLanczos
    expected.lanczosAntiring = true
    #expect(c == expected)
}

@Test func applyingRejects() {
    // `pixel-art` is a global key, `metalfx` is not a downscale filter: both skipped, the config as it was.
    var base = Config()
    base.upscale = .kernel(.mitchell)
    let (c, rejected) = base.applying(["pixel-art": "400", "downscale": "metalfx"])
    #expect(c == base)
    #expect(rejected == ["downscale=metalfx", "pixel-art=400"])
    // Valid entries still apply next to rejected ones.
    let (mixed, mixedRejected) = base.applying(["upscale": "bilinear", "strip-height": "100"])
    #expect(mixed.upscale == .bilinear && mixed.stripHeight == base.stripHeight)
    #expect(mixedRejected == ["strip-height=100"])
}

/// `wheel-direction`: right after `key-step`; `content` by default (user, M3a: a reversed mouse wheel under natural
/// scrolling stepped backwards).
@Test func wheelDirectionKey() throws {
    #expect(Config().wheelDirection == .content)
    #expect(Config.parse("wheel-direction=Device").0.wheelDirection == .device)
    #expect(Config.parse("wheel-direction=up").1 == ["loupe.conf:1: bad option 'wheel-direction=up'"])
    let keyStep = try #require(Config.keys.firstIndex(of: "key-step"))
    #expect(Config.keys[keyStep + 1] == "wheel-direction")
}

@Test func wheelDirectionSteps() {
    // A page-down notch: negative delta whatever the flag says.
    #expect(WheelDirection.content.isNext(deltaY: -1, invertedFromDevice: true))
    #expect(WheelDirection.content.isNext(deltaY: -1, invertedFromDevice: false))
    #expect(!WheelDirection.content.isNext(deltaY: 1, invertedFromDevice: true))
    // The physical turn, as before.
    #expect(WheelDirection.device.isNext(deltaY: 1, invertedFromDevice: true))
    #expect(!WheelDirection.device.isNext(deltaY: -1, invertedFromDevice: true))
    #expect(WheelDirection.device.isNext(deltaY: -1, invertedFromDevice: false))
}

// MARK: M4b: zoom animation, rubber band, photo-switch mode, fit-upscale, pan indicators, toast

@Test func m4bKeysDefaultsAndParse() {
    let d = Config()
    #expect(d.zoomAnimationMilliseconds == 150 && d.zoomRubberBand && d.keepZoomPosition
            && d.defaultZoomMode == .fit && d.fitUpscale)
    #expect(d.panIndicators == .auto && d.panIndicatorsHideMilliseconds == 400
            && d.panIndicatorsFadeMilliseconds == 250 && d.toastDurationMilliseconds == 2000)
    let text = """
    zoom-animation=1000
    zoom-rubber-band=no
    keep-zoom-position=no
    default-zoom-mode=Fit-Width
    fit-upscale=no
    pan-indicators=Always
    pan-indicators-hide=5000
    pan-indicators-fade=0
    toast-duration=10000
    """
    let (c, w) = Config.parse(text)
    var expected = Config()
    expected.zoomAnimationMilliseconds = 1000
    expected.zoomRubberBand = false
    expected.keepZoomPosition = false
    expected.defaultZoomMode = .fitWidth
    expected.fitUpscale = false
    expected.panIndicators = .always
    expected.panIndicatorsHideMilliseconds = 5000
    expected.panIndicatorsFadeMilliseconds = 0
    expected.toastDurationMilliseconds = 10_000
    #expect(c == expected && w.isEmpty)
    #expect(Config.parse("zoom-animation=no").0.zoomAnimationMilliseconds == 0)
    #expect(Config.parse("zoom-animation=0").0.zoomAnimationMilliseconds == 0)
    #expect(Config.parse("zoom-animation=1").0.zoomAnimationMilliseconds == 1)
    #expect(Config.parse("zoom-animation=yes").0.zoomAnimationMilliseconds == 150)
    #expect(Config.parse("zoom-animation=true").0.zoomAnimationMilliseconds == 150)
    var slow = Config.parse("zoom-animation=400").0
    #expect(slow.set("zoom-animation", "yes") == .ok && slow.zoomAnimationMilliseconds == 150)
    #expect(Config.parse("pan-indicators=no").0.panIndicators == PanIndicatorMode.no)
    #expect(Config.parse("toast-duration=500").0.toastDurationMilliseconds == 500)
    #expect(Config.parse("default-zoom-mode=150%").0.defaultZoomMode == .actual(1.5))
    #expect(Config.parse("default-zoom-mode=12.5%").0.defaultZoomMode == .actual(0.125))
}

@Test func m4bKeysRejectBadValues() {
    let defaults = Config()
    for bad in ["zoom-animation=1001", "zoom-animation=-1", "zoom-animation=fast", "zoom-animation=1.5",
                "zoom-rubber-band=maybe", "keep-zoom-position=maybe", "fit-upscale=maybe",
                "toast-duration=499", "toast-duration=10001", "toast-duration=no",
                "pan-indicators=sometimes", "pan-indicators-hide=-1", "pan-indicators-hide=5001",
                "pan-indicators-fade=-1", "pan-indicators-fade=2001",
                "default-zoom-mode=110", "default-zoom-mode=0%", "default-zoom-mode=-5%", "default-zoom-mode=inf%",
                "default-zoom-mode=nan%", "default-zoom-mode=big", "default-zoom-mode=free"] {
        let (c, w) = Config.parse(bad)
        #expect(c == defaults && w.count == 1, "\(bad)")
    }
}

@Test func m4bKeysRoundTrip() throws {
    var c = Config()
    c.zoomAnimationMilliseconds = 0
    c.zoomRubberBand = false
    c.keepZoomPosition = false
    c.defaultZoomMode = .actual(2.5)
    c.fitUpscale = false
    c.panIndicators = .always
    c.panIndicatorsHideMilliseconds = 0
    c.panIndicatorsFadeMilliseconds = 2000
    c.toastDurationMilliseconds = 750
    #expect(c.text(forKey: "zoom-animation") == "0" && c.text(forKey: "default-zoom-mode") == "250%")
    #expect(c.text(forKey: "pan-indicators") == "always" && c.text(forKey: "toast-duration") == "750")
    let lines = Config.keys.compactMap { key in c.text(forKey: key).map { "\(key)=\($0)" } }
    #expect(Config.parse(lines.joined(separator: "\n")).0 == c)
    #expect(Config().text(forKey: "default-zoom-mode") == "fit" && Config().text(forKey: "zoom-animation") == "150")
    #expect(Config().text(forKey: "fit-upscale") == "yes" && Config().text(forKey: "pan-indicators") == "auto")
}

@Test func panIndicatorsOnSwitchKey() {
    #expect(Config().panIndicatorsOnSwitch == false && Config().text(forKey: "pan-indicators-on-switch") == "no")
    let (c, w) = Config.parse("pan-indicators-on-switch=yes")
    #expect(w.isEmpty && c.panIndicatorsOnSwitch && c.text(forKey: "pan-indicators-on-switch") == "yes")
    #expect(Config.parse("pan-indicators-on-switch=yes\npan-indicators-on-switch=no").0.panIndicatorsOnSwitch == false)
    let (bad, warnings) = Config.parse("pan-indicators-on-switch=maybe")
    #expect(bad == Config() && warnings.count == 1)
}

@Test func launchRevealKey() throws {
    #expect(Config().launchReveal == .settled && Config().text(forKey: "launch-reveal") == "settled")
    let (c, w) = Config.parse("launch-reveal=Immediate")
    #expect(w.isEmpty && c.launchReveal == .immediate && c.text(forKey: "launch-reveal") == "immediate")
    let (bad, warnings) = Config.parse("launch-reveal=yes")
    #expect(bad == Config() && warnings.count == 1)
    let launch = try #require(Config.keys.firstIndex(of: "launch-reveal"))
    #expect(Config.keys[launch + 1] == "open-in" && Config.keys[launch + 2] == "new-window-fullscreen")
    #expect(Config.keys[launch + 3] == "background")
}

@Test func m4bKeyOrder() throws {
    let haptics = try #require(Config.keys.firstIndex(of: "zoom-stop-haptics"))
    #expect(Array(Config.keys[(haptics + 1)...(haptics + 6)])
            == ["zoom-animation", "zoom-rubber-band", "keep-zoom-position", "keep-zoom-as", "default-zoom-mode",
                "fit-upscale"])
    let invert = try #require(Config.keys.firstIndex(of: "rmb-zoom-invert"))
    #expect(Array(Config.keys[(invert + 1)...(invert + 3)])
            == ["pan-indicators", "pan-indicators-hide", "pan-indicators-fade"])
    #expect(Config.keys[invert + 4] == "pan-indicators-on-switch")
    let warnings = try #require(Config.keys.firstIndex(of: "config-warnings"))
    #expect(Config.keys[warnings + 1] == "toast-duration")
}

@Test func zoomKeysApplyPerFolder() {
    let (c, rejected) = Config().applying(["keep-zoom-position": "no", "default-zoom-mode": "100%"])
    #expect(rejected.isEmpty)
    #expect(c.keepZoomPosition == false && c.defaultZoomMode == .actual(1))
    let (same, bad) = Config().applying(["fit-upscale": "no"])
    #expect(same == Config() && bad == ["fit-upscale=no"])
}

// MARK: M4c: mouse and haptic keys

@Test func m4cMouseKeysDefaultsAndParse() {
    let d = Config()
    #expect(d.mouseLongPressMilliseconds == 400 && d.mouseMoveStep == 20 && d.mouseHaptics)
    #expect(d.hapticZoomStop == HapticChoice(pattern: .subtleCollision) && d.hapticLimit == HapticChoice(pattern: .sharpCollision)
            && d.hapticStep == HapticChoice(pattern: .whisperCollision) && d.hapticToggle == HapticChoice(pattern: .sharpStateChange))
    #expect(d.text(forKey: "mouse-long-press") == "400" && d.text(forKey: "mouse-move-step") == "20"
            && d.text(forKey: "mouse-haptics") == "yes")
    #expect(d.text(forKey: "haptic-zoom-stop") == "subtle-collision" && d.text(forKey: "haptic-limit") == "sharp-collision"
            && d.text(forKey: "haptic-step") == "whisper-collision" && d.text(forKey: "haptic-toggle") == "sharp-state-change")
    for key in ["mouse-long-press", "mouse-move-step", "mouse-haptics", "haptic-zoom-stop", "haptic-limit", "haptic-step",
                "haptic-toggle"] {
        #expect(Config.keys.contains(key), "\(key)")
    }
    let (c, w) = Config.parse("mouse-long-press=150\nmouse-move-step=4.5\nmouse-haptics=no\nhaptic-step=none\nhaptic-limit=knock\nhaptic-zoom-stop=0x1b\nhaptic-toggle=Damp_Collision\n")
    #expect(w.isEmpty && c.mouseLongPressMilliseconds == 150 && c.mouseMoveStep == 4.5 && !c.mouseHaptics)
    #expect(c.hapticStep == nil && c.text(forKey: "haptic-step") == "none")
    #expect(c.hapticLimit == HapticChoice(pattern: .knock) && c.hapticZoomStop == HapticChoice(pattern: .whisperCollision)
            && c.hapticToggle == HapticChoice(pattern: .dampCollision))
    #expect(Config.parse(Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")) == (c, []))
    for bad in ["mouse-long-press=149", "mouse-long-press=2001", "mouse-move-step=3", "mouse-move-step=201",
                "mouse-haptics=maybe", "haptic-toggle=bzzz", "haptic-limit=15"] {
        let (parsed, warnings) = Config.parse(bad)
        #expect(parsed == Config() && warnings.count == 1, "\(bad)")
    }
    #expect(Config.parse("mouse-long-press=2000").1.isEmpty && Config.parse("mouse-long-press=150").1.isEmpty)
}

@Test func hapticArmedAndDetentKeys() {
    let d = Config()
    #expect(d.hapticLongArmed == HapticChoice(pattern: .dampStateChange) && d.hapticDetent == HapticChoice(pattern: .dampCollision))
    #expect(d.text(forKey: "haptic-long-armed") == "damp-state-change" && d.text(forKey: "haptic-detent") == "damp-collision")
    for key in ["haptic-long-armed", "haptic-detent"] { #expect(Config.keys.contains(key), "\(key)") }
    let (c, w) = Config.parse("haptic-long-armed=0x1b strong\nhaptic-detent=knock\n")
    #expect(w.isEmpty && c.hapticLongArmed == HapticChoice(pattern: .whisperCollision, strong: true)
            && c.hapticDetent == HapticChoice(pattern: .knock))
    #expect(c.text(forKey: "haptic-long-armed") == "whisper-collision strong" && c.text(forKey: "haptic-detent") == "knock")
    let (n, nw) = Config.parse("haptic-long-armed=none\nhaptic-detent=none\n")
    #expect(nw.isEmpty && n.hapticLongArmed == nil && n.hapticDetent == nil
            && n.text(forKey: "haptic-long-armed") == "none" && n.text(forKey: "haptic-detent") == "none")
    #expect(Config.parse("haptic-detent=4").0.hapticDetent == HapticChoice(pattern: .subtleCollision))
    #expect(Config.parse(Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")) == (c, []))
    #expect(Config.parse(Config.keys.compactMap { k in n.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")) == (n, []))
    for bad in ["haptic-long-armed=bzzz", "haptic-detent=bzzz", "haptic-detent=strong", "haptic-long-armed=none strong",
                "haptic-detent=+4", "haptic-detent=-1", "haptic-detent=0xff", "haptic-detent=15"] {
        let (parsed, warnings) = Config.parse(bad)
        #expect(parsed == Config() && warnings.count == 1, "\(bad)")
    }
}

@Test func hapticValueSpellings() {
    let (c, w) = Config.parse("haptic-end=  Sharp_Collision   STRONG \nhaptic-step=sharp state change\n"
                              + "haptic-limit=0X0C\nhaptic-detent=4\tstrong\nhaptic-toggle=NONE\n")
    #expect(w.isEmpty && c.hapticEnd == HapticChoice(pattern: .sharpCollision, strong: true)
            && c.hapticStep == HapticChoice(pattern: .sharpStateChange) && c.hapticLimit == HapticChoice(pattern: .knock)
            && c.hapticDetent == HapticChoice(pattern: .subtleCollision, strong: true) && c.hapticToggle == nil)
    #expect(c.text(forKey: "haptic-end") == "sharp-collision strong" && c.text(forKey: "haptic-step") == "sharp-state-change"
            && c.text(forKey: "haptic-toggle") == "none")
}

@Test func m4cPanelForceAndStrengthKeys() {
    let d = Config()
    #expect(d.mxPanelForce == .keep && d.hapticStrength == nil && d.hapticStrongStrength == 80)
    #expect(d.hapticEnd == HapticChoice(pattern: .sharpCollision, strong: true))
    #expect(d.text(forKey: "mx-panel-force") == "keep" && d.text(forKey: "haptic-strength") == "keep"
            && d.text(forKey: "haptic-strong-strength") == "80" && d.text(forKey: "haptic-end") == "sharp-collision strong")
    for key in ["mx-panel-force", "haptic-strength", "haptic-strong-strength", "haptic-end"] {
        #expect(Config.keys.contains(key), "\(key)")
    }
    #expect(Config.parse("mx-panel-force=0").0.mxPanelForce == .percent(0))
    #expect(Config.parse("mx-panel-force=100").0.mxPanelForce == .percent(100))
    #expect(Config.parse("mx-panel-force=default").0.mxPanelForce == .factory)
    #expect(Config.parse("mx-panel-force=0\nmx-panel-force=keep").0.mxPanelForce == .keep)
    #expect(Config.parse("haptic-strength=35").0.hapticStrength == 35)
    #expect(Config.parse("haptic-strength=35\nhaptic-strength=keep").0.hapticStrength == nil)
    #expect(Config.parse("haptic-strong-strength=81").0.hapticStrongStrength == 81)
    let (c, w) = Config.parse("mx-panel-force=0\nhaptic-strength=35\nhaptic-strong-strength=81\n"
                              + "haptic-end=sharp-collision strong\nhaptic-step=whisper-collision strong\nhaptic-limit=knock\n")
    #expect(w.isEmpty)
    #expect(c.hapticEnd == HapticChoice(pattern: .sharpCollision, strong: true) && c.hapticStep == HapticChoice(pattern: .whisperCollision, strong: true))
    #expect(c.hapticLimit == HapticChoice(pattern: .knock, strong: false))
    #expect(c.text(forKey: "haptic-end") == "sharp-collision strong" && c.text(forKey: "haptic-step") == "whisper-collision strong"
            && c.text(forKey: "mx-panel-force") == "0" && c.text(forKey: "haptic-strength") == "35")
    #expect(Config.parse(Config.keys.compactMap { k in c.text(forKey: k).map { "\(k)=\($0)" } }.joined(separator: "\n")) == (c, []))
    let factory = Config.parse("mx-panel-force=default\nhaptic-end=none").0
    #expect(factory.text(forKey: "mx-panel-force") == "default" && factory.hapticEnd == nil
            && factory.text(forKey: "haptic-end") == "none")
    for bad in ["mx-panel-force=101", "mx-panel-force=-1", "mx-panel-force=soft", "mx-panel-force=50.5",
                "haptic-strength=101", "haptic-strength=default", "haptic-strong-strength=keep", "haptic-strong-strength=101",
                "haptic-end=strong", "haptic-end=none strong", "haptic-end=sharp-collision loud", "haptic-toggle=bzzz strong"] {
        let (parsed, warnings) = Config.parse(bad)
        #expect(parsed == Config() && warnings.count == 1, "\(bad)")
    }
}

@Test func sideButtonsKey() {
    #expect(Config().mxSideButtons == .watch)
    #expect(Config().text(forKey: "mx-side-buttons") == "watch")
    #expect(Config.keys.contains("mx-side-buttons"))
    for mode in [SideButtonsMode.watch, .take, .system] {
        let (c, w) = Config.parse("mx-side-buttons=\(mode.rawValue)")
        #expect(w.isEmpty && c.mxSideButtons == mode && c.text(forKey: "mx-side-buttons") == mode.rawValue)
    }
    #expect(Config.parse("mx-side-buttons=take\nmx-side-buttons=system").0.mxSideButtons == .system)
    for bad in ["mx-side-buttons=steal", "mx-side-buttons=", "mx-side-buttons=yes", "mx-side-buttons=Watch2"] {
        let (parsed, warnings) = Config.parse(bad)
        #expect(parsed == Config() && warnings.count == 1, "\(bad)")
    }
}

@Test func panelForcePercentMapsOverTheMouseRange() {
    let range: ClosedRange<UInt16> = 3799...6316
    #expect(PanelForceSetting.keep.value(range: range, defaultValue: 4749) == nil)
    #expect(PanelForceSetting.factory.value(range: range, defaultValue: 4749) == 4749)
    #expect(PanelForceSetting.percent(0).value(range: range, defaultValue: 4749) == 3799)
    #expect(PanelForceSetting.percent(100).value(range: range, defaultValue: 4749) == 6316)
    // 3799 + 2517 · 0.5 = 5057.5, rounded.
    #expect(PanelForceSetting.percent(50).value(range: range, defaultValue: 4749) == 5058)
    #expect(PanelForceSetting.percent(37).value(range: 0...UInt16.max, defaultValue: 0) == 24248)
    #expect(PanelForceSetting.percent(40).value(range: 100...100, defaultValue: 100) == 100)
    // Outside 0…100 (the parser rejects it, the mapping still holds to the range).
    #expect(PanelForceSetting.percent(-5).value(range: range, defaultValue: 4749) == 3799)
    #expect(PanelForceSetting.percent(105).value(range: range, defaultValue: 4749) == 6316)
}

// MARK: New key lands after its commented example

@Test func newLineGoesAfterCommentedExample() {
    let text = "# Zoom\n#   zoom-animation=yes   (default)\n\nbackground=#000\n"
    #expect(ConfigText.setting([("zoom-animation", "no")], in: text)
            == "# Zoom\n#   zoom-animation=yes   (default)\nzoom-animation=no\n\nbackground=#000\n")
}

@Test func lastCommentedExampleWins() {
    let text = "# zoom-animation=yes\n# zoom-animation=no\n# other\nbackground=#000\n"
    #expect(ConfigText.setting([("zoom-animation", "no")], in: text)
            == "# zoom-animation=yes\n# zoom-animation=no\nzoom-animation=no\n# other\nbackground=#000\n")
}

@Test func activeLineStillReplaced() {
    let text = "#   zoom-animation=yes   (default)\nzoom-animation=yes # mine\nbackground=#000\n"
    #expect(ConfigText.setting([("zoom-animation", "no")], in: text)
            == "#   zoom-animation=yes   (default)\nzoom-animation=no # mine\nbackground=#000\n")
}

@Test func noExampleAppendsAtEnd() {
    let text = "# ── Zoom ───\n# zoom-animation is about motion\nbackground=#000\n"
    #expect(ConfigText.setting([("zoom-animation", "no")], in: text)
            == "# ── Zoom ───\n# zoom-animation is about motion\nbackground=#000\nzoom-animation=no\n")
}

@Test func otherKeysExampleIgnored() {
    let text = "# zoom-stops=100%\nbackground=#000\n"
    #expect(ConfigText.setting([("zoom-stop-haptics", "no")], in: text) == text + "zoom-stop-haptics=no\n")
}

@Test func exampleMatchesCaseInsensitivelyAndWithLocalisedNote() {
    let text = "#   Zoom-Stops=100%      (по умолчанию)\nbackground=#000\n"
    #expect(ConfigText.setting([("zoom-stops", "200%")], in: text)
            == "#   Zoom-Stops=100%      (по умолчанию)\nzoom-stops=200%\nbackground=#000\n")
}

@Test func twoNewKeysAfterTheirOwnExamples() {
    let text = "# a=1\n# b=1\nc=1\n"
    #expect(ConfigText.setting([("a", "2"), ("b", "2")], in: text) == "# a=1\na=2\n# b=1\nb=2\nc=1\n")
}

@Test func homeKeysDefaults() {
    let d = Config()
    #expect(d.homeTab == .recent && d.recentCount == 24)
    #expect(d.text(forKey: "home-tab") == "recent" && d.text(forKey: "recent-count") == "24")
}

/// Home's own card size and layout went with the start screen (Photos style stage 2): every grid takes
/// `browser-card-size`; old lines are unknown keys now.
@Test func removedHomeKeysWarn() {
    #expect(!Config.keys.contains("home-layout") && !Config.keys.contains("home-card-size"))
    var c = Config()
    #expect(c.set("home-layout", "fit") == .unknownKey)
    #expect(c.set("home-card-size", "220") == .unknownKey)
    #expect(Config.parse("home-layout=fit").1.count == 1)
}

@Test func homeKeysParse() {
    #expect(Config.parse("home-tab=stash").0.homeTab == .stash)
    #expect(Config.parse("recent-count=0").0.recentCount == 0)
    #expect(Config.parse("recent-count=200").0.recentCount == 200)
    var c = Config()
    for (key, value) in [("recent-count", "-1"),
                         ("recent-count", "201"), ("home-tab", "grid")] {
        #expect(c.set(key, value) == .badValue, "\(key)=\(value)")
    }
}

@Test func sessionRestoreKey() {
    #expect(Config().sessionRestore == .none && Config().text(forKey: "session-restore") == "none")
    #expect(Config.parse("session-restore=last").0.sessionRestore == .last)
    var c = Config()
    #expect(c.set("session-restore", "always") == .badValue)
}

@Test func homeSidebarWidthParsesAndDefaults() {
    #expect(Config().homeSidebarWidth == 236)
    #expect(Config().text(forKey: "home-sidebar-width") == "236")
    #expect(Config.parse("home-sidebar-width=1600").0.homeSidebarWidth == 1600)
    #expect(Config.parse("home-sidebar-width=179").1 == ["loupe.conf:1: bad option 'home-sidebar-width=179'"])
}

@Test func homeStartParsesAndDefaults() {
    #expect(Config().homeStart == .recent)
    #expect(Config().text(forKey: "home-start") == "recent")
    #expect(Config.parse("home-start=folders").0.homeStart == .folders)
    #expect(Config.parse("home-start=home").1 == ["loupe.conf:1: bad option 'home-start=home'"])
}

@Test func homeSidebarTreeKeysParseAndDefault() {
    let c = Config()
    #expect(c.homeSidebarCompact && c.homeSidebarIndent == .compact && c.homeSidebarReroot == 0)
    #expect(c.homeSidebarFoldersFirst && c.text(forKey: "home-sidebar-folders-first") == "yes")
    #expect(c.text(forKey: "home-sidebar-compact") == "yes")
    #expect(c.text(forKey: "home-sidebar-indent") == "compact")
    #expect(c.text(forKey: "home-sidebar-reroot") == "0")
    let (parsed, errors) = Config.parse("home-sidebar-compact=no\nhome-sidebar-indent=even\nhome-sidebar-reroot=20")
    #expect(errors.isEmpty)
    #expect(!parsed.homeSidebarCompact && parsed.homeSidebarIndent == .even && parsed.homeSidebarReroot == 20)
    #expect(!Config.parse("home-sidebar-folders-first=no").0.homeSidebarFoldersFirst)
    #expect(Config.parse("home-sidebar-reroot=1").1 == ["loupe.conf:1: bad option 'home-sidebar-reroot=1'"])
    #expect(Config.parse("home-sidebar-reroot=21").1 == ["loupe.conf:1: bad option 'home-sidebar-reroot=21'"])
}

@Test func homeSidebarParsesAndDefaults() {
    #expect(Config().homeSidebar)
    #expect(Config().text(forKey: "home-sidebar") == "yes")
    #expect(!Config.parse("home-sidebar=no").0.homeSidebar)
    #expect(Config.parse("home-sidebar=maybe").1 == ["loupe.conf:1: bad option 'home-sidebar=maybe'"])
}

@Test func homeTabSessions() {
    #expect(Config.parse("home-tab=sessions").0.homeTab == .sessions)
}

@Test func homeTabFoldersParses() {
    #expect(Config.parse("home-tab=folders").0.homeTab == .folders)
    #expect(Config().text(forKey: "browser-card-size") == "220")
}

@Test func browserCardSizeRange() {
    #expect(Config().browserCardSize == 220)
    #expect(Config.parse("browser-card-size=60").0.browserCardSize == 60)
    #expect(Config.parse("browser-card-size=480").0.browserCardSize == 480)
    var c = Config()
    #expect(c.set("browser-card-size", "59") == .badValue)
    #expect(c.set("browser-card-size", "481") == .badValue)
}

@Test func gridDefaults() {
    let d = Config()
    #expect(d.gridStyle == .aspect && d.text(forKey: "grid-style") == "aspect")
    #expect(d.gridNames == .off && d.text(forKey: "grid-names") == "off")
    #expect(d.browserCardSize == 220)
}

@Test func gridParse() {
    #expect(Config.parse("grid-style=square").0.gridStyle == .square)
    #expect(Config.parse("grid-names=below").0.gridNames == .below)
    var c = Config()
    #expect(c.set("grid-style", "round") == .badValue)
    #expect(c.set("grid-names", "above") == .badValue)
    #expect(c.set("browser-aspect", "1:1") != .ok)   // gone: an unknown key now
}

@Test func jxlKeys() {
    let d = Config()
    #expect(d.jxlThreadsCurrent == Machine.jxlThreadsCurrent && d.jxlThreadsOther == 2 && d.jxlDCPreview)

    var (c, w) = Config.parse("jxl-threads-current=6\njxl-threads-other=3\njxl-dc-preview=no")
    #expect(w.isEmpty)
    #expect(c.jxlThreadsCurrent == 6 && c.jxlThreadsOther == 3 && !c.jxlDCPreview)
    #expect(c.text(forKey: "jxl-threads-current") == "6" && c.text(forKey: "jxl-threads-other") == "3")
    #expect(c.text(forKey: "jxl-dc-preview") == "no")

    for bad in ["jxl-threads-current=0", "jxl-threads-current=17", "jxl-threads-other=0", "jxl-threads-other=seven",
                "jxl-dc-preview=maybe"] {
        (c, w) = Config.parse(bad)
        #expect(w == ["loupe.conf:1: bad option '\(bad)'"], "\(bad)")
        #expect(c == Config(), "\(bad)")
    }
    for key in ["jxl-threads-current", "jxl-threads-other", "jxl-dc-preview"] {
        #expect(Config.keys.contains(key))
    }
    #expect(JXLOptions(config: Config()) == JXLOptions())
    var o = Config()
    o.jxlThreadsCurrent = 8; o.jxlThreadsOther = 3; o.jxlDCPreview = false
    #expect(JXLOptions(config: o) == JXLOptions(threadsCurrent: 8, threadsOther: 3, dcPreview: false))
}
