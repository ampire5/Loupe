# Full-screen toolbar reveal

Recorded on 2026-10-29: macOS 27.0.1 (26A434), 14 logical processors,
3072 × 1728-point display. Geometry diagnostics recorded no titles, filenames,
or image data. Intel has not been measured.

## Cause

Loupe explicitly removed `.autoHideToolbar` from the full-screen presentation
options and implemented its own screen-edge mouse monitor, calling
`toolbar.isVisible = true` independently from the system's window-control reveal.
The first toolbar platter moved from x=10 to x=96 pt. Intermediate positions
were 15, 25, 44, 54, 73, and 82 pt; first visible sample at 65 ms, final x at
317 ms. Layer presentation/model frames agreed and no layer animation keys
were present: AppKit was updating layout throughout the reveal.

Disabling implicit Core Animation did not fix this (user confirmed).
`.expanded` added a separate window-controls row and was rejected. An owned
variable-width spacer also failed in the real toolbar: AppKit centred its view
inside a cached item container, producing feedback and further movement. The
simple nested-NSView regression harness did not reproduce this native container
behaviour. Both workarounds and the temporary geometry probe were removed.

## Change

Use the native `.autoHideToolbar` presentation policy. Home and the viewer share
that policy; Home no longer attempts to keep its toolbar pinned in full screen.
One NSToolbar remains attached to the window for its lifetime. Its source items
switch between Home and the viewer; the same item instances retain their actions,
selection, and custom views. There is no custom edge monitor, hide timer, moving
spacer, or private frame modification.

## Real-window integration check

`NativeToolbarBench` (debug only, `--native-toolbar-bench`) creates the actual
ViewerWindowController with an empty session and disposable configuration. It
enters full screen, checks that the system accepted `.autoHideToolbar`, and runs
three Home/viewer switches. After allowing AppKit's deferred item attachment to
complete, both sets of controls have a native full-screen host and the NSToolbar
object stays unchanged. It also checks disable/enable with the toolbar shortcut,
Home while the viewer toolbar is disabled, restoring that disabled state, and
exiting full screen with `.unified` style. All checks passed.

| Round | Show Home, main-thread CPU | Return to viewer, main-thread CPU |
| --- | ---: | ---: |
| First | 44.442 ms | 4.537 ms |
| Return 1 | 14.723 ms | 4.463 ms |
| Return 2 | 17.502 ms | 3.842 ms |

CPU uses `CLOCK_THREAD_CPUTIME_ID` via ThreadCPU. The deferred-attachment waits
are excluded from these CPU timings. This verifies real native hosting and state
transitions. The user subsequently confirmed the native reveal and reported that
the app also felt faster. Intel timings remain unmeasured.
