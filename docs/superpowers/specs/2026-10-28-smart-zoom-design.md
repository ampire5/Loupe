# Smart zoom

The owner's request of 2026-10-28: use the screen better when stepping, and zoom to what matters in a photo. Decided
with the owner on 2026-10-28, in this order: the screen's share is kept by area; a command keeps its mode, a gesture
keeps the share; the pan after a step is a setting of its own (subject, keep, centre); the subject is found by a chain
that falls back (face → person → object → saliency); several subjects are framed together; a subject zoom is an
explicit command; boxes that come late may still glide the view, but only before the user touched it.

Zoom and pan are two separate things: what scale the next photo opens at (§1, §3) and where its view lands (§2).

## 1. Keeping the screen's share (`keep-zoom-as=screen`)

`keep-zoom-as` (a folder key, `ZoomCarry`) gets a third value next to `share` and `scale`:

- **`screen`:** the next photo covers the same share of the view's area as the photo before did. The share is the
  area of the photo's on-screen rect clipped to the view, divided by the view's area. A photo that would need to be
  cut to reach the share is cut, without a limit: a share of 100 % fills the view, whatever the shape (as Fill does).
  The scale is still bounded by the zoom's limits (the same as a pinch's); at the bound the share is less.
- **What decides between a mode and the share is how the zoom was reached:**
  - an explicit command (a key, the menu, the toolbar, a mouse button bound to an action: Fit, Fill, Fit Width,
    Fit Height, 100 %, Zoom to Subject) makes a named mode, which is carried as it is today;
  - a gesture (pinch, wheel zoom, right-button zoom, thumb wheel, `=` / `-`) makes a free zoom, carried as the share.
    A gesture that stops on a zoom stop (`zoom-stops`, e.g. Fit Width) is still a gesture: `ViewTransform` keeps
    where the zoom came from, not only the scale it ended at.
- The window resized keeps the share as well (the view's area changes, the share does not).
- The status's zoom slot reads `Screen 72 %` for a carried share (the slot's sample grows to fit it).

## 2. The pan after a step (`step-pan`)

A new key, a folder key like the zoom keys: where the view lands when the new photo does not fit in the view.

- **`keep`** — the same place, in proportion (the photo before's view centre as a fraction of its size). This is what
  `keep-zoom-position=yes` does today for the centre.
- **`center`** — the photo's centre.
- **`subject`** (default) — centred on the subject's frame (§4), clamped to the photo's bounds. Until its boxes are in:
  the top of a photo taller than the view's shape, the centre otherwise; then §5's glide.

`step-pan` applies to every step, whether `keep-zoom-position` keeps the zoom or the photo opens in
`default-zoom-mode`; `keep-zoom-position` now decides the zoom only. No migration: the old centre-keeping is
`step-pan=keep`. (A migration from `keep-zoom-position=yes` would have defeated the `subject` default, since that is
everyone's value.)

`K` (`toggle-zoom-carry`) cycles `keep-zoom-as` share → scale → screen for the folder; the toast names the new value.

## 3. Zoom to Subject

A command (`zoom-subject` in input.conf, built-in `Shift+z`, next to `z` Fit ↔ 100 %; View › Zoom to Subject; a button
in the toolbar's zoom block, lit while active).

- The first press zooms, animated (`zoom-animation`), to the subject's frame (§4).
- The second press goes back to the view before the first one.
- While active it is the named mode `.subject`: a step opens the next photo at its subject's frame (carried as a mode,
  §1). Any other zoom command or a gesture leaves it.
- No subject found: the photo stays at Fit and a toast says `No subject`.
- The status's zoom slot reads `Subject 140 %`.

### 3.1 Where a gesture zooms (`zoom-anchor`)

Added on 2026-10-28 at the owner's request. A new key, a folder key: the point a gesture zoom (pinch, wheel zoom,
right-button zoom, thumb wheel) keeps in place.

- **`pointer`** (default) — the spot under the pointer, as today.
- **`center`** — the view's centre.
- **`subject`** — the centre of the subject's frame (§4) on screen: the view moves towards the subject as it zooms
  in. Until the photo's boxes are in, the pointer.

`zoom-at-pointer` keeps its meaning (whether the anchor may also move an axis on which the photo is smaller than the
window); it applies to all three anchors. A step after any gesture zoom sets the centre anew by `step-pan` (§2), so a
pointer-anchored zoom leaves no small offset on the next photo; only `step-pan=keep` keeps the place, on purpose.

### 3.3 The zoom block's two sets, and where smart zoom looks

Added on 2026-10-28 at the owner's request; supersedes the single Zoom to Subject button of §3.2.

- The zoom block shows the classic modes (Fit, 100 %, Fit Width, Fit Height, Fill) or the smart ones; a button before
  them switches (magnifying glass: classic, sparkles: smart), and so does `g` (a toast names the set). The set is the
  app's, kept across launches.
- The smart modes, the one on screen lit: *Subject* (Zoom to Subject, §3), *Screen Share* (the zoom on screen becomes a
  free zoom whose share of the screen the folder keeps, `keep-zoom-as=screen`), *Fill on Subject* (Fill, centred on the
  subject).
- Keys: `0` is Fit in both sets; in the smart set `1` is Subject and `2` Screen Share (`ZoomSet.remap`, keys and mouse
  buttons only, never the menu); `3` is Fill on Subject in both.
- Where smart zoom looks (`subject-target`, now a folder key): the zoom menu's *Zoom To* group and `Alt+g` cycle the
  chains *A Face* (face, person, object, saliency), *A Person* (person, object, saliency), *An Object* (object,
  saliency), *Where the Eye Goes* (saliency).

### 3.2 The toolbar and the keys

Added on 2026-10-28 at the owner's request.

- **Toolbar:** a *Zoom to Subject* button in the zoom block (a person in a frame, lit while the mode is active). The
  zoom block's options menu (`⋯`, *More zoom options*) becomes the panel for all of smart zoom, each group with the
  current choice ticked:
  - *What the zoom keeps:* Share of the photo / Scale / Share of the screen (`keep-zoom-as`);
  - *After a step:* The subject / The same place / The centre (`step-pan`);
  - *Gesture zoom towards:* The pointer / The centre / The subject (`zoom-anchor`);
  - *Subject:* Face, Person, Object, Saliency, check boxes in the chain's order (`subject-target`);
  - *Look for subjects:* Ahead / When asked / Off (`subject-analysis`).
  A choice made there applies to the folder (as `K` does); the menu's last item saves the folder's choices as the
  defaults.
- **Keys** (built-in, rebindable in input.conf; each acts on the folder with a toast, `⇧` with it saves to loupe.conf):
  - `Shift+z` — Zoom to Subject (§3);
  - `k` — cycles `keep-zoom-as` (as today), `Shift+k` saves;
  - `Alt+k` — cycles `step-pan`, `Alt+Shift+k` saves;
  - `Alt+z` — cycles `zoom-anchor`, `Alt+Shift+z` saves.

## 4. Framing (`SubjectFraming`, LoupeCore, pure)

In: the photo's `SubjectBoxes` (§5), the settings, the oriented photo size, the view size, the zoom limits. Out: the
scale and the centre.

1. Take the first kind in `subject-target` that has boxes. Default `face,person,object,saliency`; any subset in any
   order. Faces are enlarged to the head with its hair: ×1.8 about the box's centre, shifted up by 0.15 of the box's
   height.
2. Frame all boxes of that kind together (their union) and add a margin of 8 % of the frame's size on each side.
3. Scale so the frame's height or width (whichever binds) takes `subject-size` of the view's (default 60 %,
   20…100 %); never smaller than Fit, never past the zoom's upper limit.
4. Centre on the frame, clamped so the view stays within the photo where the photo is larger than the view.

The same centre serves `step-pan=subject` at any zoom (§2).

## 5. Finding subjects

- **`SubjectBoxes` (LoupeCore):** normalised rects in the oriented photo's space, by kind: faces, people, animals,
  objects, saliency. Codable, a few dozen bytes.
- **`SubjectFinder` (app):**
  - The photo is drawn whole into a proxy of at most 1536 px from the resident pyramid by its own `TileRenderer`, as
    the subject-mask spike does (`SubjectMasker`): any format, no second decode.
  - One `VNImageRequestHandler` runs the cheap requests: face rectangles, human rectangles (whole body), animal
    recognition, attention-based saliency.
  - `VNGenerateForegroundInstanceMaskRequest` (object) runs only when the chain reaches `object` and the kinds before
    it found nothing; only its instances' bounding boxes are kept.
- **Cache:** in memory by photo, and a `subjects` table in `Loupe.db` keyed as the thumbnails are (path, size,
  modification date) with an analysis version; a photo seen before costs a lookup.
- **Scheduling (`subject-analysis`):**
  - `ahead` (default): the photo on screen first, then up to 3 photos ahead in the step direction. 1 ahead on an
    Intel Mac; both numbers measured (§7), written next to the constant.
  - `on-demand`: only for the photo on screen, and only while Zoom to Subject is active or `step-pan=subject`.
  - `off`: nothing is analysed; `subject` falls back as if no boxes were found.
  - One analysis at a time: Vision takes the neural engine and the GPU, so parallel analyses gain nothing.
  - QoS: `.userInitiated` for the photo on screen after Zoom to Subject was pressed; `.utility` for the rest.
  - It yields to the foreground: no analysis starts while the photo on screen is decoding. A step cancels the queued
    analyses that are no longer ahead.
- **Late boxes (the glide):** when the boxes of the photo on screen come in after it was shown, and within 300 ms of
  it showing, and no input touched its view since, the view glides to the subject's frame or centre (the zoom
  animation). Otherwise nothing moves; the boxes serve the next visit.

## 6. Settings

| Key | Values | Default | Folder key |
|---|---|---|---|
| `keep-zoom-as` | `share` \| `scale` \| `screen` | `share` | yes |
| `step-pan` | `subject` \| `keep` \| `center` | `subject` | yes |
| `subject-target` | a list of `face`, `person`, `object`, `saliency` | `face,person,object,saliency` | no |
| `subject-size` | 20…100 (%) | 60 | no |
| `subject-analysis` | `ahead` \| `on-demand` \| `off` | `ahead` | no |
| `zoom-anchor` | `pointer` \| `center` \| `subject` | `pointer` | yes |

Settings window, zoom page: `keep-zoom-as` gets *Screen share*; `step-pan` a pop-up beside it; a *Subject* group
with the chain (check boxes, reordered by dragging), the size slider and the analysis mode. The pop-ups fill lazily
(CLAUDE.md).

## 7. Speed

- Main thread: framing and the share are arithmetic, < 1 ms per step; no Vision, no I/O, no proxy drawing on it.
- Analysis target: ≤ 60 ms per photo for the cheap requests on an M4 Max; the object mask measured on its own.
- Bench (`docs/bench/smart-zoom.md`): analysis time per photo (cheap requests, object mask), main-thread CPU time per
  step with the features on and off (`CLOCK_THREAD_CPUTIME_ID`), fast stepping through a 200-photo folder (no round
  slower than the one before, the queue drained after the last step). M4 Max and an Intel Mac.
- Quiet at rest: with nothing ahead to analyse the finder does nothing.

## 8. Tests

- `SubjectFraming`: photo and view shapes, one and several subjects, faces enlarged, clamping at the photo's edges,
  the chain's fallback, the size's bounds against Fit and the upper limit.
- The share: carried between shapes, 100 % as Fill, at the zoom's limits, over a resize; a gesture that ends on a zoom
  stop carries the share, a command carries its mode.
- `step-pan`: each value, with `keep-zoom-position` on and off, the fallback before the boxes.
- `SubjectFinder` on fixtures: a portrait (faces), a group (several faces framed together), a full-length photo, a
  landscape without people (saliency).
- Config: the new keys parse, refuse bad values and write back (`ConfigTests`), the folder keys are taken by a folder.

## 9. Order of work

Each stage is usable on its own.

1. `keep-zoom-as=screen` and `step-pan=keep|center` (geometry, no Vision).
2. `SubjectBoxes`, `SubjectFinder`, its cache and scheduling, `step-pan=subject`, the glide.
3. Zoom to Subject (command, menu, toolbar), `subject-size`, `zoom-anchor`, the toolbar's smart zoom menu and the keys
   (§3.1, §3.2), the Settings window's group.
