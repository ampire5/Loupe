# Photos-style full-screen toolbar

## Reference investigation

Inspected the installed Photos on macOS 27.0.1 on 2026-10-30, on an Apple M4 Max
with 14 physical CPU cores and a 3072 × 1728-point display. Accessibility
identifies a native toolbar in both the library grid and single-photo view.
Static Objective-C metadata and ARM64 disassembly show:

- `IPXWorkspaceController` selects visibility from the active controller's
  `prefersSidebarAndToolbarHiddenInFullscreenWindowMode` preference.
- `IPXOneUpSourceController` returns true for that preference.
- `IPXMainWindowController` adds `NSApplicationPresentationAutoHideToolbar`
  (0x800) to its proposed options when the workspace requests autohiding.
- `setToolbarHiddenInFullScreen:` forwards to the window's UXKit category.

Loaded the installed UXKit in a standalone diagnostic process, without loading
a photo library. LLDB disassembly of
`-[NSWindow(UXKit) ux_setToolbarHiddenInFullScreen:]` shows that it stores the
preference and, when already full screen, sends one of these selectors to the
window's existing toolbar:

- `_disableFullScreenAutohiding` for the library/grid;
- `_enableFullScreenAutohiding` for single-photo viewing.

This changes the native toolbar's policy rather than its `isVisible` property.
There is no duplicate content toolbar or custom screen-edge reveal in this path.

## Isolated AppKit experiment

A native full-screen window with a unified toolbar and a retained custom label
was used to compare switching approaches. With the public application-wide
`presentationOptions` setter, changes did not switch the existing toolbar's
safe-area reservation. The per-toolbar calls used by Photos did:

| Native toolbar state | Content top safe area | First item x in host |
| --- | ---: | ---: |
| Auto-hide after entry | 0 pt | 94 pt |
| Pinned using the Photos call | 66 pt | 94 pt |
| Auto-hide restored using the Photos call | 0 pt | 94 pt |

The toolbar object and its native full-screen host stayed the same. These calls
are private AppKit selectors: any application use must be isolated and checked
with `responds(to:)`. When either selector is absent, the public delegate policy preserves native
autohiding for both modes; persistent Home pinning is unavailable on that system. No UXKit dependency is needed by the app.

## Verification

The real-window integration bench was first run with the policy switch disabled:
all three Home safe-area checks failed. With the switch enabled, all three
passed, and the viewer restored a zero top inset. The toolbar object and native
host survived all transitions. The existing toolbar shortcut and native sort
also passed.

A longer display probe exposed a separate HomeScreenKit layout invalidation:
`pageTop?.constant != inset` is true when `pageTop` is absent. Consequently,
every layout scheduled another layout even if the toolbar inset was unchanged.
`HomeBrowserLayoutTests.unchangedToolbarInsetDoesNotScheduleAnotherLayoutWithoutCustomPage`
failed before the fix and passed after checking only an existing page constraint.

The controlled real-window bench also passed full-screen exit, a second entry
directly from Home, viewer autohiding after that entry, and repinning Home.

| Round | Show Home, main-thread CPU | Return to viewer, main-thread CPU |
| --- | ---: | ---: |
| First | 47.058 ms | 38.264 ms |
| Return 1 | 40.659 ms | 35.065 ms |
| Return 2 | 37.516 ms | 33.411 ms |

The native sort action took 0.476 ms. These are debug-build measurements using
`CLOCK_THREAD_CPUTIME_ID`, excluding native transition waits. All measured
actions are below the 100 ms navigation budget on this Mac; Intel remains
unmeasured. Other toolbar work was present in the shared working tree, so these
are not a controlled before/after comparison with the previous day's build.

All 677 HomeScreenKit tests passed after the inset fix.

### Fixture correction

The original extended bench browsed its configuration scratch folder under
`NSTemporaryDirectory`. This host's temporary directory contained 26,075 immediate
subdirectories. Following the path expanded that ancestor in the sidebar.
A one-second sample taken after the stall began put all 666 main-thread samples
in `HomeView.listingComplete → showTree → HomeSidebar.rebuild`; 569 were in
`SidebarLineView` allocation, 97 in attaching views. Footprint was 1.2 GB.
The later AutoLayout memory exception did not establish a toolbar-state defect.

The browser fixture now lives under the workspace's ignored `build` directory;
the scratch directory is used only for configuration and reports. With this
fixture, the complete repeated-entry bench passes. No timing or native-host
workaround was required. Large sidebar virtualization is a separate pre-existing
issue, outside this toolbar change.

A native full-screen Home screenshot confirmed the pinned system toolbar and
window controls. The extended pointer-reveal automation could not be completed:
computer-use coordinate actions reported no eligible window, and the tool was
subsequently unavailable. Static zero-drift samples are not evidence of reveal
behavior, so no animation or hide-delay claim is made from those samples.
Pointer-driven reveal remains a manual validation item for the test build.
The interactive diagnostic sampler was removed; the repeatable state bench remains.

### Final integration run

The standard `scripts/test.sh` run completed successfully: LoupeTests 21 tests,
LoupeSettingsTests 63 tests, and LoupeCoreTests 2,211 tests (7 skips reported by
the runner). An earlier combined run exposed native toolbar-family insertion
synchronization across windows with the same identifier. Window toolbar
identifiers are now unique per controller; each window still retains its one
toolbar for its entire lifetime. The final combined run and the repeated-entry
window bench both passed.

The test bundle is labelled `Photos Toolbar`. Private selector availability
and actual pointer-reveal behavior on Intel have not been verified.

## Titlebar backdrop regression

A reported rectangular patch beside the browser toolbar corresponded to the
full-screen host's split titlebar backdrop. Home inherited
`titlebarAppearsTransparent = true` from the photo viewer. Native-host snapshots
with a 500 pt sidebar contained an opaque rectangle starting at x=500 pt,
52 pt high. The sidebar and browser used separate backdrop paths.

Home now selects AppKit's standard titlebar backdrop
(`titlebarAppearsTransparent = false`); the photo viewer continues to restore
transparency in `hideHome`. No system view frames or private background layers
are patched. The native pin/autohide policy and retained toolbar stay intact.

The real-window bench first failed its Home backdrop checks in all three
rounds and on direct Home entry. With the appearance switch, all pass; the
viewer transparency checks pass on each return.

Own-window snapshots covered sidebar widths 236, 321, 500, then 321 pt and a
Home/viewer/Home round trip. At 500 pt, the old host bitmap had alpha 0 at
x=100/320 pt and alpha 1 at x=500/600/750 pt in the top row. The updated
host bitmap has alpha 0 at all five positions: the opaque fill is gone, leaving
the background to AppKit's compositor-managed material. These cached-view
snapshots do not render the compositor's actual glass. They demonstrate removal
of the extra opaque rectangle, rather than full WindowServer visual validation.

Measured main-thread CPU on the same Apple M4 Max, debug build:

| Round | Show Home | Return to viewer |
| --- | ---: | ---: |
| First | 48.469 ms | 5.769 ms |
| Return 1 | 47.293 ms | 42.353 ms |
| Return 2 | 47.988 ms | 38.889 ms |

Sort: 0.460 ms. All measured actions remain within the navigation budget on
this Mac; Intel remains unmeasured. Temporary view-tree/snapshot instrumentation
was removed after diagnosis.

The final standard test run passed (2,211 core tests, 7 skips reported), as did
the repeated-entry native window bench. The signed test bundle is labelled
`Toolbar Backdrop Fix`.

## Transparent backdrop spike

An opt-in transparency spike enabled `NSWindow.titlebarAppearsTransparent`
for Home. It has been removed after the reference investigation below.
The standard backdrop remains selected. No new private methods or system-layer
edits were introduced into production for this experiment.

This is a visual trial, **not a fix for the backdrop regression**. In a real
full-screen probe, transparency reproduced the split opaque patch. Cached host
bitmaps sampled at x=100/240/320/500/700 pt showed alpha 0/0/0/1/1, versus
0/0/0/0/0 for the standard backdrop. Making the main window's background clear,
changing `isOpaque`, mirroring transparency onto the native host, and removing
the toolbar's sidebar tracking separator did not remove the patch. Unified,
unified-compact, automatic and preference styles retained it. Expanded moves
the toolbar onto another row, so its clear top row does not establish a fix
and changes the requested layout. None of those diagnostic changes is kept.

These are cached-view measurements, not a composited-glass appearance check.
The early diagnostic runs entered native full screen successfully. Later full
bench reruns could no longer enter full screen, including the standard-backdrop
control run; waiting for app activation did not resolve that. Consequently this
trial does not have a passing full-screen integration certification. The
existing private pin/autohide selectors remain a compatibility compromise;
using Photos' mechanism does not make those selectors public API.

The attempted trial packaging was interrupted; no transparent trial bundle is
delivered. The stable backdrop-fix bundle remains available separately.


## Photos backdrop implementation investigation

The backdrop was investigated separately from fullscreen autohiding. The live
Photos Library UI exposed individual native toolbar items in both windowed and
fullscreen modes. Attaching LLDB to Photos was denied by macOS; no protection
settings were changed. A full-app screenshot was rejected by automatic review
because it would include personal media, so the user-supplied toolbar crops
remain the visual reference.

Decoded the installed Photos executable and UXKit from the dyld shared cache
using `dyld_info -disassemble`. A separate, disposable AppKit process loaded
UXKit to resolve optimized Objective-C selector stubs and inspect default
window properties; it never opened a Photos library.

Evidence:

- `IPXMainWindowController.initWithWorkspace:` (0x1000062BC) calls
  `UXWindowController.initWithRootViewController:`.
- `+[UXWindowController defaultWindow]` (0x22D064454) allocates `_UXWindow`.
- `-[_UXWindow initWithContentRect:]` (0x22D06449C) uses style mask 0x800f
  (including full-size content), hides the title and sets toolbar style 3
  (`.unified`). It does not enable titlebar transparency.
- The diagnostic process confirmed `titlebarAppearsTransparent == false`,
  `toolbarStyle == .unified`, and the standard window background color.
- With individual NSToolbar items enabled, a standalone UXWindowController
  creates a native `NSToolbar`; its existing toolbar, subtoolbar and extended
  background effect ivars were all nil at inspection. This reproduces the
  framework setup, not a live dump of Photos' private window state.
- UXKit also contains a legacy `toolbarVisualEffectsView` path: it lazily
  creates NSVisualEffectView with `.withinWindow` and `.contentBackground`
  (material 18). The appearance-update code chooses different branches based
  on controller style and detached bars. Finding this code alone does not
  prove it supplies the current Photos Library toolbar background.

The established reference setup therefore retains AppKit's backdrop instead
of requesting a transparent titlebar. Loupe keeps the same public window
configuration. The hypothesis that merely enabling transparency reproduces
Photos is rejected, and the experimental Info.plist switch was removed.

The exact live composited material and any difference in under-toolbar content
between Photos and Loupe are not yet established by this inspection. No claim
of pixel-equivalent glass rendering follows from these window properties.

## Native backdrop-content trial

The requested effect is translucent, blurred material, rather than a clear
window titlebar. A separate trial keeps AppKit's standard unified backdrop and
uses the public macOS 26 `NSBackgroundExtensionView` to extend the browser's
edge content underneath it. This follows Apple's documented background
extension mechanism; the investigation above does **not** establish that
Photos uses this exact component.

HomeScreenKit's `HomeView(source:extendsBrowserBackground:)` adds the extension
only when requested and supported. Other clients keep the ordinary layout.
Loupe opts in. The browser is placed within the safe area, while the extension
fills the area under the toolbar. The sidebar's top inset follows its own safe
area as well, so moving the browser below the toolbar does not move sidebar
rows behind the window controls. The browser and toolbar instances remain
retained. No new private selectors, system view edits, snapshot loops, or
production timers are introduced.

Validation on the Apple M4 Max/macOS 27.0.1:

- All 677 HomeScreenKit workspace tests passed.
- The real-window native toolbar bench passed all checks, including three
  Home/viewer round trips, direct Home fullscreen entry, sort and shortcuts.
- New checks passed in each round: interactive browser content stays below
  the native toolbar and receives no second toolbar safe-area inset.
- Main-thread CPU, Home/viewer: 48.343/6.541, 47.880/42.253,
  42.827/39.861 ms; sort 1.341 ms. Intel is not measured.

A temporary visual fixture contained only generated colored checker cards.
The screenshot tool rejected a full-window capture because the sidebar/path
bar exposed filesystem names. Attempts to hide those through UI automation
produced unchanged accessibility state; the probe later exited on its own.
Consequently the trial has structural and behavioral verification, but no
confirmed composited screenshot or claim of visual equality to Photos.
Temporary visual-hold instrumentation was removed from the source.

The separately signed bundle is `build/Loupe-Glass-Toolbar-Trial.app`, labelled
`Glass Toolbar Trial`. The previously delivered backdrop-fix bundle is retained
for comparison. This is a visual experiment, not a kit release or merge.

## Return destination in the native toolbar

Removed the viewer's separate hover-revealed return capsule, its constraints,
pointer callback and info-panel avoidance band. The retained native Back item
now shows the previous destination label (`Recent`, `Folders`, or `Photos`)
beside its arrow using `NSToolbarItem.title`. Its overflow label and tooltip
include the destination. The destination is updated from session status changes
and Home transitions, without waiting for pointer movement. Existing Back
navigation and keyboard actions are preserved.

`ViewerToolbarBackTests.returnDestinationUpdatesTheRetainedNativeItem` passed,
covering destination changes, item/action retention and clearing/disabling the
item. The test script passed 24 app tests, 63 settings tests, 2 renderer-smoke
tests and 2,211 core tests (7 skipped). The native fullscreen toolbar bench also
passed. No further custom darkening or shadow was added to the background.
The separate signed test bundle is labelled `Toolbar Return Label`.

## Restore workflow-dependent zoom groups

The viewer refactor left Manual presets permanently visible: the earlier
`setZoomSet` had become a no-op, and the SmartZoom group was later removed.
The Manual/SmartZoom switch now selects the corresponding retained native
mode group. Manual shows Fit, 100%, Fit Width, Fit Height and Fill; SmartZoom
shows Subject, Screen Share and Fill on Subject. The existing zoom actions
and workflow semantics are preserved.

Only the mode item is replaced in the window's retained NSToolbar. The source
controller reports the replacement to WindowToolbarController; an inactive
source does not modify the Home toolbar, and its current group is restored
when the viewer returns. Status changes update selection without rebuilding
other toolbar controls or repeatedly replacing the group.

The regression test first failed because the actual window toolbar contained
no SmartZoom mode group. It now passes, covering Manual/SmartZoom round trips,
all three SmartZoom button actions, preservation of the Back item and mode
item instances, a workflow change while Home is active, and exactly one mode
group after return. The full standard test script passed 25 app tests, 63
settings tests, 2 renderer smoke tests and 2,211 core tests (7 skipped). The
native fullscreen toolbar bench passed as well. The separate test bundle is
labelled `Zoom Workflow Restored`.

## Native appearance simplification after hardware/UI feedback

The reported File View screenshots showed recognizable, vertically reflected content behind the toolbar title/subtitle. Loupe enabled HomeView's `NSBackgroundExtensionView` wrapper. The SDK header describes extending edge content outside its safe area beneath titlebar/sidebar/inspector; this is unsuitable for text-heavy browser pages. Loupe now uses the default HomeView initialization without the extension. The kit API remains unchanged for other clients.

The viewer information controls also no longer have their own ChromeGlass layer or forced dark appearance. They inherit the native toolbar appearance and use semantic system label/status colors. Both browser and viewer keep a nontransparent unified titlebar so AppKit provides its standard material backdrop. Navigation, sorting, colour sliders, SmartZoom controls and native fullscreen pin/autohide remain available. Existing guarded fullscreen pin/autohide compatibility selectors are unchanged.

Verification adds a status appearance/material regression and native Home rounds asserting the absence of a background extension under the toolbar. Final verification: `scripts/test.sh` exit 0, 30 app / 63 settings / 3 render-smoke / 2245 core tests passed (7 skipped). Debug product build succeeded. Native fullscreen bench passed all 67 checks, including three browser safe-area rounds and absence of background extension. The old outer-frame assertions assumed the removed wrapper; the bench now checks the browser's actual safeAreaLayoutGuide.frame against the window contentLayoutRect, ensuring one toolbar inset. B pin/unpin main-thread CPU: 0.750/0.406 ms; Home rounds 45.725/44.755/47.347 ms; viewer returns 6.121/39.413/37.419 ms; sort 1.306 ms on the same M4 Max/macOS 27.2 debug setup.

The enabled `nativeWindowBenchAndSnapshot` test passed and generated neutral-fixture snapshots at multiple widths. The 1280 pt native toolbar capture was visually inspected: system backdrop, inherited appearance and no separate information glass panel. This is not a reproduction of the user's private browser data. No new installation was performed by this task.
