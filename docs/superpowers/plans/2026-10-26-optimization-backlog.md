# Optimization backlog (left for later)

What is left of the optimization work of 2026-10-25/26 (spikes/rust/REPORT.md §6, the window-cache-ownership plan,
the owner's reports of 2026-10-26), with what is known of each. Done in this round: keep sets, read classes, finished
reads past half, close release, B, C, one activation per restore, the front window restored in front, viewer ↔ Folders
(docs/bench/2026-10-26-viewer-to-folders.md), the sidebar's width, names cut at the end, stored listings
(docs/bench/2026-10-26-stored-listings.md), thumbnails and covers while flipping
(docs/bench/2026-10-26-thumbs-while-flipping.md).

## Before merging

- **HomeScreenKit tag.** Loupe uses kit API newer than 0.4.0 (`HomeView.isParked`, `sidebarFoldersChanged`,
  `BrowserListing.isProvisional`): tag the kit (0.5.0), raise Loupe's `from:` and put the kit pins back in
  `Package.resolved` (edit mode drops them), as in fdc7d7d.

## Measurements still owed

- Window-ownership plan task 9: the benches of this round (branch `spike/window-ownership-bench`,
  `spikes/window-ownership/bench`; and `spikes/rust/bench/switch-bench.py` on branch `spike/rust`) into `scripts/`;
  `LoupeBench replay
  --script close` (20 open/close cycles, footprint per cycle: the plateau after closes); the final
  `docs/bench/<date>-window-ownership.md` with spec §5's acceptance.
- Intel (the ~100 ms budget is checked there): restore, viewer ↔ Folders, flips.
- The NAS over Wi-Fi: `FileReader.finishReadAbove` (0.5, the spec's starting value: on the PC share few reads are
  caught half-way), `ThumbnailStore.neighbourReads` (1; 2 not measured).

## Speed

- **The browser lists again the folder the viewer has just listed.** Return from a photo: `Playlist.relist` and
  `BrowserListingSource.names` of the same folder at once on the same share (seen in a sample on the NAS). The viewer's
  listing could serve the browser (its photos and stamps; the folders and zips still to list).
- **Two toolbars swapping** on viewer ↔ Folders: about 16 ms of the 40 left (`-[NSToolbarView layout]`).
- **Core Animation colour-matching on a calibrated display** (Kuycon G32P's profile): about 12 ms a move to Folders;
  ~1 ms on the built-in display. Cells drawn into Display P3 did not help (measured, not done).
- **A cold NAS** takes up to a minute for a big folder's dates (2 017 files: names 16 s, `ls -l` 51 s): paged listings
  of the dates, or the dates of the photos in view first.
- Stored listings: a names-only stored listing sorted by date waits for the share's dates as before; capacity (2 000
  folders) by measurement of `Catalog.db`'s size on a real library.

## Memory (spikes/rust/REPORT.md, memory-audit.md)

- After memory pressure the limits come back 30 s later and the neighbours load again: an oscillation.
- Decodes in flight (up to 4 × 0.6 GB plus libjpeg's buffers) are outside the budget and cannot be cancelled.
- `ThumbnailCells` is bounded by count (300), not bytes: up to ~1.2 GB of CGImage.

## Interface

- **Sidebar folders folding while scrolling up from deep down** (owner's report): not reproduced with the wheel on the
  PC share's tree; the width part of the report was the split view's own moves taken as the user's (fixed). Needs the
  owner's exact steps (the wheel in the sidebar, or ⌘↑ / Back up the folders; which depth). Suspect: compact chains
  (`a › b › c`) re-forming as the current folder moves up.
- **The sidebar's divider is hard to grab** (a thin native divider).
- Names cut in the middle elsewhere: the stats bar's folder label, the viewer's toolbar title, the Stash bar
  (`byTruncatingMiddle`); the sidebar's now cut at the end.

- **Photo thumbnail cards are not laid out to the mockup** (owner's request of 2026-10-26; the folder cards were
  redone, the photo ones were not: folder-cards spec, "Вне документа"). Mockup: board «Эскизы фото тем же языком» in
  the canvas «Карточки папок» (https://claude.ai/artifact/Hgk6ZE7Ge8mbbWZjH4pmMb, `Main.dc.html`; the canvas is not in
  the repository: export the three boards into `docs/` first). It shows a 104 pt square, radius 8, no text by default;
  a blue dot (8 pt, 1.5 pt white ring) 6 pt in from the top right for a photo not yet viewed; a ⧉ chip (12 pt glyph on
  `rgba(18,18,20,.58)`, radius 5) at the top left for a pair; on hover a strip along the bottom (`rgba(18,18,20,.6)`,
  10.5 pt) with the format at the left and the size at the right; the selection a 2.5 pt `#0A84FF` ring outside the
  picture. Today `PhotoCard` (HomeScreenKit) has radius 1 (Square) or 4 (Aspect), the ring inside, and the name, and
  none of the dot, the chip or the strip. To decide: what Aspect mode does with the mockup (it shows only squares).
  Needs: viewed marks (ROADMAP "Favorites and Viewed"; without them no dot), the pair flag from the folder's spread
  keys, format from the extension and size from the listing's stat. New kit API needs a kit tag.
  **Must not cost speed:** nothing read from files for a card (only the listing's name, size, stamp); the viewed set
  is one in-memory lookup per visible cell, never a query per cell; the hover strip is made on first hover, not with
  every cell, and the off states add no layers; setting a card's state on reuse is O(1) and changes nothing else in
  the grid; the dot and the chip change a cell alone, not the whole grid. Bench before a build is handed over
  (CLAUDE.md, "Interface responsiveness"): the real window, scrolling a folder of thousands, first visit and return,
  main-thread CPU per action, on the Intel Mac.

## Small

- `Settings.reload` skipped when the config files' mtimes did not change (an add-on of plan B, never done).
- Plan task 6 (the stamp check of a window gone back to as an ordinary read) is not done, by measurement
  (docs/bench/2026-10-26-keep-sets.md).
- Timing tests that fail under a full parallel run and pass alone: `hungLocalDiskTimesOut`,
  `evictsOldestInactiveFirst`, `shareListsNamesOnly`, `batchCommitsByTime`, `cubeBuildTime`.
