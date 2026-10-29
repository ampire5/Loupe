# Viewer ↔ Folders: Return to the browser and back

Reported: a stutter when Return takes the viewer to File View (Home's Folders on the photo's folder), where the move was
expected to be quick.

What: scratchpad `browse-bench.py` (to go to `scripts/` with the other benches): a photo opened (`open-in=window`,
`session-restore=none`), then 8 rounds of Return (Folders on its folder, the photo selected) and Return (the selected
photo back in the viewer), 2.5 s apart. Each move logs what the rest of its turn of the main run loop cost, layout and
Core Animation commit included (`DebugLog.measureTurn`: `turn browse`, `turn open from browser`; main-thread CPU,
`CLOCK_THREAD_CPUTIME_ID`, and wall). Profiles: `sample` over the rounds, main thread only (self and inclusive samples
per symbol, scratchpad `sample-*.py`).

Machine: MacBook Pro M4 Max (10P + 4E), 36 GB, macOS 27.0.1, release builds (arm64); the window on the Kuycon G32P
(6144 × 3456, a calibration ICC profile) unless said. Data: `photo-share/benchmark/images` (PC share, Ethernet),
200 JPEG XL of 14000 px, thumbnails in the database.

The first round makes Home (its first show) and is left out of the medians.

| Build | Return → Folders, CPU (wall) | Folders → viewer, CPU (wall) |
|---|---|---|
| before (`e4ed221`) | 142–168 ms (185–303) | 43–55 ms (59–111) |
| sidebar redraws only changed lines | 92–99 ms (93–111) | 44–48 ms (49–66) |
| + Home parked, not taken out of the window | 39–40 ms (40–56) | 28–30 ms (30–45) |

Before, per Return to Folders (8 rounds, main thread, sample at 1 ms):

- **The sidebar redrew every line** at each change of its tree (the browser's move, its listing complete, the path's
  folders): a new `NSImage(systemSymbolName:)` and the title and count set again on every line, and every symbol image
  drawn again at the commit (`_NSSimpleImageView updateLayer`): 266 samples in `HomeSidebar.rebuild`, 296 in the
  commit's `updateLayer`. Now a line redraws only when its row, light or spinner changed, and the symbols are one image
  per name (`SidebarLineView.show`): −45 ms.
- **Home was taken out of the window when the viewer showed, and put back at the next Return**, so as not to leave a
  split view with a sidebar item in the window (the system then keeps a sidebar's room in the viewer's toolbar: in full
  screen its buttons stood 148 pt from the left edge). Each way moved the whole tree between windows: `-[NSView
  _setWindow:]` (the layout engine, vibrancy) 260 samples, the window's layout from scratch 259. Now Home stays in the
  window, hidden and parked (`HomeView.isParked`: its sidebar item collapsed without animation, so the toolbar keeps no
  room; checked by the toolbar's buttons' positions in full screen through System Events: 92 pt with parking, 240 pt
  when Home is only hidden), and the browser lays out no cards while hidden (a resize of the viewer's window waits for
  the next show): −55 ms to Folders, −17 ms back.

What is left in a Return to Folders (40 ms):

- the two toolbars swapping (`window.toolbar = …`, `-[NSToolbarView layout]` with its animation group): about 16 ms;
- Core Animation colour-matching images on the CPU for this display (`CA::Render::prepare_image` →
  `vImageConverterConvert`, ~200 samples over the run, about 12 ms a move): the Kuycon's calibration profile. On the
  built-in display (P3) the same run has 18 samples of it. Cells drawn into Display P3 BGRA when decoded did not change
  either display (202 against 193 on the Kuycon, 38 against 18 on the built-in): not done.
- the split view putting the sidebar back at its width (`setPosition`), about 2 ms.

Not measured here: Intel (the budget is ~100 ms there, CLAUDE.md), a NAS share.
