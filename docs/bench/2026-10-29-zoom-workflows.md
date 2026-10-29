# Separate Manual and SmartZoom workflows

Machine: Mac16,6, Apple Silicon. Same release dependencies as SmartZoom-2. Intel unavailable; these are local measurements only.

## Behavior checks

The real ViewerWindowController benchmark uses neutral 001.png/002.png fixtures and injected object boxes. `LOUPE_BENCH_WINDOW_RULES=1 LOUPE_BENCH_SMARTZOOM=1 LOUPE_BENCH_PANEL=1` with a disposable `LOUPE_CONFIG_DIR` verifies:

- Manual keeps 100%, free zoom, Fit Width and relative position during ordinary photo steps.
- 0 preserves the selected profile.
- Shift-Z repeatedly enters/reapplies Auto; the legacy mouse action does the same.
- Actual clicks on toolbar Manual/SmartZoom select Manual/Auto.
- A fixed ordinary preset enters Manual.
- Folder saves have disjoint scopes; saving inactive Smart preferences does not enable Smart.
- Power exits without moving the view, and resumes the last Smart mode.
- Manual zoom does not teach a new profile target size on the next photo.
- Status states workflow, Smart mode, profile, selected group and actual zoom.

All checks pass in `/tmp/loupe-workflows-window-final.log`.

## Main-thread CPU time

Measured with CLOCK_THREAD_CPUTIME_ID in actual window callbacks, five rounds. Maxima in ms:

| Action | ms |
|---|---:|
| Construct/open window | 113.165 |
| Click SmartZoom workflow control | 0.349 |
| First SmartZoom panel visit | 39.806 |
| Change Manual/Smart mode | 5.798 |
| Next group | 8.497 |
| Weight adjustment | 2.606 |
| Return to retained panel | 0.218 |

No growing trend. The benchmark activates its window and asserts panel construction, preventing an occluded-window no-op from being reported as panel performance.

Visual inspection caught the long workflow status displacing toolbar buttons. The chip is now bounded to 220–480 pt (preferred 400), with position/name/dimensions above a single-line workflow label. Full text is in tooltips. Primary workflow and panel controls have priority over status. The status screenshot is `/tmp/loupe-zoom-workflows-window.png`; Metal photo pixels are outside AppKit cacheDisplay capture.

## Tests

Full sequential run: 2170 Core tests and 63 Settings tests pass, `/tmp/loupe-workflows-tests-final.log`. The unchanged ImageCache test `queuedReadyDecodeIsAbandonedNotAwaited` failed trace-event timing assertions in two earlier full runs; it passed isolated (0.036 s) and in the final full run. No cache/decoder source was changed. Later focused ordinary-key/label/menu/profile tests pass after fixing numeric 3 to ordinary Fill.
