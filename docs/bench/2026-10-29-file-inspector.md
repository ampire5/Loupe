# File View inspector — 2026-10-29

Follow-up: [lazy creation and startup audit](2026-10-29-lazy-startup.md) separates hidden-startup cost from first visible opening and records the deferred implementation. The measurements below describe the initial implementation.

## Method

MacBook Pro, Apple M4 Max (14 physical cores: 10 performance + 4 efficiency), 36 GB RAM; macOS 27 SDK/runtime. `LoupeBench inspector [screenshot.png]` opens the real HomeView, native toolbar, split inspector and AppKit controls in a 1160 × 820 pt window. A 1000-file synthetic listing and synthetic EXIF isolate UI work from disk/network latency. Some files carry a 22 KB generation description to exercise bounded summary layout. Each of three rounds selects 20 files with real arrow-key events and closes/reopens the inspector five times. CPU is `CLOCK_THREAD_CPUTIME_ID` on the main thread, including run-loop layout and drawing after each action. Initial creation is separate from returns. No network-throughput or real-file metadata latency claim follows from this benchmark.

Run after building LoupeBench with the repository's decoder environment:

```sh
source scripts/libjxl-env.sh
swift build --jobs 4 -c release --triple "$DEPS_TRIPLE" --product LoupeBench
.build/release/LoupeBench inspector /tmp/loupe-inspector.png
```

## Results (ms main-thread CPU)

| Build / round | Selection median | Selection max | Reopen median | Reopen max |
| --- | ---: | ---: | ---: | ---: |
| Debug / 1 | 10.416 | 15.550 | 18.259 | 18.736 |
| Debug / 2 | 8.855 | 10.336 | 20.197 | 21.236 |
| Debug / 3 | 8.292 | 9.694 | 20.228 | 20.612 |
| Release / 1 | 9.520 | 15.348 | 18.852 | 20.062 |
| Release / 2 | 8.940 | 10.259 | 19.793 | 21.585 |
| Release / 3 | 8.671 | 10.072 | 18.945 | 21.838 |

First construction/open: debug 107.422 ms; release 112.080 ms. Release breakdown: controller initialization 5.611 ms, native split installation 1.245 ms, synchronous layout/display 56.076 ms, subsequent run-loop work 49.149 ms. This first construction exceeds the approximate 100 ms screen budget slightly on this machine; it is not evidence of meeting the Intel budget. Home installs the inspector once and retains it, so repeated toggles do not reconstruct controls. A separate 1 ms `sample` during startup/first open showed AppKit layout/toolbar work and mostly waiting; it did not establish an expensive metadata symbol on the main thread. No speculative timing fix was made from that short sample.

The measured return/selection rounds do not show monotonically accumulating selection work. Reopen medians remain about 19–20 ms. Inspecting the captured real window confirmed readable labels, wrapping values, no overlap, native disclosure controls and a docked right pane. Intel hardware, real slow shares, and very large ZIP entries remain separate validation requirements.

## Bounded work

- One metadata reader in flight per inspector, with a single replaceable pending selection. It is a correctness bound: a cancelled native read cannot be interrupted safely, so no replacement reader starts before it finishes.
- A 120 ms settling interval avoids starting native reads for transient selections. This is an interaction choice, not a claim that all files can be read within 120 ms; known listing facts update immediately.
- At most 24 successful results retained by path + size + modification date; entries without a complete stamp are not cached. Previews come from ThumbnailStore, bounded to 160 px on the long side (at most about 100 KB of RGBA pixels each, about 2.4 MB for all 24). Existing PNG text parsing caps individual displayed embedded texts at 64 KB. Metadata outside PNG follows the existing PhotoMetadata reader's limits.
- Closing, parking, occlusion and native tab visibility discard pending reads. An in-flight synchronous read may finish but cannot update a different selection or a hidden inspector. No File View diagnostics timer or idle polling.
- Native divider collapse is reconciled through KVO, so a visually hidden inspector also stops new work. Catalog facts arriving for the same identity/stamp enrich the summary without restarting its read.

## Verification

Focused loader/content tests cover latest-only scheduling, stale reply rejection, cache reuse, hide/reshow while a read is running, empty selection, and enrichment of an in-flight selection. HomeScreenKit tests cover selection/listing/empty results, late thumbnail facts, native collapse and parking without rebuilding its controller. All kit suites pass (673 tests across eight test products); the final Loupe core run passes 2206 tests and settings passes 63 tests. Render tests pass 136 tests in 7 suites. A concurrent Photos integration test, `PhotosBrowserTests.leavingPhotosViewerRemovesItsCurrentReadPriority`, failed in the overall run; it is outside the inspector change and remains tracked in that work. The inspector does not issue reads for Photos/source URLs.

HomeScreenKit is being consumed in its existing edit mode on the matching branch. `scripts/kits-check.py` reports the missing HomeScreenKit release pin. Release the combined kit branch first, then update Package.swift/Package.resolved outside edit mode before distributing a tagged Loupe build.
