# Photo cards: the cost of the marks

Spec: docs/superpowers/specs/2026-10-26-photo-cards-design.md, §4.

Machine: MacBook Pro M4 Max, 36 GB, macOS 27.0.1. **The Intel Mac's run is still owed** (the budget is checked there;
local builds are arm64 only).

## Scrolling the grid

What: HomeScreenKit `PHOTO_BENCH=<plain|marked> swift test -c release --filter PhotoCardBench`. A `HomeBrowserView` in
a 1400 × 900 window, 5 000 photos at card size 160 (no pictures), scrolled top to bottom in 200 steps; main-thread CPU
per step (`CLOCK_THREAD_CPUTIME_ID`: the tile, the layout and the Core Animation commit). "Marked": every photo not
viewed and in a pair (a dot and a chip on every card). One process per mode, three rounds each.

| Build | Median per step | p95 | Max |
|---|---|---|---|
| before (kit `main`, old `PhotoCard`) | 2.13–2.19 ms | 2.55–2.79 ms | 6.2–7.0 ms |
| after, no marks | 2.21–2.26 ms | 2.76–2.96 ms | 6.2–6.5 ms |
| after, all marked | 2.07–2.10 ms | 2.28–2.46 ms | 8.2–9.0 ms |

The rounds do not get slower. The marked max is the first steps, when the pool's cards make their dot and chip once
(a card keeps them, hidden, when reused). Run in one process, alternating modes, the later rounds grew (2.15 → 2.42 ms):
the closed windows of the earlier rounds stay alive until the test ends, an artefact of the bench, not of the cards.

## Computing the marks

What: a scratch test, debug build, 10 000 photos, `spread` on with `spread-landscape = alone`, every seventh page
wide.

| Step | Time |
|---|---|
| `Playlist` + `sorted` (the order) | 42–46 ms |
| `PhotoMarks.unseen` | 4.6–6.1 ms |
| `PhotoMarks.paired` | 6.6–7.4 ms |

The order was made on every send at first (each return from the viewer, each arrival of aspects); it is now made once
per listing and sort (`FolderBrowserSource.markOrder`), so a return from the viewer pays only the two marks.
