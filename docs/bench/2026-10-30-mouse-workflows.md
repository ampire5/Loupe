# Mouse workflows and toolbar pinning verification

2026-10-30, Apple M4 Max development Mac, macOS 27.2 (26B123), debug build. CPU measurements use `CLOCK_THREAD_CPUTIME_ID` through ThreadCPU; these are main-thread CPU times, not fullscreen animation durations. No Intel hardware was available, so the slowest-supported-machine budget remains unverified.

## Standard verification

`source scripts/libjxl-env.sh` then `scripts/test.sh`, exit 0 after the final functional edits:

- Loupe app: 28 tests passed.
- Settings: 63 tests passed.
- Render smoke: 3 tests passed.
- Core: 2240 tests passed, 7 skipped.
- `git diff --check`: clean.

App tests exercise real ViewerView manual commands, SmartZoom revision invalidation, RMB modifier/colour input retaining pending framing, lost RMB-up recovery, native toolbar mode items and windowed reveal lifecycle. Pure tests cover reverse group/profile cycling, unavailable models, per-profile group retention, input parsing and modified wheel release order/channel retention/momentum, and release-only Gesture clicks. Existing SmartZoomArrival tests cover same-photo cancellation and rearming on the next photo.

## Native window bench

`swift build -c debug --triple "$DEPS_TRIPLE" --product Loupe`, then `.build/out/Products/Debug/Loupe --native-toolbar-bench`: all checks passed. It opens a real empty app window, with a disposable browser fixture and configuration. Preference mutations are restored before exit.

| Action | Main-thread CPU |
| --- | ---: |
| B pin fullscreen toolbar | 0.943 ms |
| B unpin fullscreen toolbar | 0.602 ms |
| Home visits, rounds 1 / 2 / 3 | 50.754 / 45.946 / 47.546 ms |
| Viewer returns, rounds 1 / 2 / 3 | 6.539 / 37.434 / 37.069 ms |
| Native sort selection | 1.299 ms |

Checks include native auto-hide acceptance, fullscreen toolbar host, pin safe-area reservation, stats suppression and accurate menu checkmark, preference restoration on unpin, three Home/viewer rounds, sort, explicit toolbar enable/disable, direct Home fullscreen entry, and explicit B pin surviving two fullscreen entries even with fullscreen-toolbar configured hidden.

The bench exposed an initial policy bug: default windowed visibility was mistaken for an explicit fullscreen pin. The delegate now uses the explicit pin override. The corrected native run passed. No processing-interval or parallelism constants were changed.

## Boundaries

Physical MX 4 ergonomics and driver-generated gesture events still need a hands-on pass. No system input was posted by tests. Folder scrolling reuses the existing configurable repeat throttle and in-flight request rejection, dropping excess input rather than buffering it. LMB movement remains unchanged.

Fullscreen keeps the existing guarded private AppKit pin/autohide selectors. This work adds no private API; it cannot claim the entire toolbar implementation is free of compatibility compromises. Windowed reveal uses public AppKit events and a cancellable delayed hide, with no polling. No final app packaging or installation was performed here; the inspector integration session owns that step.

## RMB gesture correction

After physical hardware feedback, removed the inaccessible RMB+Panel default commands. Restored vertical RMB drag while retaining RMB wheel/button combinations: suppression now begins on actual modifier use, not the initial press. Consumed modifier wheels clear the pending drag. LMB panning is unchanged.

Red phase: new recognizer regression failed three assertions on the previous code. Green phase: actual ViewerView synthetic down/drag/up events change scale, retain SmartZoom, invalidate late requests on movement, and do not restart drag after wheel use. Tests construct events without posting system input.

Final `scripts/test.sh` exit 0: app 29, settings 63, render smoke 3, core 2245 passed (7 skipped). `git diff --check` clean. No new release installation was performed. Final user choice: Panel long press toggles Vibrance; RMB+middle stays Fit Width; strength stays in the toolbar. No thumb-wheel adjustment assigned.

Final commit mapping check: the user restored Vibrance to Panel long press (on release), leaving RMB+middle as Fit Width and strength in the toolbar. The isolated input package rerun passed 136 tests, including actual standard binding recognition and wheel use cancelling the pending Panel long action. No shared build was used for this final mapping-only change; the preceding full app/native verification remains recorded above.
