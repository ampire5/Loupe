# Thumbnail settings and per-file viewing history

Measured locally on 2026-10-30, M4 Max (14 physical cores, 36 GB), macOS 27.2. Intel is not measured.

Settings → Strip → Thumbnails now has Thumbnail format (JPEG/HEIC/AVIF) and whole-number Thumbnail quality (10–100, default 80). The existing native SettingsKit controls write per-app preferences, validate, notify and reset without editing loupe.conf. Changes apply to the process encoding snapshot after restart; only disposable thumbnail payloads are rebuilt. File-menu cache cleanup and Performance → Catalog remain available. Viewing history is not disposable cache data.

`FileViewHistory` stores addressed path/source-URL timestamps in Application Support/Loupe/Loupe.db, using additive `file_views` schema. No startup history scan. One serial utility writer and bounded admitted receipts (64) avoid unbounded queued writes; pair admission is atomic. A saturated writer retains the prior rendered snapshot and retries when capacity returns, while input remains responsive. Unpresented receipts release their reservation. Successful timestamps merge by MAX, and live row updates are monotonic. In-flight address tokens follow local renames without remapping newly reused names. Source URLs remain source keys. Disk-unavailable storage uses a bounded in-memory fallback, like other user-state stores.

## Actual presentation validation

A one-shot receipt is attached only to a visible, intersecting rendered page. `CAMetalDrawable.addPresentedHandler` records only positive `presentedTime`. The visibility interval is retained per receipt so a delayed pre-hide presentation is valid and a hidden/later interval is not. Refinement, zoom and colour frames reuse the completed receipt. Preview generation and selection without a rendered frame never call the history writer.

The first single-frame harness returned presentedTime=0. A diagnostic continual-redraw variant confirmed presentation after the first three drawables were dropped; changing presentation call order alone was not the cause. The final implementation preserves the existing command-buffer presentation order and permits at most 16 presentation attempts per receipt, stopping immediately when confirmed. It then uses the existing idle grace and pauses; there is no endless repaint or timer.

Real `ViewerWindowController`, generated local PNGs, normal NSApplication.run: `Loupe --file-view-history-bench` (debug build) PASS with the production path. Checks cover visible photo recorded, another prefetched/unshown file absent, refinement does not retime, hidden photo absent, reveal records, previous timestamp retained. The earlier SwiftPM GUI experiment was replaced by this real-app benchmark because a unit-test process was not a dependable presentation harness. No history credit was substituted from mere decode/GPU completion.

## Settings CPU

Real window, three rounds, `LoupeBench settings --rounds 3 --settle 150 --icons 0 --start colour`; CLOCK_THREAD_CPUTIME_ID, first visit and returns separately. Values in ms:

| Operation | First CPU | Longest first block | Return median/max |
|---|---:|---:|---:|
| Open on Colour |282|—|—|
| Switch to Strip (includes new rows) |157|24|10/10|

Round totals 773/136/135 ms; no accumulation on returns. At rest 2 ms main CPU in 2 s. A single setting change 10–12 ms. First-visit aggregate exceeds the ~100 ms category target; its largest contiguous block is 24 ms. No extra performance optimization was added to this feature task.

## Verification

Independent read-only review found and re-reviewed fixes for rename-after-admission, partial-spread deadlock and stale live notifications; no remaining finding in that review. Tests cover persistence/reopen, real separate cache removal, failed/hidden presentation, later/older dates, source keys, delayed rename, atomic admission, bounded retries and preferences/rows/reset/validation.

Full HomeScreenKit: 684 tests passed across its test products. Repository Loupe standard run: 2252 tests, 7 skips; two existing strict timing checks in ThumbnailCoversTests exceeded their deadlines under the parallel full run (`hungResolveTimesOut`, `hungLocalDiskTimesOut`). Both passed independently with no parallel execution (0.105/0.118s). Their limits were not weakened, and the complete parallel run is not reported as all-green. Release polish-3 built and installed locally; no merge/push/tag.
