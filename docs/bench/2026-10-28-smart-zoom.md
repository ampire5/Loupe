# Smart zoom: the subject analysis

Smart zoom spec §7 (`docs/superpowers/specs/2026-10-28-smart-zoom-design.md`). What `SubjectFinder` spends per photo
off the main thread, measured with `LoupeBench subjects <folder>` (`Sources/LoupeBench/SubjectsBench.swift`): a proxy
of at most 1536 px made with ImageIO (not timed), then `SubjectDetector.boxes` with the cheap requests (face, person,
saliency in one handler) and, apart, the foreground-instance mask (`object`).

## 2026-10-28, M4 Max (Apple silicon), macOS 27, release build

207 portraits of 2944×4416 (one photo session, people in every frame), proxy 1024×1536; `nice -n 10`.
Faces found in 207, people in 203, foreground objects in 207.

| request | first (warm-up), ms | median, ms | p90, ms | max, ms |
|---|---|---|---|---|
| face + person + saliency | 104 | 11 | 14 | 22 |
| foreground mask (object) | 88 | 19 | 22 | 31 |

In the app, `LOUPE_DEBUG`'s `subjects` line (the proxy drawn from the resident pyramid and read back, plus the
analysis): 26–34 ms per photo ahead, 217–286 ms for the first photo of a launch (Vision's models loading).

- The target (≤ 60 ms per photo for the cheap requests) holds with room: a photo ahead is ready long before a step at
  any human pace, so `SubjectFinder.aheadLimit` = 3 costs ~100 ms of one background thread per three photos.
- The foreground mask runs only when the chain reaches `object` with nothing found before it (never on these
  portraits: a face is always found first).

## Intel

Not measured: no Intel Mac at hand. Vision runs on the CPU there, several times slower than the neural engine;
`aheadLimit` is 1 on x86_64 until a measurement says otherwise.

# Framing while browsing: `SubjectFraming.pan`

`pan` chooses where the view of a framed photo is centred, on the main thread, several times per step (the arrival
mode, the cache's focus, the layout). It tries every place where a box's edge meets the view's (2n + 3 per axis for n
other boxes) and sums every box's visible share at each: before, the view intersected with every box at every place,
~4n³ rect intersections a call. Now each axis's overlaps are measured once per place and box, places that clamping
makes equal are tried once, and only the boxes overlapped across at a column are summed; the result is the same
(`theFasterPanAgreesWithTheReference` compares it with the old one on 600 cases, ties and empty boxes included).

## 2026-10-28, M4 Max (Apple silicon), release (`-O`)

Random boxes 0.02–0.2 of the photo's side, the window 0.3 and 0.8 of the photo, 20 calls each; ms per call.

| boxes | window | before, ms | after, ms |
|---|---|---|---|
| 10 | 0.3 / 0.8 | 0.06 / 0.13 | 0.006 / 0.005 |
| 20 | 0.3 / 0.8 | 0.69 / 1.25 | 0.009 / 0.010 |
| 40 | 0.3 / 0.8 | 5.4 / 8.9 | 0.03 / 0.03 |
| 80 | 0.3 / 0.8 | 40 / 73 | 0.12 / 0.14 |
| 160 | 0.3 / 0.8 | 343 / 578 | 0.54 / 1.09 |

- Before, a group photo (40–80 faces, people, objects and detections) cost tens of ms a call, several calls a step:
  past the step's ~100 ms budget on an Intel Mac. After, under a ms at 160 boxes: nothing to cache.
- How many boxes real photos carry is not measured yet (the portraits above have a few); synthetic counts bound it.
- Intel: not measured (no Intel Mac at hand).

# Show Subjects (⇧G) during a zoom

Owner, 2026-10-28: with Show Subjects on, zooming and panning stuttered. Every frame (`ViewerView.sessionDidChange`)
asked the overlay to draw again: the whole window's backing store (4300×2162 px here) drawn on the CPU in the
Core Animation commit, the caption laid out again, the overlay's model made anew. Now the boxes are shape layers and
the labels text layers, made when the boxes, the chain or the crop change; a frame only sets their paths and places.

## 2026-10-28, M4 Max, release, `LOUPE_AUTOPAN_MODE=zoom` (fit…300 %, 120 Hz) with `LOUPE_AUTOPAN_SUBJECTS=1`

A 6016×6016 HEIC (one saliency box, the frame and the cross), the window 4300×2162 px; `sample` of the main thread for
6 s in the middle of the run (1 ms a sample, ~720 frames).

| main thread | before, samples | after, samples |
|---|---|---|
| busy (not waiting in the run loop) | 510 (14.5 %) | 344 (9.5 %) |
| `SubjectOverlayView` | 62 | 32 |
| `CA::Transaction::commit` (the overlay's CPU drawing was here) | 234 | 68 |

- ~0.7 ms of main-thread time a frame before, ~0.5 ms after; the overlay's own part from ~0.3 ms to ~0.05 ms.
- The window server's side (compositing a window-sized transparent layer, uploading its backing store every frame)
  is not in these figures: the run was not on screen ("not presented"), so the presentation latency could not be
  compared. A window-sized CPU backing store redrawn at 120 Hz is the likelier cause of the stutter than the
  main-thread time itself; to be confirmed on screen.
- Intel: not measured.
