# Local Loupe performance sweep

Apple M4 Max, Mac16,6, 14 physical cores, 36 GB, macOS 27.2.1. Current release build, using the
workspace's HomeScreenKit checkout. AppKit measurements use the main-thread CPU clock. Render
measurements use Metal command-buffer GPU time. The runs were sequential.

## AppKit and folder work

| Workload | Result |
|---|---:|
| Settings opening on Mouse & Trackpad | 253 ms CPU |
| Settings first visits from Mouse & Trackpad onward | 23–89 ms CPU |
| Settings repeat visits in that sequence, per-page medians | 16–24 ms CPU |
| Changing one setting | 12–13 ms CPU |
| Settings idle | 5 ms CPU over 2 s |
| File View inspector, first open | 102.7 ms CPU |
| File View inspector, selection / reopen medians across three rounds | 9.8–11.0 / 19.3–20.8 ms CPU |
| Folder slot, first show / tab return / resize / hide medians | 8.57 / 0.74 / 2.69 / 0.64 ms CPU |
| Filmstrip, 10,000 entries, 2,000 scroll events | 1.3 µs median, 1.6 µs p99 |
| Folder preparation, 50,000 synthetic entries | 213 ms wall, 0.030 ms main CPU |
| Folder re-sort primitive / Home index, 50,000 entries | 31.4 / 4.29 ms CPU |
| Local browser listing, 48 files | 0–2 ms at whole-millisecond resolution |
| Thumbnail generation, 48 JPEGs, two read and two decode slots | 48/48, 101 files/s |

The inspector's first open is slightly above the approximate 100 ms screen budget. The earlier
release measurement was 112 ms on the same class of Mac. Settings' repeat visits took more CPU
than in the November 20 Key Bindings debug run in the matched Mouse & Trackpad starting sequence.
For Key Bindings the first visit was 65 ms versus 64 ms, and repeated visits were 20 ms median versus
8–9 ms. Repeat-visit costs varied across the two full sweeps as well. The builds and starting
sequences differ, so the older comparison does not establish a regression.

The browser, thumbnails and replay used 48 independent copies of three JPEG sizes of the macOS
Default Aerial image, from 1280×720 through 3840×2160. The local listing and thumbnail rates
describe that fixture. The slot benchmark exercises the existing folder slot with 1,000 synthetic
gallery rows and five windows. All of its navigation and cancellation assertions passed.

Two three-round sweeps of all 12 Settings pages opened on General in 275 and 293 ms. Three
first visits crossed the 100 ms screen target in both sweeps.

| First visit | CPU, two sweeps | Longest block, two sweeps |
|---|---:|---:|
| Zoom & Pan | 160 / 156 ms | 23 / 27 ms |
| Strip | 111 / 118 ms | 14 / 24 ms |
| Interface | 110 / 118 ms | 18 / 15 ms |
| Quality | 99 / 98 ms | 15 / 14 ms |

Full-round CPU totals were 1,103 / 464 / 465 ms and 950 / 179 / 339 ms, respectively.

## Rendering

12 MP source, 6144×3456 target, 200% zoom, 30 frames after five warm-ups.

| Filter | GPU median / p90 |
|---|---:|
| Lanczos-3 | 1.45 / 1.53 ms |
| MetalFX | 1.88 / 1.89 ms |
| MetalFX with Fine source grain | 3.56 / 3.56 ms |
| MetalFX with Fine output grain | 2.19 / 2.19 ms |
| MetalFX with Adaptive Window debanding | 2.25 / 2.25 ms |

The corresponding November grain-stage medians were 3.58, 2.20 and 2.26 ms. The repeated
measurements are within 0.02 ms for those three effects.

## Playback of viewer navigation

Replay records when a sharp entry is ready to show. It does not measure physical display presentation.
The fixture has local JPEGs and seeded thumbnails.

| Scenario | Sharp updates | Sharp p50 / p90 | Peak ordinary image cache |
|---|---:|---:|---:|
| Fit, normal steps | 30/30 | 2 / 2 ms | 1,202 MB |
| 100%, forward and backward | 40/40 | 2 / 3 ms | 1,202 MB |
| Fit, 60 ms burst | 40/47 attempted, 8 skipped | 0 / 11 ms | 1,551 MB |
| 100%, alternating direction | 20/20 | 2 / 2 ms | 324 MB |

Burst timing includes only the sharp frames reached before the next step. The ordinary replay clears
the viewer's playlist and pin while the cache stays alive; its remaining Metal allocation is not a
measurement of closing and unregistering a window.

### Memory after close

The separate close replay opened one viewer session, advanced across six local JPEGs, unregistered
the session and repeated the cycle 20 times. The cache returned to zero and Metal to its initial
0.5 MiB on every cycle. Process footprint after three seconds was 8.8–9.1 MiB, compared with
7.1 MiB before the first open. The last ten cycles stayed within 0.82% of their mean, passing the
5% plateau check. This replay exercises the normal image cache with neural upscale off.

## Upscale model switching

The AppKit model picker was exercised against installed 2× and 4× models on a
640×360 SDR photo. The 200% viewer mode stayed selected, native result dimensions changed with the
model, and both cached pyramids were returned by identity on subsequent selections. A second viewer
reused the same cached 4× pyramid. Two cached switches together took 0.90 ms wall time in this debug
test with Metal API Validation. The time includes the model picker action and cache lookup and excludes
display presentation. To run the opt-in test, set `LOUPE_TEST_UPSCALE_PHOTO` to a small local JPEG and
set `LOUPE_TEST_UPSCALE_2X_MODEL` and `LOUPE_TEST_UPSCALE_4X_MODEL` to the installed models' display names.

## Reproduce

Build `LoupeBench` and `Loupe` in release with the repository's decoder environment. Run these
commands sequentially. Use a scratch configuration for the AppKit runs.

```sh
LoupeBench hotpaths --files 50000 --runs 9
LoupeBench settings --start mouse --rounds 3 --settle 180 --icons 0
LoupeBench settings --rounds 3 --settle 180 --icons 0
LoupeBench inspector
Loupe --folder-slots-bench
LoupeBench strip --files 10000
LoupeBench browser --runs 9 "$photos"
LoupeBench thumbs --reads 2 --decodes 2 --limit 48 "$photos"
LoupeBench render --frames 30 --size 6144x3456 --image 4000x3000 --filter metalfx --filter lanczos3
LoupeBench replay --script fit,100,burst,pingpong --screen 6144x3456 --seed "$photos"
LoupeBench replay --script close --limit 6 --screen 6144x3456 "$photos"
```

The sweep covers the local M4 Max. Intel, live SMB, and physical input-to-display latency were outside this run.

## Startup and transitions between File View and the viewer

`scripts/startup-bench.py` launched an isolated copy of the installed release app three times
per file, with an empty configuration and the standard uncounted signature warm-up. Times below
are from process launch. The render-loop marker is internal. The first-image marker measures
submission of a frame containing the image.

| Startup input | Render-loop marker, median | First image, median | Full resolution, median |
|---|---:|---:|---:|
| 1280×720 local JPEG | 124 ms | 324 ms | 324 ms |
| 3840×2160 local JPEG | 122 ms | 317 ms | 318 ms |

First-image measurements ranged from 314 to 488 ms across the six launches. This case starts
with a file argument and uses no saved session.

Eight round trips ran in one 1200×800 pt AppKit window in a debug test process. The probe used the
normal viewer Browse action and dispatched Return to File View's selected card. It used a local
48-file folder and the 4K JPEG. The app's existing `turn browse` and `turn open from browser`
markers include AppKit layout and the Core Animation commit. They measure a main-run-loop turn.

| Direction | First turn, CPU / wall | Repeat median, CPU / wall | Repeat range, wall |
|---|---:|---:|---:|
| Viewer → File View | 121.7 / 155.3 ms | 85.6 / 86.3 ms | 69.1–99.9 ms |
| File View → viewer | 28.9 / 29.9 ms | 17.1 / 17.6 ms | 14.2–35.1 ms |

The October [Viewer ↔ Folders measurement](2026-10-26-viewer-to-folders.md) used a release app,
6K monitor and 200 large JXLs over Ethernet SMB. Its times describe a different workload and
build configuration. The fresh local test puts the first Viewer → File View turn above the
100 ms CPU target. Startup and transition timings here exclude physical display presentation.

A second eight-round run used the same AppKit probe and fixture with optimizations enabled
(`swift test -c release`). It passed its checks that Browse enters File View and Return
opens the selected photo in the same window.

| Direction | First turn, CPU / wall | Repeat median, CPU / wall | Repeat range, wall |
|---|---:|---:|---:|
| Viewer → File View | 130.7 / 185.1 ms | 94.2 / 94.8 ms | 89.9–100.9 ms |
| File View → viewer | 18.5 / 19.5 ms | 30.5 / 32.8 ms | 23.7–36.7 ms |

`session-bench.py` also exercises the same-window round trip in its fullscreen workflow.
`switch-bench.py` measures activation between separate windows or Spaces.

### Main-thread profiles

On the M4 Max, `sample` at 1 ms captured three separate launches of the release app with the
same 4K JPEG, and separate recordings of the release and debug round-trip probes. Sample counts below are inclusive
unless marked self. They indicate where the thread was sampled, and can overlap between
callers and callees. The profiler changed elapsed time, so use the unprofiled runs for latency.

| Startup stack, main thread | Samples per launch |
|---|---:|
| Restoring the first window frame in `setFrameUsingName` | 62–64 |
| Constructing the first viewer controller | 57–59 |
| ↳ Constructing its toolbar controller | 23–26 |
| AppKit `NSToolbarView.layout`, across the launch | 47–48 |
| Objective-C dispatch (`objc_msgSend`, self) | 13–18 |

The frame restoration stack includes a synchronous layout of the already assembled window and
toolbar. In the unprofiled runs the session reached `navigate` at 245–252 ms from exec. Five of
six runs submitted the first image 65–77 ms after that marker; one took 243 ms.

The startup experiment applied the saved frame before attaching the view tree and toolbar.
Ten unprofiled launches per release build ran in alternating order with the same saved frame,
4K JPEG and display. A second saved frame verified that both builds honored the geometry.

| Startup from exec | Current order | Early frame restore |
|---|---:|---:|
| Render-loop marker, median | 120.0 ms | 120.5 ms |
| Navigation marker, median | 234.5 ms | 180.0 ms |
| First image, median | 316.5 ms | 311.0 ms |
| First image, range | 305–335 ms | 301–332 ms |

A separate sampled launch reduced the frame restoration stack from 53 to 6 main-thread
samples. Toolbar layout appeared later in the candidate stack. The 54.5 ms gain at the
internal navigation marker yielded a 5.5 ms difference at the first image. The experiment
was reverted. The toolbar controller also creates the Zoom Options and Scaling menus on
launch. Lazy menu population is a separate experiment with its own first-open timing.

For the round trip, the optimized profile collected 5,048 main-thread samples. The table
includes both directions and UI work that occurred after an action returned. The debug
recording independently found the toolbar layout stack 316 times.

| Round-trip stack, main thread | Release samples |
|---|---:|
| AppKit `NSToolbarView.layout` | 358 |
| `ViewerWindowController.showHome` | 153 |
| Sidebar tree assignment's change handler | 63 |
| `WindowToolbarController.show` | 57 |
| `vImageConverterConvert` | 7 |
| Objective-C dispatch (`objc_msgSend`, self) | 74 |
| `mach_msg2_trap` (self) | 4,011 |

### File View follow-up

The first experiment set the native toolbar's complete `itemIdentifiers` list in one call.
A native test window verified order and custom-item identity across multiple switches.
Two release runs per variant alternated in the same environment, with eight round trips in
each process. Medians include the run-loop commit and are in ms (CPU / wall).

| Direction | Existing, first | Batch, first | Existing, repeat | Batch, repeat |
|---|---:|---:|---:|---:|
| Viewer → File View | 126.0 / 128.4 | 142.6 / 144.4 | 91.8 / 92.8 | 100.5 / 101.2 |
| File View → viewer | 22.0 / 22.9 | 49.2 / 50.2 | 32.1 / 34.5 | 55.6 / 56.6 |

The native layout stack appeared in 585 of 5,036 main-thread samples with the batch setter
and in 358 of 5,048 with the original switch. The synchronous toolbar switch stack went
from 57 to 469 samples. The batch setter was reverted.

A separate change in HomeScreenKit builds the sidebar's rows, root identities and followed
row together. The view uses the resulting projection for row and selection lookups until
it receives the next tree. On the same Mac, an optimized model probe with the same folder
under Places and Favorites measured this part of one update at 0.32 → 0.15 ms for 66 rows,
1.63 → 0.74 ms for 366 rows, and 4.56 → 2.10 ms for 1,006 rows. This probe excludes native
layout and compares four tree lookups against a single intermediate result.

The same release round-trip comparison with only the sidebar change gave the following
times. The local 48-JPEG fixture has a small sidebar. On that workload the full turn
latencies were close to baseline, and the first Browse turn still exceeded 100 ms CPU.

| Direction | Before, first | Sidebar, first | Before, repeat | Sidebar, repeat |
|---|---:|---:|---:|---:|
| Viewer → File View | 127.2 / 129.8 | 126.6 / 128.1 | 93.9 / 94.5 | 92.0 / 93.3 |
| File View → viewer | 22.0 / 22.8 | 21.8 / 22.8 | 31.7 / 34.0 | 32.1 / 34.5 |

The sidebar tree build appeared in 47 → 16 inclusive main-thread samples in the two
release recordings, both with 5,048 total main-thread samples. The native toolbar layout
still appeared in 358 → 361 samples.

All 17 sidebar tree tests, all 16 sidebar view tests and the viewer toolbar workflow test
passed. The HomeView toolbar-field focus test failed at the same three assertions with the
original and changed sidebar. The signed copies of both builds reported the same checks in
the fullscreen bench, starting with failure to enter fullscreen in this session.

### Transition with toolbar item changes disabled

The same release test executable ran four paired launches on the M4 Max. Each pair
alternated the order and each launch made eight same-window round trips through a
local 48-JPEG folder. The diagnostic variant kept the original viewer toolbar
items mounted while File View was visible. It still made Home, obtained the Home
toolbar from its source, changed browser state and ran ordinary AppKit layout.
Both variants checked the selected 4K JPEG and that Return reopened it in the
same window. The table shows medians in ms (main-thread CPU / wall through commit).

| Direction | Ordinary, first | Frozen, first | Ordinary, repeat | Frozen, repeat |
|---|---:|---:|---:|---:|
| Viewer → File View | 142.0 / 147.2 | 123.5 / 128.3 | 87.4 / 88.5 | 67.7 / 67.9 |
| File View → viewer | 24.0 / 24.7 | 22.6 / 26.6 | 17.8 / 19.7 | 23.7 / 28.9 |

The paired first-Browse CPU savings were 20.2, 10.0, 22.0 and 12.0 ms. All four
first Browse turns with the item swap disabled still took more than 100 ms CPU
(118.8–133.2 ms). The backward direction is included as a diagnostic: keeping
the viewer controls mounted changes the work they receive while File View is up.

In separate launches with stage timing enabled, `makeHome` took 24.1 ms CPU
on the first ordinary Browse and 23.3 ms with the panel frozen. The first direct
item swap took 2.3 ms. The remainder of the first main-loop turn after the
measured synchronous sections took 103.9 ms with the ordinary swap and 94.8 ms
with it disabled. The latter is an independent run and includes deferred work
through Core Animation commit. A separate frozen run sampled the main thread at
1 ms across multiple round trips. Among 5,510 samples, 524 included window
layout, 262 included native toolbar layout and 35 included applying the sidebar
divider position. These inclusive counts overlap and include warm transitions.
This experiment isolates changing the installed toolbar items from the rest of
the transition. Physical presentation timing and full screen were outside the
probe. The diagnostic code was removed after measurement.

### Incremental native toolbar prototype

The prototype uses a collection difference to retain installed items in their
relative order. Custom items match by object and identifier. System spacers
match by identifier. An AppKit test window with a shared text field, repeated
flexible spacers and two distinct buttons with the same identifier ran four
switches. The original switch dismissed the active field editor on all four.
The prototype retained the editor and selected text on all four, kept the shared
spacer in that fixture, and selected the correct mode button. The regression
test checks that the shared custom item is never removed, the buttons are
replaced, and a spacer is retained per switch.

The release transition probe on M4 Max alternated the baseline and prototype
four times, with eight round trips per launch. Each variant checked that Return
reopened the selected JPEG. The prototype also checked that a spacer already
mounted before each switch survived it. The current Loupe modes have no shared
custom toolbar items. The median main-thread CPU and elapsed time through the
run-loop commit are in ms.

| Direction | Baseline, first | Prototype, first | Baseline, repeat | Prototype, repeat |
|---|---:|---:|---:|---:|
| Viewer → File View | 135.1 / 139.1 | 135.3 / 137.8 | 87.4 / 88.6 | 88.1 / 90.0 |
| File View → viewer | 23.5 / 26.6 | 23.1 / 26.2 | 19.6 / 21.1 | 18.6 / 20.2 |

The measurements show no consistent improvement in the File View direction.
The back-label and mode-switching regressions passed. The separate signed
`Toolbar Trial` bundle passed signature verification and opened the local
4K test photo in an isolated startup run. The windowed round-trip measurements
used the test executable.
Fullscreen behavior still needs a hands-on check.

## November 24 local-media replay

MacBook Pro Mac16,6, M4 Max, 14 physical cores, 36 GiB, macOS 27.2.1 (26B131), internal
APFS SSD. Baseline Loupe was `892fa7c` plus the measurement entry point. Both release builds
used the pinned kits and statically linked Loupe decoders. This run uses a 1200×800 pt AppKit
viewer, a 2 GiB photo-cache budget and an isolated on-disk thumbnail catalog. Neural upscale
was off. Folder opening goes through the real window controller. The navigation loop sends
session steps directly, with a 60 ms deadline per step, 14 forward and 14 backward, then
supersedes a large-directory open with a different folder. The zoom loop uses the viewer's
200% and Fit commands. The video probe uses the real poster and playback controller.

The fixture contains 48 separately materialized JPEG files from the macOS Default Aerial
photo (1280×720, 1920×1080 and 3840×2160), a second folder containing 24 JPEGs and a four-second
3840×2160 H.264 MP4 at 30 fps, and 12,000 naturally named hard links to the 48 JPEGs.
Hard links test directory/playlist scale with bounded disk footprint. A separate 7680×4320
JPEG derived from the 4K source tests zoom past a reduced fit level. The fixture resides at a
regular absolute path on APFS. A preliminary fixture under a hidden directory exercised the
fallback of HomeScreenKit's `URL.quicklyStandardized`, roughly doubling opening time.
The paths below describe the regular-path run.

A first pass starts with an empty Loupe cache and catalog. A repeat stays in that process
with the viewer, data and Metal allocations still resident. In the primary runs the APFS
page cache was generally warm. Separate fresh-inode APFS clones supplied a storage-read case
for navigation. Clone creation warms directory metadata, and these runs make no claims about
cold filesystem metadata or storage-controller caches.

The stop condition is a qualifying entry for the requested photo, a decoded poster, or a
settled zoom at the required level. It excludes physical input and scan-out. Main CPU is
`CLOCK_THREAD_CPUTIME_ID` over the same interval, including other main-loop work. Process
footprint and Metal allocation are sampled at action boundaries. The kernel's process I/O
counters track physical bytes charged to the process, including concurrent work. They exclude
cache hits and cannot count metadata syscalls. A navigation miss means the target did not
qualify by 60 ms. Latency percentiles count successes, and CPU includes misses. p95 and p99
are nearest rank. For the ten-run cases both are the maximum.

### Isolated changes and profiles

Separate `sample PID 5 1` runs profiled release builds. The table counts inclusive samples
within each stack across the two passes. Profiled launches can overlap certificate, AppKit
and worker startup work, and the process can finish before five seconds. Use the separate
unprofiled timings for latency.

| Experiment | Relevant inclusive samples, before → after | Unprofiled change |
|---|---:|---|
| Reuse the fast normalization path when keying folder stamps | `FolderNavigator.target` 215 → 37 worker samples, `faccessat` 52 → 0 worker samples | Open and qualify the first photo, median 375.7 → 273.8 ms first and 332.2 → 228.0 ms repeat |
| Build both listings in the selected sort and keep reordering off main | `Playlist.sorted` 26 → 0 main samples | Main CPU until sorted stamps, median 53.0 → 37.4 ms first and 48.0 → 30.3 ms repeat. The already selected photo still qualified in about 78 ms |
| Reuse the fast normalization path for re-read URLs | `Playlist.list` 274 → 86 worker samples, `faccessat` 49 → 0 worker samples | Time from the shown photo to sorted stamps, median 254.9 → 165.2 ms first and 282.8 → 189.2 ms repeat |

Full Foundation normalization repeatedly went through `URLByStandardizingPath`,
`checkResourceIsReachableAndReturnError:` and `faccessat` for URLs obtained from the directory
iterator. The existing HomeScreenKit fast path keeps ordinary absolute URLs and still calls
Foundation for exceptional spellings. Loupe retains the listing's date and size for cache
validation. The re-read keeps the current and previously retained entries by URL. The shared
sort order and the distinction between the names-only and stamped passes stay in use. When the
sort setting changes in flight, the shared preparation actor reorders the snapshot before the
viewer can commit it. The viewer checks the current folder again after that hop.

The remaining large-folder work includes `FolderPlaylistPreparation` (218 worker samples in
the final profile), `StripController.playlistChanged` (51 main samples), native
`NSToolbarView.layout` (60 main samples) and `ThumbnailStore.sync` (67 worker samples). The
strip builds URL indexes and remaps visible cells when a playlist changes. The catalog tracks
source revisions and reusable thumbnails. Both remain visible in the profiles after eliminating
the path probes.

### Paired AppKit results

Wall and main CPU are in ms. Each cell shows p50 / p95 / p99. First and repeat are separate
samples. The warm page-cache navigation comparison used eight processes per build.

| Workload | Wall before | Wall after | Main CPU before | Main CPU after |
|---|---:|---:|---:|---:|
| 12,000-file folder to first photo, first | 375.7 / 389.1 / 389.1 | 272.1 / 283.8 / 283.8 | 78.3 / 84.6 / 84.6 | 73.9 / 77.6 / 77.6 |
| 12,000-file folder to first photo, repeat | 332.2 / 339.2 / 339.2 | 226.9 / 231.1 / 231.1 | 37.4 / 39.6 / 39.6 | 32.5 / 35.0 / 35.0 |
| Already shown photo to complete sorted playlist, first | 271.5 / 293.6 / 293.6 | 165.2 / 176.2 / 176.2 | 53.0 / 71.3 / 71.3 | 36.0 / 41.0 / 41.0 |
| Already shown photo to complete sorted playlist, repeat | 294.6 / 320.1 / 320.1 | 189.2 / 209.5 / 209.5 | 48.0 / 64.7 / 64.7 | 32.0 / 52.7 / 52.7 |
| Select JPEG inside the 12,000-file folder, first | 78.4 / 79.6 / 79.6 | 76.5 / 85.7 / 85.7 | 49.4 / 52.0 / 52.0 | 47.8 / 50.3 / 50.3 |
| Leave 12,000-file folder for 48 photos, first | 24.1 / 32.4 / 32.4 | 27.7 / 36.4 / 36.4 | 22.4 / 31.5 / 31.5 | 25.6 / 35.1 / 35.1 |
| Forward, first | 10.8 / 18.8 / 20.1 | 11.1 / 16.6 / 24.6 | 4.9 / 6.5 / 17.2 | 4.9 / 6.6 / 9.2 |
| Reverse, first | 2.7 / 4.1 / 4.8 | 2.7 / 4.6 / 5.2 | 1.6 / 3.8 / 4.0 | 1.7 / 3.9 / 4.1 |
| Forward, repeat | 2.8 / 5.0 / 6.0 | 2.8 / 5.0 / 5.8 | 1.7 / 4.9 / 5.0 | 1.7 / 4.8 / 5.3 |
| Replace pending folder request, first | 8.7 / 17.5 / 17.5 | 9.0 / 11.9 / 11.9 | 2.7 / 8.6 / 8.6 | 4.5 / 7.0 / 7.0 |
| 8K JPEG, zoom to 200%, first set of 12 | 149.7 / 152.2 / 161.9 | 149.8 / 150.9 / 152.1 | 10.6 / 20.2 / 31.8 | 11.6 / 19.2 / 20.4 |
| 8K JPEG, zoom to 200%, repeat set of 12 | 149.8 / 151.3 / 151.6 | 149.8 / 151.0 / 152.3 | 15.5 / 21.7 / 23.0 | 15.1 / 21.4 / 22.1 |

All large-folder opens and sorted-list checks completed. Opening the selected JPEG itself,
leaving for a small folder and sourcing the already-resident 200% view were similar across
builds. The zoom loop is dominated by the configured 150 ms transition. With
`zoom-animation = 0`, the settled and already-resident 8K case was 0.2 / 0.4 / 0.4 ms in
24 first-pass commands and 0.2 / 0.2 / 0.2 ms in 24 repeat commands. These are viewer-state
transitions. All 192 8K zoom-in
operations across the two builds reached the requested scale with level 0 resident.
In the 4K scenario one of eight initial JPEG opens on the changed build timed out in the
3 s probe. The remaining seven were 78.3 ms p50 / 82.6 ms p95, versus 77.4 / 82.7 ms in
eight baseline launches. All 4K zoom-in operations completed after the initial open probe.

With warm pages, the first forward sweep qualified 72 of 112 frames in both builds.
Both qualified all 112 reverse frames and all 224 frames in the repeat. With fresh file
clones, the first forward sweep qualified 45 of 70 frames in both builds. Its latency
was 12.6 / 17.3 / 27.5 → 12.3 / 19.8 / 21.9 ms for qualifying frames, with 25 misses
on each side. The clone run charged 210.8 → 210.9 MiB of reads across those five forward
sweeps versus zero on the repeat. Both reverse and repeat runs completed 70/70 frames per
direction. The high-resolution file's cold path still pays decode and texture upload.
Reopening already resident frames is fast even when no JPEG pages are charged to the
process. Extending the 60 ms interaction deadline would change the miss count.

For the 12,000-file first open, the maximum sampled process/Metal allocation was 440/54 →
433/54 MiB. On repeat it was 807/339 → 730/295 MiB. Measured reads rounded to zero in both,
and writes across ten repeat opens rounded to 1.1 MiB in both. These are endpoint observations,
including AppKit, GPU resources and overlapping background work. During navigation with
fresh clones, the largest sampled footprint was about 1.4 GiB on either build, with about
930 MiB of Metal allocation.

The supersession test checks that the destination is still selected 400 ms afterward.
It replaces the request in the same main-actor turn. An additional test holds an in-flight
directory read, cancels its request, then lets the operation return. A queued cancelled
request skips the lister. An active filesystem call can finish, and the cancelled task
discards its result before building the target. Existing pool limits govern photo reads
and decodes and thumbnail generation. Current photos reserve decode capacity, and the
thumbnail store pauses new reads during current-photo work. Samples of the tested
navigation sweeps showed JPEG decode and texture uploads on workers. Thumbnail work
continued while the viewer was idle and used its existing worker limits.

The misses matched the five 4K JPEGs at positions 3, 6, 9, 12 and 15 in every first forward
sweep, including the runs charged no physical reads. The file reader maps the local file and
TurboJPEG writes directly into its decoded BGRA buffer. Metal wraps that buffer using
`makeBuffer(bytesNoCopy:)`, then transfers tiles to private textures and builds the smaller
levels. `decode_mcu` and `jpeg_fill_bit_buffer` took 799 and 285 self samples in the
changed navigation profile, respectively. `_platform_memmove` took 17 across the process.
A separate debug trace found 62–66 ms of preview decode and 8–9 ms of upload on the 4K
photos reached on reversal, with read setup below the log’s 1 ms resolution.
Separate thumbnail decodes also use the JPEG library at utility QoS. Existing priorities
and reuse of the viewer's compressed bytes keep both pipelines in the same I/O budget.

The first path experiment reduced the `faccessat` leaf from 52 samples to zero. For the
re-read experiment, the whole-process leaf was 50 → fewer than five, including the caller's
commit-time lookups. `getattrlistbulk` still shows up, as the listing supplies the source
stamps. After cancellation and review fixes, `FolderNavigator.target` went from 34 → zero
samples in the supersession replay. A separate folder-open sample still found 36 samples
there when the request was wanted.

The final release retest gave 274.0 / 281.6 / 281.6 ms to the first frame from the 12,000-file
folder and 230.1 / 236.9 / 236.9 ms on repeat (five launches). The sorted-list interval
was 164.8 / 168.4 / 168.4 ms first and 198.5 / 198.8 / 198.8 ms repeat. The final clone run
again qualified 45/70 forward frames, with 209.3 MiB of attributable reads across five
first sweeps and zero on repeat. All 70 reverse and all 140 repeated navigation steps
qualified. The final 4K zoom retest opened the target in all four launches, and the
final 8K run qualified all 96 zoom-in commands.

### Reproduce

Build in release with the repository's decoder environment. Use a disposable window and
catalog. In the root fixture, put JPEGs in `a` and `b`, name the zoom target `a/003.jpg`,
put the MP4 at `b/clip.mp4`, and put `img1.jpg` through `img12000.jpg` in `large`.
The descending-name check expects all 12,000 stamps. For the 8K case use a separate fixture
with the larger image at `a/003.jpg`. A fresh APFS clone per process gives a new file-cache
identity without writing a new copy of the compressed payload. Reuse that process for the
warm pass.

```sh
. scripts/libjxl-env.sh
swift build -c release --triple "$DEPS_TRIPLE" -j 5
probe="$(swift build -c release --triple "$DEPS_TRIPLE" --show-bin-path)/Loupe"
scratch="$(mktemp -d)"
mkdir "$scratch/config" "$scratch/home"
printf 'cache-memory = 2G\n' > "$scratch/config/loupe.conf"
export LOUPE_CONFIG_DIR="$scratch/config" CFFIXED_USER_HOME="$scratch/home" MallocLargeCache=0
for scenario in folder sorted-open navigate zoom video; do
    export LOUPE_BENCH_CATALOG="$(mktemp -d "$scratch/catalog.XXXXXX")"
    "$probe" --local-media-bench "$fixture" "$scenario" > "$scratch/$scenario.tsv"
done

# Profile separately. Use a signed Loupe bundle with the original extension point for the video probe.
export LOUPE_BENCH_CATALOG="$(mktemp -d "$scratch/catalog.XXXXXX")"
"$probe" --local-media-bench "$fixture" sorted-open > "$scratch/profile.tsv" &
target=$!
sample "$target" 5 1 -file "$scratch/sorted-open.sample"
wait "$target"
```

### Video and FrameScrub

Loupe selects the file, asks AVFoundation for a poster and hands a read-only descriptor to the
optional FrameScrub scene once its handshake succeeds. The provider acknowledges its first
picture. Once the host steps, it allows one outstanding step request and coalesces the remaining
travel as a signed delta. FrameScrub owns demux, decode, presentation, frame history and its
playback clock. The Loupe and FrameScrub timelines use independent sample processes.

The native 4K poster qualified in 160.6 / 174.0 / 174.0 ms on first open and
28.6 / 33.3 / 33.3 ms on repeat across four release launches. The host's main-CPU figures
were 72.2 / 87.1 / 87.1 ms and 12.4 / 13.7 / 13.7 ms. Main-thread work included building the
playback surface and native window layout. The poster generator was off main (79 inclusive
`AVAssetImageGenerator` samples in a separate video run). The isolated identifier used by the
early photo probe could display a poster but could not discover the extension. Restoring the
original signed host identifier yielded protocol v6 in the final launch series.
The in-process repeat keeps the poster view and ExtensionKit process warm. It opens the
video at the start again.

The independently built FrameScrub provider harness drove the actual service and picture view
with local 1920×1080 H.264 (250-frame GOP) and the same 3840×2160 H.264 clip as Loupe. Each
round sought to an interior point and drove 20 back, 20 forward and 20 back, as fast as
each presented response allowed. It checked every frame timestamp against the 30 fps
sequence, then resumed and observed ten advancing frames. Neither fixture dropped a
frame within those short resume windows. This probe omits ExtensionKit transport and physical
scan-out. Source and build commands are in FrameScrub's
`docs/bench/2026-11-16-provider-scrub.md`.

| FrameScrub engine and picture view | 1080p H.264 | 4K H.264 |
|---|---:|---:|
| First open to submitted picture | 81.8 ms | 77.5 ms |
| Step p50 / p95 / p99, ranges across three rounds | 1.3–1.9 / 1.9–2.4 / 2.0–3.5 ms | 4.7–5.2 / 61.7–73.9 / 73.4–74.8 ms |
| Steps over 50 ms | 0/180 | 14/180 |
| Seek and 60 steps, main CPU per round | 6.1–11.1 ms | 23.9–33.2 ms |
| Resume to first advancing picture | 33.9–35.5 ms | 34.5–36.0 ms |
| Max RSS | 84.5 MiB | 180.1 MiB |
| Block input operations reported by `time -l` | 0 | 0 |

The 4K worker profile included 751 inclusive samples in `OnDemandVideo.previous` and its
descendants. The FrameScrub benchmark on decoded-frame windows explains the retained-frame
limit and why sustained reverse reaches an uncached part of a GOP. The Loupe changes are
limited to photo/folder preparation. The measurements supply independent baselines for video.

The same-identifier comparison opened four baseline and eight final processes. Each process
opened the local 4K clip twice. Two final processes got "provider scene deactivated" before
handshake on both passes and hit the five-second picture deadline. All four baseline and
six final processes with an active scene received their first pictures. For those six final
processes, the host sent 24 forward and 11 backward step commands at eight-millisecond
intervals using the real queue, waited for acknowledgements and read FrameScrub's presented
timestamp. All 12 bursts landed exactly at 0.433333333 s from a paused 0 s anchor.
All 12 resumes then observed a later presented timestamp.

| 4K embedded stage | Before wall p50 / p95 / p99, ms | After wall p50 / p95 / p99, ms | After main CPU p50 / p95 / p99, ms |
|---|---:|---:|---:|
| Native poster, first | 156.4 / 188.5 / 188.5 | 162.7 / 181.3 / 181.3 | 75.5 / 93.2 / 93.2 |
| Native poster, repeat | 22.0 / 25.8 / 25.8 | 23.0 / 32.4 / 32.4 | 12.4 / 14.1 / 14.1 |
| Extension activation to first picture, first | 377.5 / 389.2 / 389.2 | 371.0 / 408.5 / 408.5 | 35.1 / 66.4 / 66.4 |
| Extension activation to first picture, repeat | 59.3 / 233.8 / 233.8 | 101.5 / 125.6 / 125.6 | 8.5 / 117.9 / 117.9 |
| Last input to acknowledged scrub landing, first | — | 189.8 / 251.2 / 251.2 | 2.6 / 3.7 / 3.7 |
| Last input to acknowledged scrub landing, repeat | — | 149.7 / 253.5 / 253.5 | 3.0 / 4.7 / 4.7 |
| Resume after landing to first advancing picture, first | — | 102.2 / 142.0 / 142.0 | 1.5 / 3.0 / 3.0 |
| Resume after landing to first advancing picture, repeat | — | 134.2 / 175.2 / 175.2 | 1.1 / 3.4 / 3.4 |

Baseline host-side instrumentation timed poster and first picture. The more detailed timestamp
probe ran on the final host. Video providers were unchanged. Both comparisons include warm
APFS pages, except the first baseline process incurred 26.1 MiB of poster-phase reads and
45.0 MiB in the first-picture interval. Final scrub and resume intervals charged zero
physical I/O to Loupe. At the scrub landing raw sampled Loupe footprint reached 717 MiB
first and 1,098 MiB on repeat. These counts include the photo cache and exclude memory
charged to the FrameScrub extension.

### Verification

The final release build completed for both products. `LoupeCoreTests` passed 2,419 tests in
the serial core run, including the new requested-sort, pre-submit cancellation and in-flight
cancellation cases. `LoupeTests` passed 109 tests with a clean configuration. The focused
run passed 15 app tests and 284 core tests. The combined parallel run hit the known
`placesDimsMissingPin` availability timeout. The final app run with the usual configuration
also hit the two-finger pan expectation. Both checks passed in isolation with a clean
configuration. When all targets ran serially in a single command the app test helper trapped
in `MenuShortcuts` during its first test. Running the app target on its normal parallel
schedule passed.

```sh
. scripts/libjxl-env.sh
swift build -c release --triple "$DEPS_TRIPLE" -j 5
swift test --triple "$DEPS_TRIPLE" -j 5 --filter LoupeTests
swift test --skip-build --triple "$DEPS_TRIPLE" --no-parallel --filter LoupeCoreTests
```

The local investigation retained action TSVs, scripts, verification logs and profiles under
`.build/local-perf-20261124`.
