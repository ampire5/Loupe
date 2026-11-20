# Viewer feedback verification

Measured 2026-11-07 on the available Apple Silicon arm64 Mac, macOS 27.2 (26B123), 14 logical CPUs,
using the Debug executable's `--framing-learning-bench` with synthetic images and a separate temporary store.
No personal images or live learning records were changed by the benchmark. Intel remains unmeasured.

| Native operation | First visit, main-thread CPU | Subsequent rounds, main-thread CPU |
| --- | ---: | ---: |
| Feedback menu construction and native item/submenu layout | 4.775 ms | 0.090–0.158 ms |
| Learning window creation, layout and display | 47.181 ms | 18.277–20.558 ms |
| Existing window hide/show and display | 0.770 ms | 0.604–0.654 ms |
| Fit control dispatch | 1.504 ms | — |

Six menu rounds and four window rounds did not accumulate cost. Menu measurements cover construction and
layout, not pointer-to-popup wall time: fresh captured-image detection is asynchronous, shows a preparing toast,
and may take longer. Source stat, detection and persistence are outside main-thread menu construction.
Only one menu preparation per viewer is admitted. Pending menus are rejected after source, transform,
window focus or detector-context changes. No recurring timers were added.

One complete ordinary test run passed: 2,315 core tests (7 skipped), plus 65 app, 65 settings and 3 inspector tests.
Focused framing, input and mouse tests passed. Tests cover old dataset decoding, overlapping objects,
independent object notes preserving crop references, revision-fenced undo, fresh captured detections,
replacement at the same URL, manual capture without an automatic origin, and save-and-next preserving Manual.
The initial broad run exposed incomplete exhaustive input-action test tables and examples that duplicated standard
bindings; both were corrected. That run also hit a thumbnail-store SQLite lock; no thumbnail-store code or test was
changed. After adding cancellation on image replacement/window teardown, the final broad run failed two unchanged
browser availability tests (`placesOrderHomeVolumesPins`, `placesDimsMissingPin`). The subsequent focused run
including all framing/input/mouse tests and `BrowserListingSourceTests` passed (146 core tests, plus app tests).
This feature does not claim to fix SQLite contention or browser availability deadline instability.

The existing 64 MiB store limit remains; object notes have an additional 32,768-record ceiling. Checkpoints retain
one prior dataset per viewer; undo requires the exact post-edit revision. Existing ideal crop geometry is not migrated.
