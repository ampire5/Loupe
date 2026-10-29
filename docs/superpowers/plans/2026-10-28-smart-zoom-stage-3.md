# Smart zoom, stage 3: Zoom to Subject, `zoom-anchor`, the toolbar menu and the keys — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a Zoom to Subject command (key, menu, toolbar) that frames the photo's subject and carries to the next photos;
gesture zoom that can anchor at the pointer, the centre or the subject; the toolbar's zoom menu as the panel for all of
smart zoom; keys to cycle and save each setting.

**Architecture:** The scale is pure (`SubjectFraming.scale`), the mode is a session flag (`subjectZoom`) over a `.free`
transform rather than a new `ZoomMode` case (every switch over `ZoomMode` would otherwise grow one): the flag carries
across steps as a named mode does, any other zoom command or gesture clears it. The anchor is resolved in `ViewerView`
where gestures already pass the pointer. Menus and keys write folder settings as `K` does.

**Tech Stack:** Swift 6, AppKit (NSMenu, NSToolbar), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-28-smart-zoom-design.md` §3, §3.1, §3.2, §4 (the scale), §6 rows
`subject-size` and `zoom-anchor`.

## Global Constraints

- `subject-size` 20…100 (%), default 60: the frame's height or width, whichever binds, takes that share of the view's;
  never smaller than Fit, never past the zoom's upper limit.
- `zoom-anchor` = `pointer` (default) | `center` | `subject`, a folder key; `subject` falls back to the pointer until
  the boxes are in. `zoom-at-pointer` keeps its meaning for all three.
- Zoom to Subject: first press zooms (animated) to the frame, second press goes back to the view before; active, it
  carries to the next photo; any other zoom command or gesture leaves it; no subject → stays (Fit), toast
  `No subject`; status `Subject NN %`; `.userInitiated` for the analysis it waits for.
- Keys: `Shift+z` zoom to subject; `Alt+k` / `Alt+Shift+k` cycle / save `step-pan`; `Alt+z` / `Alt+Shift+z` cycle /
  save `zoom-anchor`; `k` / `Shift+k` as today.
- Toolbar: a *Zoom to Subject* button in the zoom block (symbol `person.crop.rectangle`), lit while active; the zoom
  options menu gets the five groups of spec §3.2 with the current choice ticked, choices written for the folder.

## Review Focus

1. Zoom to Subject pressed before the boxes are in: waits for them (`.userInitiated`) and zooms when they come, unless
   the user did something else meanwhile; no double zoom when pressed twice quickly.
2. Subject mode on and a step to a photo whose boxes are unknown: opens at Fit (not at the old scale), then glides to
   the subject within the glide window.
3. `zoom-anchor=subject` on a photo without boxes: anchors at the pointer exactly as before, no jump.
4. The toolbar menu's ticks follow a change made by a key in the same or another window.
5. A spread (two pages): Zoom to Subject uses the first page's boxes or does nothing; never a crash.

---

### Task 1: Settings and the scale (LoupeCore)

**Files:** `Sources/LoupeCore/Config.swift`, `Sources/LoupeCore/SubjectFraming.swift`, `Sources/LoupeCore/ZoomRules.swift`,
`Sources/LoupeCore/ZoomKeys.swift`, `Sources/LoupeSettings/Pages/PageZoomPan.swift`; tests `ConfigTests`,
`SubjectFramingTests`, `ZoomKeysTests`, `PagesTests` (147 → 149).

**Interfaces — produces:** `public enum ZoomAnchor: String, Sendable { case pointer, center, subject }`;
`Config.zoomAnchor = .pointer` (key `zoom-anchor` after `zoom-at-pointer`, in `zoomFolderKeys`); `Config.subjectSize = 60`
(key `subject-size` after `subject-target`, 20…100); `ZoomRules.anchor`, `ZoomRules.subjectSize`;
`SubjectFraming.scale(frame: CGRect, size: Double, imageSize: CGSize, viewSize: CGSize, limits: ClosedRange<Double>,
fit: Double) -> Double` (`size` 0.2…1; frame normalised); `ZoomKeys.toggledPan(_:) -> StepPan` (subject → keep →
center → subject), `toggledAnchor(_:) -> ZoomAnchor` (pointer → center → subject → pointer), `panKey = "step-pan"`,
`anchorKey = "zoom-anchor"`, `toast(pan:)` "After a step: the subject · folder" / "the same place" / "the centre",
`toast(anchor:)` "Zoom towards: the pointer · folder" / "the centre" / "the subject", `panSaved`, `anchorSaved`.

- [ ] Tests first: `zoomAnchorAndSubjectSizeParse` (values, bad values `"mouse"`, `"10"`, `"101"`, texts back,
  folder key); `subjectScaleTakesTheSizeOfTheView` (1000×1000 image, 2000×1000 view, frame (0.4, 0.4, 0.2, 0.2),
  size 0.6: the frame's 200 px height becomes 600 px → scale 3; a frame of the whole image → Fit (1); size 1 with a
  tiny frame clamps at `limits.upperBound`); `stepPanAndAnchorKeysCycle` (cycles and toasts above).
- [ ] Watch them fail; implement; `scripts/test.sh`; commit "zoom-anchor, subject-size, the subject's scale, the keys'
  cycles".

### Task 2: Zoom to Subject in the session and the view

**Files:** `Sources/LoupeCore/KeyMap.swift` (actions `zoomSubject`, `cycleStepPan`, `saveStepPan`, `cycleZoomAnchor`,
`saveZoomAnchor`, built-in bindings above, cheat-sheet titles), `Sources/LoupeCore/InputConfTemplate.swift` (the
lines), `Sources/Loupe/ViewerSession.swift` (`var subjectZoom: Bool`, cleared by `withMode`-style commands and gestures),
`Sources/Loupe/ViewerView.swift` (the command, the anchor), `Sources/Loupe/ViewerWindowController.swift` (the keys,
the finder's `.userInitiated` request), `Sources/Loupe/SubjectFinder.swift` (`urgent` request), `Sources/LoupeCore/
StatsLine.swift` (`Subject NN %`), `Sources/LoupeCore/PhotoSwitchView.swift` (subject mode on a step).

**Interfaces — produces:** `PhotoSwitchView.subjectTransform(_ t: ViewTransform, boxes: SubjectBoxes, rules: ZoomRules)
-> ViewTransform?` (nil when no kind of the chain is found: `.free(scale / fitScale)` at the frame's centre);
`StatsLine.modeText(_:carry:subject:)` with `subject: Bool = false` → `"Subject NN %"` for a free zoom.

- [ ] Tests first (LoupeCore): `subjectTransformFramesTheSubject` (the example of Task 1 through `subjectTransform`:
  scale 3, centre (0.5, 0.5); no faces with chain `[.face]` → nil); `modeTextNamesSubjectZoom`; `keyMapBindsSmartZoomKeys`
  (`Shift+z`, `Alt+k`, `Alt+Shift+k`, `Alt+z`, `Alt+Shift+z` → the actions; the template's lines parse back).
- [ ] Watch them fail; implement. In the app: `zoomSubject` toggles; on: remember the transform before, ask the
  finder for the photo on screen urgently, animate to `subjectTransform` when boxes are known (now or on arrival, if
  the user did nothing else since the press), else toast `No subject`; off: animate back. A step with `subjectZoom`
  on uses `subjectTransform` when the boxes are known, else Fit and the glide (stage 2's, with the scale too). Gesture
  handlers and the other zoom commands clear `subjectZoom`. `zoom-anchor`: the gesture's anchor point is the pointer,
  the view's centre, or `viewPoint(forImage:)` of the frame's centre (pointer when no boxes).
- [ ] `scripts/test.sh`; `scripts/make-app.sh`; by hand in a copy of the app with its own bundle id
  (scratchpad `testapp.sh`) on fresh copies of portraits: `⇧Z` frames the head, a step keeps framing, `⇧Z` again
  goes back; `⌥Z` to subject, a pinch-like `=` zooms towards the face. Commit "Zoom to Subject (⇧Z) and zoom-anchor".

### Task 3: The toolbar and the menu

**Files:** `Sources/Loupe/ViewerToolbarController.swift` (the button in the zoom block, lit by the session's
`subjectZoom`), `Sources/Loupe/Settings.swift` (`makeZoomMenu`: the five groups as radio items, tagged with key and
value; their states from the effective config in `menuNeedsUpdate`/`validate`; a "Save as Default" item),
`Sources/Loupe/ViewerWindowController.swift` (`setFolderValue(_ key: String, _ value: String)` for the menu's items,
shared with the keys' code paths; the status refreshed as for `K`).

- [ ] Test first where it is pure: `Settings`'s menu model if one exists in LoupeSettings/LoupeCore; otherwise a
  `SmartZoomMenuTests` over a pure description of the groups (`SmartZoomMenu.groups: [(title, key, [(title, value)])]`
  in LoupeCore, which `makeZoomMenu` renders) checking the five groups, their keys, values and titles.
- [ ] Implement; `scripts/test.sh`; by hand: the menu's ticks match the folder's values; choosing an item changes the
  behaviour and the toast/status; the button lights with `⇧Z`. Screenshot the menu (window capture). Commit "The
  toolbar's smart zoom: Zoom to Subject button, the zoom menu's five groups".
- [ ] The owner's loupe.conf: comments for `zoom-anchor` and `subject-size` (Russian, the file's style), values at
  their defaults; no other value changed.
