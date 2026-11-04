# Restore the viewer's Pro Camera summary

Commit `3ba97f4` replaced the summary's `ChromeGlass` with a plain view and
changed its Pro Camera palette to system label colors. Restore the original
light over-media glass, 12 pt corners, rim and light-on-dark palette. Keep the
native toolbar backdrop and existing retained controls.

Use AppKit's `centeredItemIdentifiers` for the summary, relative to the window
when space permits. Narrow windows keep the existing compact layouts and
visibility priorities. A native window regression checks the actual summary
centre at 3,000 pt, as well as visibility down to the 320 pt minimum.

Validation on the local arm64 Mac, macOS 27.2:

- The appearance regression failed before restoration because no `ChromeGlass`
  existed, then passed. The 12 summary tests passed.
- `LOUPE_STATUS_BENCH=1 scripts/test.sh` passed 2,275 tests (6 skipped), including
  ten rounds of real-window updates, resizes and popovers. Native snapshots at
  1,280 and 3,000 pt were inspected; the rounded summary is visible and the
  summary is centred in the wide window.
- The final ordinary `scripts/test.sh` passed 2,275 tests (7 skipped).
  An earlier run overlapped a separate full-screen UI probe and failed
  `WindowToolbarRevealTests.windowedToolbarRevealsHidesAndStopsWhenDisabled`;
  the isolated full rerun passed.
- The native toolbar probe passed all 72 checks, including three Home/viewer
  round trips and a viewer beside a Recent tab in windowed and full-screen
  modes. Geometry checks wait for the system titlebar animation to finish:
  attachment alone can expose an intermediate frame with a doubled leading
  offset. A persistent sidebar-sized left gutter was not reproduced. No
  speculative Home parking change is included.
- The final probe measured viewer returns at 4.28–4.97 ms of main-thread CPU;
  Home first visit was 113.55 ms and returns were 8.46–9.50 ms. The first Home
  visit exceeds the 100 ms navigation budget; that existing cold construction
  path is outside this appearance change. Intel has not been measured.

Intel performance and the originally reported persistent left gutter remain
unverified. This change restores the summary appearance and native centring.
