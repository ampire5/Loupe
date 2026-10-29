# Session restore one window per turn; no folder re-read on a return that missed nothing

Machine: MacBook Pro M4 Max (10P + 4E), 36 GB, macOS 27.0.1; release builds (arm64). Sides: **before** = `20d1416`
with the probe; **B** = the return rule (`FolderPollSchedule.rereadOnReturn`); **B + C** = B and the restore one window
per turn (`WindowRegistry.restoreNext`). The probe (`session opened … main X ms CPU, longest turn Y ms`) is the main
thread's CPU time (`CLOCK_THREAD_CPUTIME_ID`) of building the session's windows, the same on all sides.

## 1. Restore and returns, windows (not full screen)

What: `scripts/restore-bench.py --app <Loupe.app> --file <f1> … --file <f5>` (5 windows, `open-in=window`, quit,
relaunch with `session-restore=last`, 12 s, then 6 × Finder to the front for 2 s and Loupe back for 4 s, no
keystrokes). Counted from the `LOUPE_DEBUG` log: `activate N` lines during the restore, `folder re-read <folder>: …`
lines (a listing done) during the restore and during the 6 returns.

**PC share** (`L$`, SMB over Ethernet, a listing 15–120 ms): one 147 MP JPEG XL in each of
`photo-share/benchmark/session-{1..5}`. Screen unlocked (2026-10-26):

| Run | Build | Main CPU, all / longest turn | `activate` in restore | Re-reads in restore | Re-reads on 6 returns |
|---|---|---|---|---|---|
| beforeB_u1 | before | 261 / 261 ms | 2 | 10 | 30 |
| beforeB_u2 | before | 272 / 272 ms | 2 | 11 | 30 |
| beforeC_u1 | B | 265 / 265 ms | 2 | 5 | 5 (25 `back, no re-read`) |
| beforeC_u2 | B | 269 / 269 ms | 2 | 5 | 5 (25) |
| afterBC_u1 | B + C | 300 / 78 ms | 2 | 5 | 5 (25) |
| afterBC_u2 | B + C | 290 / 75 ms | 2 | 5 | 5 (25) |

Earlier runs of 2026-10-25, partly with the screen locked (windows then count as occluded, `paused`, and a return
re-reads nothing on any side): before 264–280 / 264–280 ms, 9–18 re-reads in the restore, 25–30 on the returns; B
231–237 / 231–237 ms; B + C 263–271 / 70–71 ms, 5 re-reads on the returns (afterBC2, unlocked).

**NAS** (`nas2`, SMB over Wi-Fi, a listing 45 ms–3.2 s): the first JPEG in each of five folders of
`photo-share/benchmark/upscaled/…` (23–56 files). Run 2 of each (run 1 of before and B logged 13 pauses/resumes — an
occlusion from outside the bench — and is left out):

| Run | Build | Main CPU, all / longest turn | `activate` in restore | Re-reads in restore | Re-reads on 6 returns |
|---|---|---|---|---|---|
| nas_beforeB_2 | before | 273 / 273 ms | 2 | 5 | 26 |
| nas_beforeC_2 | B | 279 / 279 ms | 2 | 5 | 5 (25 `back, no re-read`) |
| nas_afterBC_2 | B + C | 285 / 74 ms | 2 | 5 | 5 (25) |

## 2. The owner's scenario, full screen

What: `spikes/rust/bench/session-bench.py` (5 full-screen windows restored, 20 fast flips during the restore, END/HOME,
then per window ⌃← + 4 flips + Enter to the browser + Enter back), with its setup fixed: the first window is put in
full screen only when its `AXFullScreen` is false. ⌃⌘F toggles, and a new window may come up in full screen already
(state left in `~/Library/Application Support/Loupe` by the previous run), so the unfixed setup took some runs out
of full screen: ⌃← then switched nothing, and those runs (2026-10-26, `runs3`/`runs4`) are not compared. PC share, the
same five files.

| | before (fs1, fs2) | B + C (fs1, fs2) |
|---|---|---|
| Main CPU of the restore, all / longest turn | 299 / 299, 291 / 291 ms | 317 / 86, 339 / 111 ms |
| `session opened` after relaunch | +1.3, +1.5 s | +1.9, +2.6 s |
| `folder re-read` lines in the run | 24, 22 | 9, 10 |
| switch ⌃← → `activate`, p50 | 497, 497 ms | 478, 486 ms |
| probe (Apple Event round trip) p95 / max | 62 / 198, 64 / 173 ms | 64 / 192, 65 / 150 ms |
| stalls > 250 ms | none | none |
| fast flip during the restore → navigate, p90 | 2298, 1194 ms | 1759, 2632 ms |
| `other windows −N` at the end | −61 (10.2 GB), −63 (11.0 GB) | −115 (11.4 GB), −67 (10.8 GB) |

## Findings

- **C**: the longest main-thread turn of a 5-window restore goes from 261–300 ms to 74–111 ms, on both shares and in
  full screen; all in, 10–40 ms more (each window's turn lays its window out on its own). The other windows come later:
  `session opened` +0.6–1.1 s in full screen, the last folder listed +0.03–0.1 s in windows. C changes neither the
  activations (2 in every run, both of the front window: when it is built and when the app becomes active; the old
  restore did not make each window key either — the 4 of 2026-10-25 were noise) nor the main-thread probe.
- **B**: before, every return re-read each visible window's folder (5 windows × 6 returns = 26–30 listings, on the NAS
  each up to 3 s of Wi-Fi), and a restore 5–18. With the rule, a return re-reads only when the safety-net poll's
  interval passed since the last listing (30 s here: the 5 re-reads came on the return 33 s after the restore's
  listings) or something may have been missed (no kqueue, an event while hidden, a failed listing); the restore lists
  each folder once. In the full-screen scenario 22–24 re-reads became 9–10.
- **Not B or C**: flips during a restore wait 1–2.6 s for navigation and up to 10–22 s for the sharp photo on both
  sides, while the windows evict each other (`other windows −61…−115`, 10–11 GB): the keep sets of the
  window-ownership plan (tasks 1–3).
- **Found, both sides**: a restored full-screen session brings the wrong window to the front. With five full-screen
  windows, `laura` (s05) in front at quit, the restore ends with `dimona` (s02) in front, 4 runs of 4. The snapshot takes
  the front from `NSApp.orderedWindows`, which for windows in other Spaces is apparently not the order on screen.
- Not measured here: Intel (the one ~300 ms block was the candidate for the first freeze there,
  spikes/rust/REPORT.md §3.4; the same scripts).

## Fixed: one activation, and the window left in front comes back in front (2026-10-26)

What: scratchpad `front-check.py` (to go to `scripts/` with the other benches): five windows (`open-in=window`) on one
147 MP JPEG XL each (`PIR020_s0{1..5}_fullres`, PC share), the first put in full screen (the others follow it),
quit; this run's Last Session row read from `Loupe.db`; relaunch with `session-restore=last`, 14 s, `window 1` of the
process asked through System Events; the `activate` lines of the relaunch counted. M4 Max, release builds.

| Build | Window in front at quit | Last Session order | In front after the restore | `activate` in the restore | at quit |
|---|---|---|---|---|---|
| before (`50db527`) | s05 | s01 s02 s03 s04 s05 | s02 | 4 (all window 1) | 4 |
| after, run 1 | s05 | s05 s04 s03 s02 s01 | s05 | 1 | 4 |
| after, run 2 | s05 | s05 s04 s03 s02 s01 | s05 | 1 | 4 |
| after, quit fix | s05 | s05 s04 s03 s02 s01 | s05 | 1 | 0 |

Three causes, each fixed on its own:

- **Order.** `NSApp.orderedWindows` gives windows in full-screen Spaces in the order they were made: the snapshot
  listed the first window made as the front one. `WindowRegistry.snapshot` now orders by the last time a window was
  key, the system's order only among windows never key.
- **Front.** The launch's window enters full screen on its own, before the restore makes the others; they then
  entered theirs back to front and the last of them (the second window) kept its Space on screen, while the front
  window stayed key in a Space not shown: keys went to a window the user could not see. Once the full-screen windows
  are in, the front one is shown again (`frontAfterFullScreen`), unless the user went to another window meanwhile.
- **Activations.** An activation was sent on every visibility change of the active window (the window put on screen,
  its Space shown, occlusion); the restore's 4 `activate 1` were one activation and three visibility changes. Those
  now send only the visibility (`ImageCache.setVisibility`): one activation per restore, as spec §5 asks. At quit each
  window closing made the next one active and started its reads (4 activations, 16–20 reads); quitting, none is.
