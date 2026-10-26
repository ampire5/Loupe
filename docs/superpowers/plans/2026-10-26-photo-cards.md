# Photo Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The browser's photo cards drawn as the mockup: radius 8, the ring inside, the not-viewed dot, the ⧉ chip
of a pair, the format and size strip on hover.

**Architecture:** HomeScreenKit draws (`PhotoCard`) and takes the marks as two id sets
(`HomeBrowserView.setPhotoMarks`); Loupe computes the sets (`PhotoMarks` in LoupeCore) from the folder's remembered
photo, its visit, its two-page keys and the store's aspects, and `FolderBrowserSource` sends them.

**Tech Stack:** Swift 6, AppKit + Core Animation, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-26-photo-cards-design.md`

## Global Constraints

- Kit work on HomeScreenKit's branch `polish` (Loupe's branch); Loupe builds it in edit mode; Package.resolved is not
  committed from edit mode. New API: kit minor version 0.6.0 when the branch closes.
- Nothing read from files for a card; the marks are one set lookup each per bind; a mark changes its card alone.
- The dot, the chip and the strip are made on first need; off is `isHidden`.
- Local builds arm64 only; the Intel bench is the owner's.

## Review Focus

- A card reused from the pool while the pointer is over it: the strip must not stay on the new photo
  (task 1: `stripHidesOnReuse`).
- A photo with no `bytes` or no `format`: the strip shows what there is, never "nil" (task 1: `stripWithoutSize`).
- A folder the viewer never opened: every photo dotted (task 3: `noPositionAllUnseen`).
- A remembered photo deleted since: dates alone decide (task 3: `goneFileByDates`).
- Two pages turned on with unknown aspects: pairs by index as the viewer does (task 3: `unknownAspectsPair`).

---

### Task 1: `PhotoCard` to the mockup (kit)

**Files:** Modify `Sources/HomeChrome/Chrome.swift` (`Radius.photo = 8`), `Sources/HomeScreenKit/PhotoCard.swift`;
Test `Tests/HomeScreenKitTests/GridCardTests.swift`.

**Produces:** `PhotoCard.isUnseen: Bool`, `PhotoCard.isPaired: Bool`, `PhotoCard.isHovered: Bool` (set by
mouseEntered/Exited, false on `show` of another id), read-only `dotLayer: CALayer?`, `chipLayer: CALayer?`,
`strip: NSView?` (nil until first needed), `stripText: (format: String, size: String)`.

- [ ] Tests: `photoRadiusEight` (picture and ring `cornerRadius == 8` in both styles; Aspect 300×20 image: at most half
  the short side); `ringInsideBothStyles` (ring frame == pictureRect, width 2.5; hairline inset 2.5);
  `marksOffAddNoLayers` (fresh card: `dotLayer == nil`, `chipLayer == nil`, `strip == nil`); `dotTopRight` (unseen,
  200 Square: dot frame `(186, 6, 8, 8)`; Aspect: 6 pt in from the fitted image's corner); `chipTopLeft` (paired: frame
  origin `(6, 6)`, size 18×16); `smallSlotOnlyDot` (80 pt: chip and strip hidden though paired and hovered, dot shown);
  `stripOnHover` (hovered with format "JXL", bytes 24_000_000: strip at picture's bottom, full width, text "JXL" /
  "24 MB" as `ByteCountFormatter` `.file`); `stripWithoutSize`; `stripHidesOnReuse` (hovered, `show` of item id "b":
  strip hidden).
- [ ] Run `swift test --filter GridCardTests` in HomeScreenKit: new tests fail.
- [ ] Implement per spec §1. Old tests on ring width 3 / radius 1 / 4 updated to the new values.
- [ ] Tests pass; commit `PhotoCard: radius 8, the ring inside, the not-viewed dot, the pair chip, the hover strip`.

### Task 2: `HomeBrowserView.setPhotoMarks` (kit)

**Files:** Modify `Sources/HomeScreenKit/HomeBrowserView.swift` (state beside `unavailable`, `configure`, the place
change that clears `unavailable`); Test `Tests/HomeScreenKitTests/HomeBrowserGridTests.swift`.

**Produces:** `public func setPhotoMarks(unseen: Set<String>, paired: Set<String>)`.

- [ ] Tests: `photoMarksReachLiveCards` (a folder of photos shown; marks set: the live `PhotoCard`s with those ids have
  `isUnseen` / `isPaired`, others not); `photoMarksBindOnScroll` (a card laid out after the call gets its marks);
  `photoMarksForgottenOnPlaceChange`.
- [ ] Implement: store both sets; walk `live` and set the two flags only where they differ; `configure` sets them from
  the sets for a `PhotoCard`; cleared where `unavailable` is.
- [ ] Tests pass (whole kit suite); commit `Browser: setPhotoMarks, the not-viewed and pair marks of the photos`.

### Task 3: `PhotoMarks` (Loupe, pure)

**Files:** Create `Sources/LoupeCore/PhotoMarks.swift`; Test `Tests/LoupeCoreTests/PhotoMarksTests.swift`.

**Produces:**
- `PhotoMarks.unseen(order: [URL], remembered: String?, visit: FolderVisit?, modified: (URL) -> Date?) -> Set<URL>`
- `PhotoMarks.paired(order: [URL], rules: SpreadRules, aspects: [Double?]) -> Set<URL>` (`aspects` parallel to
  `order`, [] when not needed; sizes through `SpreadSizes.sizes(files:aspects:headers: [:])`).

- [ ] Tests: `noPositionAllUnseen`; `afterRememberedUnseen` (5 files, remembered 3rd → 4th, 5th); `rememberedLastNone`;
  `newerThanVisitUnseen` (remembered last, 2nd modified after `visit.visited` → {2nd}); `goneFileByDates`;
  `pairedOff` (rules off → []); `pairedAll` (4 files, no shift → all 4); `pairedShift` (shift, 4 files → 2nd, 3rd);
  `landscapeAlone` (aspect 1.5 at index 1 → only 3rd, 4th pair); `unknownAspectsPair` (aspects all nil → as portrait).
- [ ] Run `swift test --filter PhotoMarksTests`: fail; implement; pass; commit `PhotoMarks: which photos of a folder
  are not viewed yet and which are in a pair`.

### Task 4: `FolderBrowserSource` sends the marks (Loupe)

**Files:** Modify `Sources/Loupe/FolderBrowserSource.swift`.

**Consumes:** tasks 2, 3. `Playlist(files:current:stamps:).sorted(BrowserSort.forFolder(folder, settings:))` for the
order; `positions.fileName(in:)`, `positions.visit(in:)`; `FolderCardFacts.config(for:base:settings:)` →
`SpreadRules(config:)`; a `StripAspects` (fetch `thumbnails.aspects`) made only while `rules.on &&
options.landscapeAlone`, its `onChange` → resend; `thumbnailChanged` → `thumbnailArrived`.

- [ ] `private func sendPhotoMarks()`: from `shownFiles` + `stamps`, ids via `shown` (url → id map built in
  `remember`); called after `deliver` / `deliverStored` of the folder on screen, on unpause (beside
  `showSummaries()`), on aspects' change. Not on Home's own sources.
- [ ] `swift build` and the Loupe suite green; commit `Home: photo cards show not-viewed and pair marks`.

### Task 5: Bench, run, docs

- [ ] Kit-side bench numbers: `LoupeBench` scrolling scenario if one exists for the browser grid, else a timing of
  `setPhotoMarks` + layout over 5 000 cards in the kit tests' style; result in `docs/bench/2026-10-26-photo-cards.md`.
- [ ] Build and run the app (arm64), screenshot of a folder's grid (window only), look checked against the mockup.
- [ ] Backlog entry updated (done, Intel run owed); commit.
