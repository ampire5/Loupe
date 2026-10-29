# Photo cards to the mockup

The owner's request of 2026-10-26 (backlog, "Interface"): the folder cards were redone (folder-cards spec), the photo
cards were not. Mockup: board «Эскизы фото тем же языком» in the canvas «Карточки папок»
(https://claude.ai/artifact/Hgk6ZE7Ge8mbbWZjH4pmMb, `project/Main.dc.html`). Decided with the owner on 2026-10-26:
the blue dot comes from the folder's position, Aspect gets the same language on the photo's outline, the grid keeps its
compact spacing and the selection ring goes inside (spacing refined on 2026-10-29).

## 1. The card (HomeScreenKit, `PhotoCard`)

All of it is drawn on the picture's rect (`pictureRect`): the slot's square in Square, the fitted photo in Aspect.

- **Picture:** restrained radius `min(6, shorterSide × 0.06)`, shared by the image, selection and last-opened outline.
- **Selection:** a 2.5 pt ring in the accent colour inside the picture, on the same radius; the dark hairline (1 pt,
  black .35) stays inside the ring so it reads on light photos. Both styles alike. The compact grid gap is 8 pt, leaving room for the separate amber last-opened outline.
- **Not yet viewed:** a dot 8 pt across in the accent colour (the mockup's `#0A84FF` is the default accent) with a
  1.5 pt white ring (white .85), 6 pt in from the picture's top right.
- **A pair:** a chip 6 pt in from the top left: the ⧉ glyph (two 6 × 10 rounded rects of a 16-unit box, 1.5 stroke,
  drawn at 12 pt by a `CAShapeLayer`) in white on `rgba(18,18,20,.58)`, radius 5, padding 2 × 3 (18 × 16 pt).
- **On hover:** a strip along the picture's bottom, `rgba(18,18,20,.6)`, padding 4 × 6, white text 10.5 pt
  (monospaced digits): the format at the left (`HomeCardItem.format`), the size at the right (`bytes`, file style).
  Shown on mouse-over only (the tracking area the card has), not for the keyboard's selection. With names on the
  photo the name's band sits right above the strip while it shows.
- **Small slots:** under `GridMetrics.minNamed` (90 pt) only the dot; no chip and no strip.
- **Layers:** the dot, the chip and the strip are made the first time they show; a card that never needs one has
  none. Off is `isHidden`, never a removed layer.

Refinement chosen by the owner on 2026-10-29: compact tiles with small gaps and restrained corners. Caption shading fades from clear to dark toward the bottom. The caption, hover strip and progress track are clipped to the image silhouette; an overlay never adds its own rounded top edge. The amber last-opened outline remains independent of the blue selection ring.

## 2. The kit API

`HomeBrowserView.setPhotoMarks(unseen: Set<String>, paired: Set<String>)`: the ids of the photos not yet viewed and
of those in a pair, for the place on screen; forgotten when the place changes (like `setUnavailable`). Binding a card
costs two set lookups. A call walks the live cards only (O(live)) and touches a card only when its marks changed.
`PhotoCard` gets `isUnseen` and `isPaired`; each change is a layer's `isHidden` (and its first creation). Minor kit
version: 0.6.0.

## 3. The marks in Loupe

Pure functions in LoupeCore (`PhotoMarks`), called by `FolderBrowserSource` on the main actor; no file is read.

- **Order:** the folder's photos in the browser's order, which the viewer follows too: `Playlist.sorted` with
  `BrowserSort.forFolder` over the listing's files and stamps.
- **Not yet viewed:** the photos after the folder's remembered photo (`FolderPositions.fileName`) in that order, and
  those modified after the visit (`FolderVisit.visited`). A folder with no remembered photo is all unviewed. The
  remembered photo itself is viewed. A remembered photo no longer in the folder: only the dates count (all unviewed
  without a visit).
- **Pairs:** only while the folder's two pages are on (`spread`). `SpreadPlan` over the same order; both pages of a
  pair get the chip. With `spread-landscape = alone` the plan needs the aspects: a `StripAspects` of the folder's
  photos (the store's memory and catalog), whose arrivals are coalesced to one per 250 ms; nil counts as portrait as
  in the viewer. Without `landscapeAlone` no aspect is asked.
- **When:** a complete listing of the folder on screen (also a provisional stored one), back from the viewer (the
  position and the visit may have moved), new aspects. Each is O(n) for the folder, n its photos.

## 4. Speed

Nothing is read from files for a card; the marks are two sets; a card's state on reuse is O(1); the dot and the chip
change their cell alone; the strip is made on the first hover. Bench before a build is handed over (CLAUDE.md,
"Interface responsiveness"): the real window, scrolling a folder of thousands, first visit and return, main-thread CPU
per action, before and after. Local builds are Apple Silicon only: the Intel Mac's run is the owner's.

## 5. Tests

- Kit: the dot, the chip and the strip where §1 puts them in both styles; no extra layers while off; small slots;
  `setPhotoMarks` changes only the cards whose marks changed.
- Loupe: `PhotoMarks.unseen` (no position, position in the middle, at the end, gone; new dates) and `PhotoMarks.paired`
  (off, shift, landscape alone).

## Outside this document

EXIF on the cards (the ProCam-style question of 2026-10-26), real per-photo viewed marks (ROADMAP "Favorites and
Viewed": would replace §3's rule), the Intel run.
