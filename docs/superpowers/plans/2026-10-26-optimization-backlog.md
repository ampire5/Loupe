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
  `Package.resolved` (edit mode drops them), as in fdc7d7d. The photo cards add `HomeBrowserView.setPhotoMarks`:
  0.6.0.

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

- **Photo thumbnail cards: done on `polish`** (spec docs/superpowers/specs/2026-10-26-photo-cards-design.md, bench
  docs/bench/2026-10-26-photo-cards.md). Left: the Intel Mac's bench; the real-window bench (scrolling a folder of
  thousands, first visit and return) on real data; HomeScreenKit 0.6.0 (`setPhotoMarks`) before the branch merges.

## Small

- `Settings.reload` skipped when the config files' mtimes did not change (an add-on of plan B, never done).
- Plan task 6 (the stamp check of a window gone back to as an ordinary read) is not done, by measurement
  (docs/bench/2026-10-26-keep-sets.md).
- Timing tests that fail under a full parallel run and pass alone: `hungLocalDiskTimesOut`,
  `evictsOldestInactiveFirst`, `shareListsNamesOnly`, `batchCommitsByTime`, `cubeBuildTime`.
