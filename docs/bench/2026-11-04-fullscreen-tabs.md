# Stable full-screen tabs

The native tab bar is a bottom titlebar accessory. The real two-tab probe on
Apple M4 Max (14 physical cores), macOS 27.2/arm64 reported a 36 pt view and `fullScreenMinHeight == 36` even
while the toolbar had independent auto-hiding. Thus the tabs could remain
visible separately and move when the toolbar appeared above them. Pointer
motion reproducing the intermittent original report has not been automated.

`fullscreen-tabs=shown|auto` is exposed in Interface → Full Screen → Tabs.
Shown is the default: when the native tab bar is visible, keep the whole
native header expanded so the tabs do not move between collapsed and expanded
positions. Auto uses a zero fullscreen accessory minimum and native toolbar
auto-hiding together. This uses the documented
[fullScreenMinHeight](https://developer.apple.com/documentation/appkit/nstitlebaraccessoryviewcontroller/fullscreenminheight)
property; no private tab view classes, pointer monitors or polling are added.

B temporarily overrides pinning. Explicit toolbar hiding with ⌥⌘T still wins
over automatic tab pinning and does not change windowed pinning on fullscreen
exit. Changing the tab setting clears the temporary B
override. Layout and selected-tab changes reconcile the header; stats layout
is refreshed only when the effective pin state changes. Layout-triggered work
coalesces into one deferred main-queue update and checks close/fullscreen-exit
state before touching chrome. Windowed reveal is
unchanged. Leaving full screen restores the accessory's native visible height.

Validation: the config default/parser test first failed because the key did
not exist, then passed. Existing key enumeration and settings coverage tests
were updated for the additional choice and its unique SF Symbol. The normal
test script passed 2,276 core tests (7 skipped), together with its app and
settings target runs. A prior full run caught those three fixture updates,
and also timing failures in `windowedToolbarRevealsHidesAndStopsWhenDisabled`,
`hungResolveTimesOut` and `hungLocalDiskTimesOut`; the isolated full rerun
passed. Intel has not been measured.

Subsequent parallel runs also intermittently failed the unrelated
`quickCompletionCancelsDelayedPending` timing check. The final
`scripts/test.sh --no-parallel` run passed all app/settings runs and all 2,276
core tests (7 skipped, 57 s for core), avoiding concurrent UI/timer interference.

The native two-tab probe checks shown header
reservation, duplicate-stats suppression, actual fullscreen summary centring,
preserved native tab height, B auto-hide override, zero tab accessory minimum
in auto mode, ⌥⌘T hide/restore with shown tabs, and live return to the shown
policy. A review caught ⌥⌘T being masked by the tab policy; its new native
regression failed before automatic pinning was made conditional on toolbar
enablement. This preserves the original windowed override state.

That same native shortcut test caught an AppKit exception from showing/hiding
toolbar hierarchy inside `ViewerContainerView.layout`. The crash backtrace
pointed to `applyFullScreenToolbar` through the layout callback. Moving the
coalesced reconciliation outside the layout pass addresses that specific
reentrancy; the toolbar state itself remains reconciled on native tab changes.

The explicit hide regression then measured `toolbar.isVisible == true` even
with a zero safe-area inset and zero accessory minimum. Enabling AppKit's
native auto-hide had restored the toolbar's enabled flag. Explicit requested
visibility is now applied after that native policy operation. Deferred work
and policy application also skip inactive native tabs, so an inactive Home tab
cannot re-pin the active viewer's shared chrome.

Final native probe: all 83 checks passed, including ⌥⌘T hide/restore and an
auto-hidden viewer → pinned Recent → auto-hidden viewer round trip. The
exception did not recur in this full probe.

The final probe's synchronous action portions used 1.05/0.66 ms of main-thread
CPU for B pin/unpin, 4.32–4.89 ms for viewer returns, and 108.79/16.80/24.09 ms
for Home visits. These exclude deferred reconciliation and animation waits;
they do not establish end-to-end action latency. Cold Home construction still
exceeds the 100 ms navigation budget and remains outside this change.
