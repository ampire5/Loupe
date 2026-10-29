# Smart zoom, stage 1: the screen's share and `step-pan` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `keep-zoom-as=screen` keeps the share of the view a gesture-zoomed photo covers across steps and resizes,
and `step-pan` (`subject` | `keep` | `center`) decides where the view lands after a step.

**Architecture:** All geometry stays in LoupeCore's pure types: `ViewTransform` learns the screen share and how to
carry it, `PhotoSwitchView.next` applies `step-pan`, `ZoomRules` carries the two settings from `Config`. The app only
passes the carry to a resize and shows the share in the status. `subject` has no boxes in this stage, so it always
takes its fallback (top of a photo taller than the view's shape, else the centre); stage 2 adds the boxes.

**Tech Stack:** Swift 6, Swift Testing, AppKit (Settings window rows, menus).

**Spec:** `docs/superpowers/specs/2026-10-28-smart-zoom-design.md` (§1, §2, §6 rows `keep-zoom-as` and `step-pan`, §8).

## Global Constraints

- A gesture (pinch, wheel, right-button zoom, thumb wheel, `=` / `-`) gives `ZoomMode.free`, also when it rests on a
  zoom stop (`ZoomStop.mode` doc comment); a command gives a named mode. Only `.free` is carried as a share.
- The share is by area: the photo's on-screen rect clipped to the view, over the view's area; no limit to cutting;
  100 % = Fill; the zoom limits (`scaleLimits`) still bound the scale.
- `step-pan` is a folder key (`Config.zoomFolderKeys`), default `subject`, applies to every switch (keep on or off);
  `keep-zoom-position` decides the zoom only. No migration.
- `K` cycles `keep-zoom-as` share → scale → screen.
- Main thread: arithmetic only; no new I/O, timers or tasks.
- Build and test with `scripts/test.sh` (everyday pass); `--filter <name>` narrows.

## Review Focus

1. A photo smaller than the view at the carried share with `fit-upscale=no`: the scale may exceed Fit; it must stay
   within `scaleLimits` and the share must not divide by zero for a degenerate image or view size.
2. A share carried from a photo zoomed *out* below Fit (picture smaller than the view on both axes): the next photo
   must also come out smaller, not jump to Fit.
3. A resize under `screen` while zoomed: the share stays, the centre stays (no jump to the middle).
4. `step-pan=center`/`subject` with a photo that fits on an axis: that axis stays centred (`clamped`), only the
   cut axis moves.
5. A folder whose saved view (`folder-view-memory`) exists: `SavedView` wins over `step-pan`, as it wins over `keep`
   today.

---

### Task 1: Settings — `ZoomCarry.screen`, `StepPan`, `step-pan`, `ZoomRules`

**Files:**
- Modify: `Sources/LoupeCore/Config.swift` (`ZoomCarry` at :86-92, keys list, `zoomFolderKeys`, `text(forKey:)`, `set`)
- Modify: `Sources/LoupeCore/ZoomRules.swift` (`ZoomRules`)
- Modify: `Sources/LoupeCore/ZoomKeys.swift:24-29` (`toggledCarry`, `toast(carry:)`)
- Test: `Tests/LoupeCoreTests/ConfigTests.swift`, `Tests/LoupeCoreTests/ZoomKeysTests.swift`

**Interfaces:**
- Produces: `ZoomCarry.screen` (raw `"screen"`); `public enum StepPan: String, Sendable { case subject, keep, center }`
  in Config.swift next to `ZoomCarry`; `Config.stepPan: StepPan = .subject`; key `"step-pan"` after `"keep-zoom-as"`
  in `Config.keys` and in `zoomFolderKeys`; `ZoomRules.pan: StepPan`; `ZoomKeys.toggledCarry` share → scale →
  screen → share.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func stepPanParsesAndWritesBack() {
    #expect(Config().stepPan == .subject)
    for v in ["subject", "keep", "center"] {
        var c = Config()
        #expect(c.set("step-pan", v) == .ok)
        #expect(c.text(forKey: "step-pan") == v)
    }
    var c = Config()
    #expect(c.set("step-pan", "middle") == .badValue)
    #expect(Config.zoomFolderKeys.contains("step-pan"))
}

@Test func keepZoomAsTakesScreen() {
    var c = Config()
    #expect(c.set("keep-zoom-as", "screen") == .ok)
    #expect(c.keepZoomAs == .screen && ZoomRules(config: c).carry == .screen)
}

@Test func zoomCarryCyclesThroughScreen() {
    var c = Config()
    c.keepZoomAs = .share;  #expect(ZoomKeys.toggledCarry(c) == .scale)
    c.keepZoomAs = .scale;  #expect(ZoomKeys.toggledCarry(c) == .screen)
    c.keepZoomAs = .screen; #expect(ZoomKeys.toggledCarry(c) == .share)
    #expect(ZoomKeys.toast(carry: .screen) == "Zoom keeps: share of screen · folder")
}
```

Also add `"step-pan"` to whatever list `ConfigTests` keeps of every key's sample value (`setMatchesParse` or similar),
with a non-default value (`keep`).

- [ ] **Step 2: Run them to verify they fail**

Run: `scripts/test.sh --filter stepPanParsesAndWritesBack --filter keepZoomAsTakesScreen --filter zoomCarryCyclesThroughScreen`
Expected: build failure (`stepPan`, `.screen` not defined).

- [ ] **Step 3: Implement**

`ZoomCarry`'s doc comment gains `screen`: "the share of the view the picture covers (by area), so the empty space does
not change from photo to photo; a photo of another shape is cut where needed". `StepPan`'s doc comment: the three
values as in spec §2. `set("step-pan")` takes the raw value lowercased; `text(forKey:)` returns `rawValue`.
`ZoomRules.init(config:)` reads `pan = config.stepPan`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the command of Step 2. Expected: PASS. Then `scripts/test.sh`: everything passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/LoupeCore/Config.swift Sources/LoupeCore/ZoomRules.swift Sources/LoupeCore/ZoomKeys.swift Tests/LoupeCoreTests
git commit -m "keep-zoom-as=screen and step-pan (subject / keep / center, a folder key) in the config; K cycles share, scale, screen"
```

### Task 2: `ViewTransform` — the screen share and carrying it

**Files:**
- Modify: `Sources/LoupeCore/ViewTransform.swift` (`carryingZoom` :298-311, `withViewSize` :286-296)
- Modify: `Sources/LoupeCore/SavedView.swift:206-214` (`.screen` restores like `.share`, the ratio to Fit)
- Test: `Tests/LoupeCoreTests/ViewTransformTests.swift`

**Interfaces:**
- Consumes: `ZoomCarry.screen` (Task 1).
- Produces: `public var screenShare: Double` (0…1, the clipped picture area over the view area, at `scale`, ignoring
  `offset`/`stretch`); `public func scale(forScreenShare share: Double) -> Double` (the scale at which this transform's
  image covers `share`, before the zoom limits); `carryingZoom(from:_:)` handles `.screen`;
  `withViewSize(_ s: CGSize, carry: ZoomCarry = .share)` replaces `withViewSize(_:keepingScale:)` (`.scale` = the old
  `keepingScale: true`, `.share` = the old default, `.screen` keeps `screenShare`).

- [ ] **Step 1: Write the failing tests**

View 2000×1000 throughout.

```swift
@Test func screenShareIsTheClippedAreaOverTheView() {
    let fit = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 2000, height: 1000))
    #expect(abs(fit.screenShare - 0.5) < 1e-9)                       // a square at Fit: half the view
    #expect(abs(fit.withMode(.fill).screenShare - 1) < 1e-9)
    #expect(abs(fit.withMode(.free(0.5)).screenShare - 0.125) < 1e-9) // half the side: a quarter of the area
}

@Test func screenCarryKeepsTheShareAcrossShapes() {
    let view = CGSize(width: 2000, height: 1000)
    let landscape = ViewTransform(imageSize: CGSize(width: 3000, height: 1500), viewSize: view, mode: .free(0.8))
    let portrait = ViewTransform(imageSize: CGSize(width: 1000, height: 1500), viewSize: view, mode: .free(1))
    let carried = portrait.carryingZoom(from: landscape, .screen)
    #expect(abs(carried.screenShare - landscape.screenShare) < 1e-9)  // 0.64 by area
    #expect(abs(carried.screenShare - 0.64) < 1e-9)
}

@Test func screenCarryCutsAndFillsAtAFullShare() {
    let view = CGSize(width: 2000, height: 1000)
    let full = ViewTransform(imageSize: CGSize(width: 3000, height: 1500), viewSize: view, mode: .free(1)) // fills
    let portrait = ViewTransform(imageSize: CGSize(width: 1000, height: 1500), viewSize: view, mode: .free(1))
    let carried = portrait.carryingZoom(from: full, .screen)
    #expect(abs(carried.scale - portrait.withMode(.fill).scale) < 1e-9)
}

@Test func screenCarryKeepsAZoomOutSmall() {
    let view = CGSize(width: 2000, height: 1000)
    let small = ViewTransform(imageSize: CGSize(width: 2000, height: 1000), viewSize: view, mode: .free(0.5)) // 25 %
    let next = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: view, mode: .free(1))
    #expect(abs(next.carryingZoom(from: small, .screen).screenShare - 0.25) < 1e-9)
}

@Test func screenCarryStaysWithinTheZoomLimitsAndNamedModesStay() {
    let view = CGSize(width: 2000, height: 1000)
    let full = ViewTransform(imageSize: CGSize(width: 2000, height: 1000), viewSize: view, mode: .free(1))
    let tiny = ViewTransform(imageSize: CGSize(width: 10, height: 1000), viewSize: view, mode: .free(1))
    let carried = tiny.carryingZoom(from: full, .screen)
    #expect(carried.scale <= tiny.scaleLimits.upperBound)
    #expect(ViewTransform(imageSize: .zero, viewSize: view).carryingZoom(from: full, .screen).scale.isFinite)
    let fitted = ViewTransform(imageSize: CGSize(width: 1000, height: 1500), viewSize: view)  // .fit
    #expect(fitted.carryingZoom(from: full, .screen).mode == .fit)
}

@Test func resizeUnderScreenKeepsTheShareAndTheCentre() {
    var t = ViewTransform(imageSize: CGSize(width: 1000, height: 1500), viewSize: CGSize(width: 2000, height: 1000),
                          mode: .free(1.6), center: CGPoint(x: 0.5, y: 0.3))
    let share = t.screenShare
    t = t.withViewSize(CGSize(width: 1200, height: 1000), carry: .screen)
    #expect(abs(t.screenShare - share) < 1e-9)
    #expect(t.center == CGPoint(x: 0.5, y: 0.3))
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `scripts/test.sh --filter screenShare --filter screenCarry --filter resizeUnderScreen`
Expected: build failure (`screenShare`, `carry:` not defined).

- [ ] **Step 3: Implement**

`scale(forScreenShare:)` inverts the piecewise share; with `W×H` the image, `vw×vh` the view, `A = vw·vh`:

```swift
// share(s) = min(W·s, vw) · min(H·s, vh) / A rises with s and is 1 from Fill on.
guard share < 1 else { return fill scale }
let fit = min(vw / W, vh / H)
let both = (share * A / (W * H)).squareRoot()          // neither axis cut
if both <= fit { return both }
return vw / W <= vh / H ? share * vh / H : share * vw / W   // the fitting axis is full, the other one grows
```

Degenerate image sizes return 1 as `fitScale` does. `carryingZoom` for `.screen`: `target = scale(forScreenShare:
old.screenShare)`, then `mode = .free(target / fitScale)` as the other carries do (the `.free` guard on both stays).
Update the callers of `withViewSize(_:keepingScale:)` (grep; `ViewerView.swift:1690` and `ViewTransform`'s own tests)
to `carry:`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the command of Step 2, then `scripts/test.sh`. Expected: PASS, everything else still passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/LoupeCore/ViewTransform.swift Sources/LoupeCore/SavedView.swift Sources/Loupe/ViewerView.swift Tests/LoupeCoreTests
git commit -m "ViewTransform.screenShare and carrying it (keep-zoom-as=screen): by area, cut where the shape needs, within the zoom limits; a resize keeps it too"
```

### Task 3: `PhotoSwitchView.next` applies `step-pan`

**Files:**
- Modify: `Sources/LoupeCore/PhotoSwitchView.swift:28-35`
- Test: `Tests/LoupeCoreTests/PhotoSwitchViewTests.swift`

**Interfaces:**
- Consumes: `ZoomRules.pan` (Task 1), `ViewTransform.clamped`.
- Produces: `PhotoSwitchView.next` sets the centre by `rules.pan`; `public static func fallbackCentre(imageSize:
  viewSize:) -> CGPoint` (top for a photo taller than the view's shape: `(0.5, 0)`, which `clamped` pulls to the top
  edge; else `(0.5, 0.5)`), which stage 2 calls when there are no boxes.

- [ ] **Step 1: Write the failing tests**

The file's `rules(...)` helper gets `pan: StepPan = .keep`, so the existing tests keep testing what they test.

```swift
@Test func stepPanKeepCentreAndSubjectFallback() {
    let tall = CGSize(width: 1000, height: 3000)   // taller than the 2:1 view's shape
    for keep in [true, false] {
        let kept = PhotoSwitchView.next(current: zoomedIn(), imageSize: newSize, rules: rules(keep: keep, pan: .keep))
        #expect(kept.center == (keep ? CGPoint(x: 0.2, y: 0.7) : CGPoint(x: 0.5, y: 0.5)), "keep \(keep)")
        let centred = PhotoSwitchView.next(current: zoomedIn(), imageSize: newSize, rules: rules(keep: keep, pan: .center))
        #expect(centred.center == CGPoint(x: 0.5, y: 0.5), "keep \(keep)")
        let subject = PhotoSwitchView.next(current: zoomedIn(), imageSize: tall, rules: rules(keep: keep, pan: .subject))
        #expect(subject.center == CGPoint(x: 0.5, y: 0), "keep \(keep)")
        let wide = PhotoSwitchView.next(current: zoomedIn(), imageSize: CGSize(width: 3000, height: 1000),
                                        rules: rules(keep: keep, pan: .subject))
        #expect(wide.center == CGPoint(x: 0.5, y: 0.5), "keep \(keep)")
    }
}
```

With `keep: false` and `pan: .keep` there is no centre to keep (the photo opens anew): centred, as today.

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/test.sh --filter PhotoSwitchViewTests`
Expected: FAIL (`pan:` unknown / centres differ).

- [ ] **Step 3: Implement**

In `next`, after the zoom is decided (both branches), set `t.center` by `rules.pan`: `.keep` leaves it (centred when
not kept), `.center` → `(0.5, 0.5)`, `.subject` → `fallbackCentre(imageSize:viewSize:)`. "Taller than the view's
shape": `imageSize.height / imageSize.width > viewSize.height / viewSize.width`. Update the doc comments of `next`
and `ZoomRules.keep` (it keeps the zoom only).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LoupeCore/PhotoSwitchView.swift Sources/LoupeCore/ZoomRules.swift Tests/LoupeCoreTests/PhotoSwitchViewTests.swift
git commit -m "step-pan on every step: keep, centre, or the subject's fallback (the top of a tall photo) until stage 2 finds subjects"
```

### Task 4: The app — resize carry, the status's `Screen` text, the Settings window, the menu, the user's file

**Files:**
- Modify: `Sources/Loupe/ViewerSession.swift:176` (`resizeKeepsScale` → `var resizeCarry: ZoomCarry`)
- Modify: `Sources/Loupe/ViewerView.swift:1690`
- Modify: `Sources/LoupeCore/StatsLine.swift:197-213` (`modeText`), `Sources/LoupeCore/ImageStatus.swift:101`
  (`facts(…)` takes `carry: ZoomCarry = .share`), `Sources/Loupe/ViewerSession+Status.swift` (passes the folder's
  carry), `Sources/Loupe/FactsRowView.swift` (the zoom sample stays `"Fit height 100 %"`, the longest)
- Modify: `Sources/LoupeSettings/Pages/PageZoomPan.swift:25-30`, `Sources/Loupe/Settings.swift:308-309,426`
- Modify: `~/.config/loupe/loupe.conf` (comments of `keep-zoom-as`, a new `step-pan` block after it; values unchanged
  except the new line `step-pan=subject`)
- Test: `Tests/LoupeCoreTests/StatsLineTests.swift` (or where `modeText` is tested), `Tests/LoupeSettingsTests`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `StatsLine.modeText(_ transform: ViewTransform, carry: ZoomCarry = .share) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func modeTextNamesTheScreenShare() {
    // 1000×1000 in 2000×1000 at .free(1.2): scale 1.2, 1200×1000 on screen after clipping, 60 % of the view.
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 2000, height: 1000),
                          mode: .free(1.2))
    #expect(StatsLine.modeText(t, carry: .screen) == "Screen 60 %")
    #expect(StatsLine.modeText(t) == "Zoom 120 %")
    #expect(StatsLine.modeText(t.withMode(.fit), carry: .screen) == "Fit 100 %")
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/test.sh --filter modeTextNamesTheScreenShare`. Expected: build failure (`carry:`).

- [ ] **Step 3: Implement**

`modeText`: under `carry == .screen` a `.free` mode reads `"Screen \(percentText(screenShare * 100)) %"`; everything
else unchanged. Session: `resizeCarry` is `zoomRules(current).carry`; `ViewerView` passes it to `withViewSize(_:carry:)`.
Settings page: `keep-zoom-as` choice gets `(word: "screen", title: "Share of the screen")`, its description adds
"Screen: the next photo covers as much of the window, cut where its shape needs." and `K` cycles; a new `.choice(
"step-pan", "After a step", [subject "The subject", keep "The same place", center "The centre"])` row after it,
symbol `"scope"`, description: "Where the view lands when the next photo does not fit: on its subject (until subjects
are found: the top of a tall photo, else the centre), at the same place, or in the middle. Default The subject."
Menu: `Keep Scale Instead of Share` becomes `Next Zoom Keeping (Share, Scale, Screen)` without a check state (the toast
says which). User's loupe.conf: Russian comments in the file's style for `screen` and the new `step-pan` block.

- [ ] **Step 4: Verify**

Run: `scripts/test.sh`. Expected: PASS. Then `scripts/make-app.sh` and by hand, in a folder of mixed portrait and
landscape photos with `keep-zoom-as=screen`: pinch a landscape photo to fill most of the window, step to a portrait
one: it covers the same share (the stats bar's zoom slot reads the same `Screen NN %`), its top on screen; press `W`
(Fit Width), step: the next opens at Fit Width; resize the window: the share stays.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "The screen's share in the app: kept over a resize, Screen NN % in the status, Settings' Share of the screen and After a step, the menu's zoom keeping cycles"
```
