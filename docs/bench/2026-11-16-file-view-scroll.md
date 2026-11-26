# File View scrolling with a large sidebar

Apple M4 Max, macOS 27.2.1, debug build. An AppKit probe opened a 1400 × 900 Loupe window and moved
each scroll view by 28 points for 240 steps, three times. Each step measured main-thread CPU with
`CLOCK_THREAD_CPUTIME_ID`, including layout and the Core Animation commit. The probe also measured
wall time between steps, with an 8.33 ms requested interval, and profiled the process with `sample`
at a 1 ms interval. These are scroll and main-loop timings. Display presentation and physical input
latency require separate measurements.

The SMB sidebar had about 2,310 logical rows. The SMB grid was measured in another folder with a
few hundred images. Both shares were read-only for the probe. The local fixture had 1,600 directories
and 3,500 images. During scrolling it added one directory and one image every 650 ms, through the
normal folder watcher and listing refresh.

| Scenario | Before, CPU p95 | Reused sidebar rows | Added off-main marking index | Added fast URL lookups |
|---|---:|---:|---:|---:|
| SMB sidebar | 20.4–32.0 ms | — | 2.3–4.1 ms | 2.1–4.4 ms |
| SMB grid | 1.7–1.9 ms | — | — | 1.3–1.4 ms |
| Local sidebar with arrivals | 30.3–39.1 ms | 3.3–3.4 ms | 2.8–4.4 ms | 2.6–3.8 ms |
| Local grid with arrivals | 12.6–13.2 ms | 2.2–2.5 ms | 1.7–2.0 ms | 1.5–1.7 ms |

The SMB sidebar's AppKit document went from 2,310 subviews to 32, including the drop indicator.
The baseline profile showed AppKit recomputing visible rectangles and traversing the sidebar's
views when scrolling. The process-wide self sample counts included 37 in
`NSViewGetTransformToAncestor`, 26 in `NSViewHierarchyInvalidateVisibleRect`, and 69 in
`CA::Layer::get_frame_transform`. On the local fixture, the sidebar change also reduced grid cost
because the grid and sidebar share the window's layout and display cycle.

During relists, `FolderBrowserSource.remember` built a URL index on the main thread. The profile
showed Foundation calling `faccessat` from `standardizedFileURL`. After moving the index into
photo-mark preparation and reusing the existing fast URL standardization, the two warm local grid
rounds had maximum wall intervals of 32 and 33 ms, down from 68 and 63 ms. The first local grid
round still had a 490 ms wall interval while the scroll step itself took at most 4 ms of CPU.

HomeScreenKit's regression test
`swift test --jobs 4 --filter scrollingALargeSidebarKeepsOnlyViewportRowsAttached` exercises a
2,500-row sidebar and checks that only the viewport's rows are attached after a large scroll.
An Intel Mac and viewer presentation were outside this measurement.

## November 24 interactive replay

Release build on a MacBook Pro Mac16,6 with M4 Max, 14 physical cores, 36 GiB, macOS 27.2.1
(26B131) and an internal APFS SSD. Baseline `baaafb5` with the same probe. The
[local media fixture](2026-11-22-local-regression.md#november-24-local-media-replay) supplies
12,000 hard links to 48 real 720p, 1080p and 4K JPEGs. The 1200 × 800 pt viewer used a 2 GiB
photo cache. One process opens the folder in File View, jumps across the grid, opens the
viewer with its strip pinned, zooms to 200%, pans with 120 precise events at 8 ms spacing,
steps six files forward and back, changes folder and repeats. A new launch against the same
catalog measures a warm disk catalog. Process repeats also reuse memory. The OS page cache
was generally warm for the unprofiled grid runs. An empty thumbnail catalog does not imply
cold source pages.

```sh
. scripts/libjxl-env.sh
swift build -c release --triple "$DEPS_TRIPLE" -j 5
mkdir -p "$work/catalog" "$work/config"
printf 'cache-memory = 2G\n' > "$work/config/loupe.conf"
LOUPE_CONFIG_DIR="$work/config" LOUPE_BENCH_CATALOG="$work/catalog" \
  .build/out/Products/Release/Loupe --local-media-bench "$fixture" interactive
# For the separate profile, launch the same command in the background and pass its PID.
sample "$pid" 6 1 -file "$work/interactive.sample"
```

The AppKit probe measures delivery to visible grid IDs and image availability for visible
strip cells, with 1 ms polling. File View uses the source's reported deliveries, so a
recycled card may be marked ready before its new view receives its picture. First visits
and first jumps target disjoint ranges and are the tabulated grid comparisons. The original
baseline repeat jump could target the restored scroll offset again. A fresh move to another
range is required for that sample, so repeat jumps are excluded from paired results.
`file-view-fill` starts at first delivery. Strip timings start once the viewer reports its
current photo. Frame statistics use `CAMetalDrawable` presentation callbacks. Rounds with
no GPU samples have no drop measurement. Neither the main CPU per event nor GPU command
duration measures hardware input-to-display latency.

The local-only experiment removed the duplicate names pass. For four cold-catalog starts
the first delivery p50 went from 603 to 540 ms and main CPU from 346 to 295 ms. In the
separate profile the directory-names stack declined from 97 to 1 inclusive samples.
The full listing still supplies dates, sizes and package information. A known network mount
keeps the names-first behavior. A path through a symlink can require a volume resource lookup
before its enumeration. Intel, removable media and remote aliases were outside this run.

The next build adds a shortcut for the key window's visible jobs before the existing whole
folder ordering, reuses the strip's URL index for remapping, and avoids full path
normalization on ordinary thumbnail notifications. The cold first jump after local-only
was 135 ms p50 and was 90 ms with these changes. Baseline was 85 ms. Full-strip fill did
not improve consistently. Work on the hot paths also remains proportional to the listing
size when starting a new catalog sync, preparing grid photo marks or sorting the viewer's
playlist. No generation worker or read-slot count changed.

The final build also shares one cell decode for overlapping requests at the same URL, size
and orientation, and reuses catalog names already extracted for synchronization. A test
with 32 simultaneous callers reproduced separate image objects before the change and
received one shared object after it. Cache invalidation drops the matching flight before
it can publish. An ImageIO decode already running can finish and discard its output. The
test isolates duplicate work. It does not measure how often it occurred under this grid
workload. The photo-cache budget and eviction policy are unchanged.

### Final comparison

Times are nearest-rank p50 / p95 / p99 in ms. Cold rows combine the original unprofiled
runs and a three-pair alternating retest (7 baseline, 8 final). Warm rows are new processes
with populated catalogs (4 baseline, 5 final). The p95 and p99 are the maximum for these counts.
Latency percentiles count successes. CPU includes timeouts. Completion of the first grid
range below is first delivery plus time to fill that range.

| Thumbnail catalog and action | Wall before | Wall after | Main CPU before | Main CPU after |
| --- | ---: | ---: | ---: | ---: |
| Empty, File View first visible thumbnail delivery | 603 / 688 / 688 | 535 / 604 / 604 | 346 / 381 / 381 | 308 / 323 / 323 |
| Empty, File View first range filled | 661 / 772 / 772 | 603 / 798 / 798 | | |
| Empty, jump to a disjoint grid range | 95 / 403 / 403 | 129 / 471 / 471 | 21 / 34 / 34 | 23 / 231 / 231 |
| Empty, first visible strip thumbnail | 167 / 179 / 179 | 162 / 186 / 186 | 11 / 12 / 12 | 10 / 14 / 14 |
| Empty, visible strip filled | 348 / 643 / 643 | 379 / 2722 / 2722 | 33 / 64 / 64 | 30 / 158 / 158 |
| Warm, File View first thumbnail delivery | 371 / 395 / 395 | 380 / 416 / 416 | 299 / 338 / 338 | 311 / 332 / 332 |
| Warm, jump to a disjoint grid range | 174 / 196 / 196 | 160 / 174 / 174 | 34 / 43 / 43 | 33 / 41 / 41 |
| Warm, visible strip filled | 171 / 184 / 184 | 165 / 188 / 188 | 10 / 14 / 14 | 15 / 21 / 21 |
| Warm, File View revisit in process | 194 / 222 / 222 | 189 / 208 / 208 | 156 / 188 / 188 | 154 / 165 / 165 |

The final cold group had one jump timeout at 3 s and one 2.72 s strip fill in the same process.
All three paired replays completed. The cold jump and strip fill improved in two of those
three pairs, with the long tails unreproduced in that smaller follow-up. The hot-path change
does not establish a reliable overall fill improvement. Main CPU to first cold delivery was
lower in all three pairs. Whole-process `sample` stacks across the mixed replay counted
105 → 82 inclusive samples for `ThumbnailQueue.order` and 134 → 117 for `ThumbnailStore.sync`.
`StripController.playlistChanged` still had 22 samples, up from 18 in the baseline profile.
Sorting and rebuilding the photo marks remained visible on workers.

In the original cold group the sampled peak process footprint was 1,468 → 1,422 MiB and
peak Metal allocation was 831 MiB on both. Warm peaks were 1,480 → 1,475 MiB. Across the
unprofiled opens, the first File View delivery had at most 4 KiB of physical reads charged
to the process. The fresh-page storage case in the local-media bench remains the reference
for cold photo I/O. Some unprofiled grid reads were satisfied by the OS page cache; the
separate first profile launches did show physical I/O during filling.

### Viewer steps and 4K JPEG decode

The mixed replay's six forward and six reverse steps followed a pan with the viewer already
warm. Both versions qualified every step within 60 ms. The separate `navigate` replay alternated
four launches per version and started the sweep immediately after opening a 48-file folder.
Both versions qualified 36 of 56 first-forward steps, 56 of 56 first-reverse steps and every
repeat step. First-forward successful actions were 11.8 / 18.6 / 19.2 → 11.6 / 17.3 / 18.1 ms.
All eight superseding-folder runs passed the delayed selection check.

A standalone check linked the same static libturbojpeg and decoded four of the baseline
4K JPEGs from memory. Each scale alternated order, skipped two warmups and retained 48
observations. Full BGRA decode took 63.0 / 64.9 / 64.9 ms and 1:8 decode took
53.4 / 55.3 / 56.7 ms before any viewer upload or scheduling. Adding the earlier measured
8–9 ms upload to that downsized decode leaves little margin for a separate first-look
decode, which would repeat entropy work. No extra decode or lower photo-cache budget was
introduced. The experiment source and raw output are under `.build/interactive-perf`.

### Pan presentation

The mixed replay's p99 main-thread event cost was about 0.5–1.0 ms across both versions.
A separate set of instrumented trials used the final binary and the existing
`LOUPE_FRAME_LATENCY` and `LOUPE_DRAWABLES` overrides. Each value had two launches, with
45 distinct presented generations per launch in the steady pan after the zoom transition.
The display link ran at 60 Hz. Render time for presented pan frames was about 1.2–1.3 ms
at p90. The diagnostic records the latest render snapshot update to presentation callback.

| Setting | Update to presentation p50 (ms) | p95 (ms) | p99 (ms) |
| --- | ---: | ---: | ---: |
| System defaults | 53.6–54.2 | 57.2–57.4 | 58.2–59.0 |
| `LOUPE_FRAME_LATENCY=1` | 53.8–53.9 | 57.3–57.9 | 58.2–59.8 |
| `LOUPE_DRAWABLES=2` | 54.0–54.0 | 57.3–57.3 | 58.2–60.0 |

The presentation interval p95 and p99 rounded to 16.7 ms in all six steady windows.
Neither override reduced the measured latency. The defaults remain in use. These traces
use synchronous diagnostics, and the intervals describe the captured 60 Hz display.

### Verification

The release build of both products passed. With a clean configuration, 149 core tests and
7 app tests passed. The focused cases include local and names-first listings, ZIP directory
handling, catalog invalidation, bounded generator reads, visible-job order, duplicate cell
requests and trackpad pan. The captured reports, profiles and run scripts are retained under
`.build/interactive-perf`.

### Queue priority during the background delay

The preceding release is the control. After current-photo work ends, the key
window can start one on-screen thumbnail job during the existing 100 ms
background delay, provided the thumbnail generator has no jobs in flight.
File View reports the on-screen count separately from its margin. The margin,
other windows and background traversal keep the delay. Existing slot limits,
utility QoS and cancellation on renewed current-photo activity apply.

Five paired release runs alternated order using the interactive replay above on
the same M4 Max, with fresh thumbnail catalogs and ordinarily warm source pages.
A separate six-second `sample` captured each build. The change also passed a
controlled test with the normal background delay exaggerated to ten seconds.
While the current photo was busy the store started no thumbnail reads. Once it
finished, the visible thumbnail completed within the test window and the margin
stayed queued.

| First pass action | Control wall p50 / p95 / p99 (ms) | Tuned wall p50 / p95 / p99 (ms) |
| --- | ---: | ---: |
| Viewer photo | 251 / 304 / 304 | 249 / 310 / 310 |
| First strip thumbnail | 157 / 166 / 166 | 157 / 168 / 168 |
| Visible strip filled | 313 / 321 / 321 | 235 / 241 / 241 |
| File View first thumbnail | 561 / 569 / 569 | 538 / 547 / 547 |
| File View jump to a disjoint range | 79 / 94 / 94 | 78 / 90 / 90 |

The strip filled 73–85 ms sooner in each pair. Main CPU over that interval was
28.2 / 30.1 / 30.1 → 24.2 / 24.9 / 24.9 ms. The separate navigation replay used
three alternating launches per build. Both builds qualified 27/42 first-forward
frames, 42/42 first-reverse frames and all repeat steps at the 60 ms deadline.
All folder supersession checks passed. Release Loupe and 87 thumbnail store and
queue tests passed. Raw TSVs, profiles, red/green test logs and the paired runner
are in `.build/interactive-perf`.
