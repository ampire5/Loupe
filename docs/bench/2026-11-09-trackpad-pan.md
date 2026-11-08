# Trackpad panning

Apple M4 Max, macOS 27.2 (26B123), debug build. The benchmark opened a real
`ViewerWindowController` with a generated 2048 × 2048 PNG at 200% zoom and
replayed precise AppKit events through `ViewerView.scrollWheel(with:)`. Each
round contained 125 repetitions of the same five-event sequence. The four
nonzero events were (1, 6), (1, 8), (8, 1) and (−10, −15), followed by an
empty end event. The first event in the timed sequence cleared the old
threshold so both builds moved the image four times. The regression test
separately checks the first sub-threshold delta, turning and momentum.

Main-thread CPU per event (`CLOCK_THREAD_CPUTIME_ID`), in ms. Each cell is
median / p99. A three-second `sample` at 1 ms intervals overlapped the first
part of the replay.

| Change | Round 1 | Round 2 | Round 3 | Round 4 |
| --- | ---: | ---: | ---: | ---: |
| Before | 0.371 / 1.035 | 0.376 / 0.901 | 0.635 / 2.116 | 0.791 / 1.773 |
| Axis lock confined to button gestures | 0.372 / 0.762 | 0.372 / 0.622 | 0.699 / 1.890 | 0.766 / 1.835 |
| Also reuse rules within each status update | 0.303 / 0.761 | 0.260 / 0.796 | 0.613 / 1.999 | 0.676 / 1.991 |
| Same code, sampler disabled | 0.654 / 2.001 | 0.618 / 2.058 | 0.701 / 1.994 | 0.682 / 1.956 |

Before the fix, the replay with a (1, 2) first delta left the photo at its
starting point. The old filter accumulated motion to its four-point
threshold and then projected subsequent deltas onto the chosen axis.
The filter took only a few stack samples. Most samples inside the event
handler went through transform updates into the window controller. The
status refresh resolved the current photo's rules four times and the shown
photo's once. The stacks included folder path standardization and
filesystem calls (`faccessat` and `stat`).

Reusing the already resolved rules removes four lookups when the current
and shown URLs match, or three when the status still describes a different
photo. Across the corresponding sampled rounds, the median CPU fell by
0.069–0.112 ms per event from the gesture-only change. The p99 results
varied. Without the sampler the late-round rise did not repeat.

The replay covers work inside the event handler. Hardware input to display
latency and Intel performance were outside these measurements.
