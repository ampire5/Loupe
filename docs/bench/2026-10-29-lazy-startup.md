# Lazy inspector creation and startup audit

## What changed

A hidden File View inspector is now a one-shot factory registered with HomeScreenKit. Registration exposes the toolbar button without allocating BrowserInspectorController, its loader, its initial AppKit controls, or an inspector split item. The first visible request constructs and installs it. Subsequent hide/show and Home/viewer transitions retain the same controller and controls. If an inspector was visibly open at the previous quit, restoring that visible state legitimately constructs it during startup. A visibility request while Home is parked waits until unpark, and can be cancelled without construction.

Loupe's selection/activity/settings callbacks only access an existing optional controller. The first construction takes the selection currently in the browser, so selections made before opening are not replayed or read.

## Measurement

MacBook Pro / Apple M4 Max, 14 physical cores (10 performance + 4 efficiency), 36 GB RAM, macOS 27; debug build. `LoupeBench inspector --startup --eager` preserves the old direct-construction path for comparison; `--startup` uses the factory. These are separate processes using the same binary, a real 1160 × 820 pt native Home window and a synthetic 1000-file listing. There are no metadata or user-file reads in the startup comparison. Times are main-thread CPU (`CLOCK_THREAD_CPUTIME_ID`), including layout and bounded run-loop settling.

```sh
source scripts/libjxl-env.sh
swift build --jobs 4 --triple "$DEPS_TRIPLE" --product LoupeBench
.build/debug/LoupeBench inspector --startup --eager
.build/debug/LoupeBench inspector --startup
.build/debug/LoupeBench inspector
```

| Path / round | Hidden Home CPU ms | Inspector registration CPU ms | Controllers before first show | Native inspector view loaded |
| --- | ---: | ---: | ---: | --- |
| Eager / 1 | 169.858 | 2.181 | 1 | no |
| Eager / 2 | 105.616 | 1.773 | 1 | no |
| Eager / 3 | 99.049 | 1.347 | 1 | no |
| Lazy / 1 | 158.913 | 0.004 | 0 | no |
| Lazy / 2 | 97.261 | 0.004 | 0 | no |
| Lazy / 3 | 97.525 | 0.004 | 0 | no |

The directly measured removed registration work is about 1–2 ms in this run. The whole-Home columns also include AppKit startup, toolbar/layout and scheduling variation; they do not establish an exact saving for a cold application launch. The earlier inspector report's 107–112 ms was construction plus first **visible** layout and populated metadata UI, not an extra 112 ms for starting with the inspector closed. Even the former eager implementation deferred its native `loadView`, but constructed the controller, initial controls and split item.

In the new startup comparison first show (with metadata disabled) was 63.519, 51.082, 51.403 ms CPU; the old path measured 46.196, 38.008, 37.234 ms. This makes the tradeoff visible: deferred object installation moves some work to the first request. Every path reported exactly one controller after reopening.

The separate populated-inspector run through the new factory measured first open 104.212 ms (registration 0.056, materialization 17.345, layout/display 33.328, subsequent run-loop work 53.484). Its selection medians were 9.303 / 9.948 / 9.930 ms over three rounds, with maxima 15.057 / 13.473 / 11.518 ms. Reopen medians were 17.394 / 20.183 / 21.187 ms, maxima 19.408 / 20.436 / 23.022 ms. This is evidence of reusing the UI, not of eliminating first-use work or meeting the budget on Intel.

A separate 1 ms `sample` of the eager startup path showed main-thread AppKit toolbar layout (`NSToolbarView layout`, `_layoutDirtyItemViewersAndTileToolbarAndRecalculateKeyViewLoop:`, `_layoutItems:withAttributes:supportsGlass:`) and mostly waiting. Its largest non-wait self stacks were runtime method lookup / dispatch. It does not isolate the roughly 2 ms controller registration with enough samples to assign reliable per-symbol costs. No speculative changes to unrelated UI followed from it.

## Other opportunities found in the code

These are audited allocation paths, not measured speedup claims. They remain unchanged in this task.

| Priority | Candidate and evidence | Possible lazy boundary | What must be preserved |
| --- | --- | --- | --- |
| Higher | `ViewerWindowController` declares `viewerToolbar` lazy but forces `viewerToolbar.nsToolbar` in its initializer. `ViewerToolbarController.init` makes every item, status view, segmented control and slider, even if this window starts on Home. | Construct the viewer's toolbar contents on first entry to the photo viewer. | Native toolbar identity / full-screen hosting, menu state and session updates must not accidentally force creation. The shared toolbar wrapper is still needed for Home. |
| Higher, smaller scope | `ViewerToolbarController.make` constructs Zoom Options and Scaling menus. `Settings.makeScalingMenu` calls `menuNeedsUpdate(menu)` before any opening, populating its filter sections. Zoom Options also builds its static choice groups immediately. | Keep a light menu shell and fill/cache contents on first menu opening. | Shortcuts, enabled state, current-folder checkmarks and changing settings remain correct. Some dynamic submenu filling already happens on demand. |
| Medium | `ViewerSlotsController.init` eagerly creates `FolderStripController`; that constructor creates its surface, rows view and card view and attaches them, even before the neighbouring-folders pane is revealed. | Create the folder-strip UI from the slot's first page factory; keep only lightweight source/state before then. | Session synchronization and pending folder choice, gallery navigation and visibility cancellation must stay independent of the view. A retained page must not be rebuilt on reopening. |
| Lower | `CheatSheetView.init` creates its glass and scrim while hidden; `ConfigWarningsOverlay.init` creates glass and an empty stack even when there are no warnings. | Create these visual shells at first use, retain afterward. | Overlay z-order, keyboard routing, accessibility, warnings and their stop conditions. The cheat sheet's large text content is already lazy, so do not confuse a small shell allocation with its full content. |

Already deferred: Home itself until first browser display; InfoPanelKit's actual photo-info view and field editor; SmartZoom page via the slot factory; the settings window until requested; Stash's WebKit page until Stash is opened; cheat-sheet text until visible layout; thumbnail/metadata work until demanded. `PhotosLibrary.shared` currently has an empty initializer, and authorization/album reads happen on requests, so deferring that empty facade would not meaningfully optimize startup.

## Verification and integration

- New native regressions failed before `configureInspector` existed, then passed: untouched factory during hidden layout and parking, first toolbar request creates once, hide/reopen retains it, parked visibility intent can be cancelled, unpark honors visible restore, first construction sees the latest selection.
- Existing native selection, late-fact, divider-collapse and parking regressions still pass.
- Full HomeScreenKit: 676 tests across eight test products, all passed. Loupe: 2206 core, 63 settings and 6 native integration tests, all passed. No render code changed in this follow-up.
- Independent scoped review found no important lifecycle defects. `git diff --check` is clean.
- App and modified kit use `polish-3`; existing dirty work was preserved. HomeScreenKit remains in the pre-existing SwiftPM edit mode. Its combined branch must be released and pinned by tag before distribution; this task does not publish or merge it.
- Intel timing is unverified. The missing user glass guide was not replaced by invented motion or material changes.
