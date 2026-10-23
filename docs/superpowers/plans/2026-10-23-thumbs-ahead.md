# Thumbnails Ahead Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Home prepares the covers and summaries of the visible cards' subfolders ahead of time and a whole subtree on command, pauses on demand, and shows how far it is — a progress pill in the toolbar, shimmering waiting cards, and "viewed 3 d ago" on the cards.

**Architecture:** The existing machinery does the work — `ThumbnailStore`'s generator for files, `CoverQueue` → `ThumbnailStore.folderCard` for covers and summaries — with two additions in LoupeCore: subfolder cards of visible cards fed to the cover queue after the folder's own files (stage 4), and a bounded subtree walk on command (stage 5). Progress counters come from those three places into one `ThumbsProgress` value in `FolderBrowserSource`, handed to the kit's `HomeBrowserView.setProgress(_:)`; the kit draws the pill (`ThumbsProgressPill` in `HomeToolbar`), the shimmer on waiting `FolderCard`s and the recency words.

**Tech Stack:** Swift 6, AppKit, Core Animation, Swift Testing; kit tests `swift test` (HomeScreenKit root), app tests `scripts/test.sh` (bare `swift test` does not link in Loupe), build `LOUPE_BUILD_LABEL=L20 scripts/make-app.sh`.

**Spec:** `docs/superpowers/specs/2026-10-23-thumbs-ahead-design.md`

## Global Constraints

- Repos: HomeScreenKit branch `folder-cards` (base 05371bf), Loupe LTS checkout branch `folder-cards-lts` (base 01636f2); kit linked via `swift package edit`. Never stage `Package.resolved`, `release.yaml`, `Packages/`; stage files by name. Commit identity and message trailer as the SDD `common.md` says. Never push.
- Public project: no home paths, user names, volume/share/server names, real folder or file names, e-mails in code, tests, docs, bench notes or commits. The staged diff must contain no user name and no home-directory path before each commit (grep as `common.md` says).
- No new threads or limits: stages 4–5 run inside `CoverQueue`'s `listingLimit` 2 / `networkListingLimit` 1 and the generator's read/decode limits; QoS `.utility`; everything pauses while the viewer flips (`CoverQueue.pause`, generator `activity`). Main thread: only updating the pill and cards from ready numbers; progress to the kit at most 4 times a second.
- Settings over constants: new keys `thumbs-ahead = folder | visible | off` (default `folder`), `thumbs-depth = 0…3` (default 1), `thumbs-pill-delay` seconds (default 1); global in `loupe.conf`, registered like `folder-cards` in `Config` (known keys list, getter, setter) and a row in Settings › Performance › Thumbnails.
- Interface strings English. Mockup board `Progress.dc.html` is the authority for the pill and waiting cards' look (values: ring 20 pt, stroke 2.5, track `Chrome.Palette.card.track`, fill accent `#0A84FF` running, `#8E8E94` paused, text 12 pt tabular, pill height 28, padding 0 12 0 6, glass background; shimmer gradient 100°, 1.6 s, Reduce Motion: none).
- Every visual change: snapshot beside the mockup in light and dark (extend `Tests/HomeScreenKitTests/CardSnapshots.swift`; `HOMESCREEN_SNAPSHOTS=<dir> swift test --filter CardSnapshots`).
- TDD: test first, watched red, then code. Measurements recorded next to constants (machine, data described neutrally).

## Review Focus

1. A parent card scrolls off screen while its subfolders are queued (stage 4): their work must be forgotten, not finished for nothing — Task 4 test `subfoldersLeaveWithTheirParent`.
2. A share: stage 4 and 5 must keep one listing in flight and never dim the folder the user opened — Task 4 `shareKeepsOneListingWithSubfolders`, Task 5 `walkOnAShareIsOneAtATime`.
3. Manual pause must not stop the cards in view (stages 1–2) — Task 6 `pauseKeepsTheViewAlive`.
4. The pill must not flicker on catalog-served folders (work < `thumbs-pill-delay`) nor stay lit after a folder change — Task 8 `pillWaitsForTheDelay`, `pillGoesOutOnANewFolder`.
5. Shimmer must stop for a card that will never get a cover (offline, given up, empty) — Task 7 `shimmerStopsWhenNothingWillCome`.

---

### Task 1: Settings and Config keys

**Files:**
- Modify: `Sources/LoupeCore/Config.swift` (known keys list ~566; `folderCards` ~450; getter ~715; setter ~1004)
- Modify: `Sources/LoupeSettings/Pages/PageStrip.swift` (Strip — the page that already holds the stored thumbnails' rows; add a "Prepare ahead" group there; the spec's "Performance › Thumbnails" was corrected to this page on 2026-10-23)
- Test: `Tests/LoupeCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces: `Config.thumbsAhead: ThumbsAhead` (`enum ThumbsAhead: String, CaseIterable, Sendable { case folder, visible, off }`), `Config.thumbsDepth: Int` (0…3, clamped, other values `.badValue`), `Config.thumbsPillDelay: Double` (seconds ≥ 0).

- [ ] **Step 1: Write failing tests** in `ConfigTests`: `thumbsAheadParsesAndDefaults` (default `.folder`; `visible`, `off`, case-insensitive; `nope` → `.badValue`), `thumbsDepthIsClamped` (default 1; `3` ok; `4`, `-1` → `.badValue`), `thumbsPillDelayDefaultsToOneSecond`; and that `Config.value(for:)` echoes each key.
- [ ] **Step 2: Run** `scripts/test.sh --filter ConfigTests` — expected: compile failure (no `thumbsAhead`).
- [ ] **Step 3: Implement** the three properties, keys in the known list, getter/setter cases, doc comments as `folder-cards` has them.
- [ ] **Step 4: Settings rows** in PageStrip (group "Prepare ahead"): `.choice("thumbs-ahead", "Prepare ahead", [(folder, "Whole folder"), (visible, "Cards in view"), (off, "Off")])` with the spec's description; `.stepper`/slider row "Prepare depth" 0–3 (use the page's existing integer row kind); pill delay as a row only if the page has a seconds row kind, else leave it a conf-only key (say so in the report).
- [ ] **Step 5: Run** `scripts/test.sh --filter ConfigTests` — PASS; `scripts/test.sh` whole — green but known flakes (`shareListsNamesOnly`, `batchCommitsByTime`, `cubeBuildTime`).
- [ ] **Step 6: Commit** `Settings: thumbs-ahead, thumbs-depth and thumbs-pill-delay`.

### Task 2: Recency words and fields (kit)

**Files:**
- Modify: `Sources/HomeScreenModel/CardSummary.swift` (add `visited: Date?` after `seen`), `Sources/HomeScreenModel/CardSummaryText.swift`
- Modify: `Sources/HomeScreenKit/CompactCard.swift` (row 4), `Sources/HomeScreenKit/PosterCard.swift` (three-line branch, `viewedLabel` text), `Sources/HomeScreenKit/FolderCard.swift` (`tooltip(_:summary:pages:)` gains the recency line), `Sources/HomeScreenKit/ListRow.swift` (tooltip only)
- Test: `Tests/HomeScreenModelTests/CardSummaryTextTests.swift` (or the existing words test file `CardWordsTests`), `Tests/HomeScreenKitTests/CompactCardTests.swift`, `PosterCardTests.swift`

**Interfaces:**
- Produces: `CardSummaryText.ago(_ date: Date, now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String` — `today`, `yesterday`, `N d ago` (2…13 days), `N w ago` (2…8 weeks), else `MMM yyyy` English (`Mar 2025`); `CardSummaryText.progressLine(_ s: CardSummary, now: Date) -> String?` — compact row 4 text: `153 / 248 · 3 d ago`, `viewed · 3 d ago`, `not opened`, nil when no photos.

- [ ] **Step 1: Failing tests**: `agoWords` (the six forms above with fixed dates), `compactRowFourHasRecency` (`"153 / 248 · 3 d ago"`, done → `"viewed · 3 d ago"`, no visit → `"not opened"`), `largePosterAppendsRecencyAndDropsItFirst` (300 pt: `"Jun – Aug 2024 · 153 / 248 · 3 d ago"`; at a width where it does not fit, the text is `"Jun – Aug 2024 · 153 / 248"`, i.e. recency is dropped before cutting), `tooltipHasRecency` (third line `"Viewed 3 d ago"`).
- [ ] **Step 2: Run** `swift test --filter "CardWordsTests|CompactCardTests|PosterCardTests"` — FAIL (no `visited`).
- [ ] **Step 3: Implement** the field, the two text functions, the card changes (CompactCard uses `progressLine`; PosterCard joins `[span, viewed, ago]` and drops `ago` when `textWidth` exceeds the line), tooltip line; `now` injected (`FolderCard.now: () -> Date` static for tests).
- [ ] **Step 4: Run** the same filter — PASS; then `swift test` whole (413+; the toast test is a known flake).
- [ ] **Step 5: Snapshots**: extend `CardSnapshots` B and E-300 data with `visited` three days before a fixed `now`; render, compare with board B by eye (row 4 keeps its 11 pt / gaps).
- [ ] **Step 6: Commit** `Home: cards say when the folder was viewed`.

### Task 3: Recency from the app

**Files:**
- Modify: `Sources/LoupeCore/FolderCardFacts.swift` (fill `visited` from `FolderVisit.visited`)
- Test: `Tests/LoupeCoreTests/FolderCardFactsTests.swift`

- [ ] **Step 1: Failing test** `visitedDateReachesTheSummary` (visit at date D → `summary.visited == D`; Recent stand-in → `opened`; no visit → nil).
- [ ] **Step 2: Run** `scripts/test.sh --filter FolderCardFactsTests` — FAIL.
- [ ] **Step 3: Implement** one assignment in `FolderCardFacts.summary(...)`.
- [ ] **Step 4: Run** — PASS. **Step 5: Commit** `Home: the visit's date goes to the card`.

### Task 4: Stage 4 — subfolders of the visible cards

**Files:**
- Modify: `Sources/LoupeCore/CoverQueue.swift` (a second tier: `want(_:visible:client:...)` gains `ahead: [String]` ids queued after every client's margin; `forget` covers them; counters), `Sources/Loupe/FolderBrowserSource.swift` (`wantImages(_:visible:width:)` ~387: for `thumbsAhead == .folder`, after the folder's own cards, ask the store for the visible cards' direct subfolders and add them as `ahead` work whose task is `folderCard` of the subfolder with `summaryPending` handled as for a card; results go to the catalog only — no view to show), `Sources/LoupeCore/ThumbnailStore+Covers.swift` (public `subfolderNames(of folder: URL, in location: ThumbnailLocation?) async -> [String]?` from the stored summary's listing or the folder's complete listing already in memory — never a new listing just to learn names; nil when unknown)
- Test: `Tests/LoupeCoreTests/CoverQueueTests.swift`, `Tests/LoupeCoreTests/ThumbnailCoversTests.swift`

**Interfaces:**
- Produces: `CoverQueue.want(_ ids: [String], visible: Int, ahead: [String] = [], client: Int = 0, isNetwork:, work:)`; `CoverQueue.progress(client:) -> CoverProgress` (`struct CoverProgress: Equatable, Sendable { var inView: (done: Int, total: Int); var margin: (done: Int, total: Int); var ahead: (done: Int, total: Int) }`); `CoverQueue.setOnProgress(_ handler: @Sendable (Int) -> Void)` (client id; coalesced by the caller).

- [ ] **Step 1: Failing tests**: `aheadRunsAfterEveryMargin` (ids in view of two clients, then margins, then `ahead`, in that order), `subfoldersLeaveWithTheirParent` (`want` without the parent → its `ahead` ids are forgotten, a running one cancelled), `shareKeepsOneListingWithSubfolders` (network `ahead` ids never make two network tasks in flight), `aheadSkipsFreshSubfolders` (a subfolder whose stored summary is fresh and whose four cells are in the catalog finishes without a listing — assert on the fake lister's call count), `progressCountsEachTier`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "CoverQueueTests|ThumbnailCoversTests"` — FAIL.
- [ ] **Step 3: Implement** the tier in `CoverQueue` (after `wanted`'s margins; same `running`/`ending` limits), `subfolderNames`, the wiring in `FolderBrowserSource` gated by `Config.thumbsAhead` (`.visible` / `.off` add no `ahead`; `.off` also passes `visible: ids.count` so no margin is asked). When a subfolder's summary lands, the parent's facts are refreshed through the existing `showSummaries()` path.
- [ ] **Step 4: Run** — PASS; whole `scripts/test.sh`.
- [ ] **Step 5: Measure** `LoupeBench thumbs --covers` (or extend `ThumbsBench`) on a local SSD folder of subfolders of JPEGs: time until the visible cards' subfolders all have covers, and peak busy cores at entry vs before. Record next to `CoverQueue.listingLimit`.
- [ ] **Step 6: Commit** `Covers: the visible cards' subfolders are covered after the folder's own cards`.

### Task 5: Stage 5 — the subtree walk on command

**Files:**
- Create: `Sources/LoupeCore/ThumbsWalk.swift` — `actor ThumbsWalk` : `init(store: ThumbnailStore, queue: CoverQueue, client: Int)`, `func start(_ folder: URL, location: ThumbnailLocation?, depth: Int)`, `func cancel()`, `var progress: WalkProgress` (`struct WalkProgress: Equatable, Sendable { var folders: (done: Int, total: Int); var files: (done: Int, total: Int); var stopped: String? }`), `static let folderLimit` (measured; start at 2 000), `func setOnProgress(_:)`
- Modify: `Sources/LoupeCore/ThumbnailStore.swift` (a low-priority generator window: `setWalkWindow(_ request: ThumbnailRequest?)` ordered after every real window in `ThumbnailQueue.order`), `Sources/LoupeCore/ThumbnailQueue.swift` (`order` takes an optional trailing request), `Sources/Loupe/FolderBrowserSource.swift` (menu items `prepare-subtree` → `ThumbsWalk.start(folder, depth: Config.thumbsDepth)`, `refresh-cover` → `ThumbnailStore.forgetSummaryAndPick(of:)` then `CoverQueue.forget`), `Sources/LoupeCore/ThumbnailStore+Summaries.swift` (`forgetSummaryAndPick(of location: ThumbnailLocation)`)
- Test: `Tests/LoupeCoreTests/ThumbsWalkTests.swift`, `ThumbnailQueueTests.swift`, `ThumbnailStoreTests.swift`

- [ ] **Step 1: Failing tests**: `walkGoesToTheDepth` (fake tree depth 3, `depth: 2` → folders of depth ≤ 2 listed, deeper not), `walkOnAShareIsOneAtATime`, `walkStopsAtTheFolderLimit` (`stopped == "Too many folders — prepared N"`), `walkWindowComesLast` (`ThumbnailQueue.order` puts the walk's files after every window's), `refreshCoverForgetsSummaryAndPick`, `walkCancelStopsListings`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "ThumbsWalkTests|ThumbnailQueueTests|ThumbnailStoreTests"` — FAIL.
- [ ] **Step 3: Implement**: the walk lists one folder at a time through the store's cover lister (same lane/limits as covers), feeds files to the walk window and subfolders to `CoverQueue` `ahead` (Task 4) then descends; respects `CoverQueue.pause`; `.utility`.
- [ ] **Step 4: Run** — PASS; whole suite. **Step 5: Commit** `Covers: a folder and its subfolders are prepared on command, to a depth`.

### Task 6: Pause and the progress model (app)

**Files:**
- Create: `Sources/LoupeCore/ThumbsProgress.swift` — `struct ThumbsProgress: Equatable, Sendable { var inView, rest, subfolders: (done: Int, total: Int); var paused: Pause? ; enum Pause { case user, browsing } ; var stage: Stage? ; enum Stage { case thumbnails, subfolders } ; var text: String? }` with `static func join(generator: (Int, Int), covers: CoverProgress, walk: WalkProgress?, pausedByUser: Bool, browsing: Bool) -> ThumbsProgress`; `text` per spec ("Thumbnails 120 / 480", "Subfolders 5 / 48", "Paused · 120 / 480").
- Modify: `Sources/LoupeCore/ThumbnailStore.swift` (`generatorProgress(window:) -> (done: Int, total: Int)`: files with a thumbnail of the window's listing / all), `Sources/LoupeCore/CoverQueue.swift` (`pause(_:)` already exists — add `pauseAhead(_ on: Bool)` that stops only margin+ahead tiers and the walk, leaving in-view work), `Sources/Loupe/FolderBrowserSource.swift` (collects the three, coalesces to ≤ 4/s with a `Task` debounce, calls `view.setProgress(_:)`; user pause state lives in the source for the session)
- Test: `Tests/LoupeCoreTests/ThumbsProgressTests.swift`, `CoverQueueTests.swift`

- [ ] **Step 1: Failing tests**: `textNamesTheCurrentStage` (files unfinished → "Thumbnails 120 / 480"; files done, subfolders going → "Subfolders 5 / 48"; paused → "Paused · 120 / 480"; all done → nil), `pauseKeepsTheViewAlive` (`pauseAhead(true)`: in-view ids run, margin and ahead do not; `pauseAhead(false)` resumes), `browsingPauseIsReported`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "ThumbsProgressTests|CoverQueueTests"` — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS; whole suite. **Step 5: Commit** `Covers: a pause for the work ahead, and one progress for the toolbar`.

### Task 7: Waiting cards shimmer (kit)

**Files:**
- Modify: `Sources/HomeScreenKit/FolderCard.swift` (`var isWaiting: Bool` → a `CAGradientLayer` shimmer over the cover placeholder and the facts lines; `transform` animation 1.6 s; `Chrome.Motion.reduced` → static lighter fill), `Sources/HomeScreenModel/HomeCardItem.swift` (`var waiting: Bool = false`), `Sources/HomeScreenKit/HomeBrowserView.swift` (`item(for:)` sets `waiting` = folder/archive entry without summary and without a known problem while covers are asked; cleared by `setSummary`/picture or by `setProblem`)
- Test: `Tests/HomeScreenKitTests/HomeBrowserViewTests.swift`, `PosterCardTests.swift`

- [ ] **Step 1: Failing tests**: `waitingCardShimmersUntilItsFactsCome` (card waiting → `shimmer` layer present and animating; `setSummary` → gone), `shimmerStopsWhenNothingWillCome` (summary with `.offline` problem → no shimmer, warning line), `reduceMotionShowsNoMovement`.
- [ ] **Step 2: Run** `swift test --filter "HomeBrowserViewTests|PosterCardTests"` — FAIL. **Step 3: Implement** (one layer per card, removed when not waiting; no timers). **Step 4: Run** — PASS; whole kit suite. **Step 5: Snapshot** a waiting card beside the board's. **Step 6: Commit** `Home: a card waiting for its cover shimmers`.

### Task 8: The progress pill (kit)

**Files:**
- Create: `Sources/HomeScreenKit/ThumbsProgressPill.swift` — `final class ThumbsProgressPill: NSView`: `func show(_ p: ThumbsProgressState?)` where `public struct ThumbsProgressState: Equatable, Sendable { var fraction: Double; var text: String; var paused: Bool; var rows: [(title: String, done: Int, total: Int)]; var pauseNote: String? }` lives in HomeScreenModel (`ThumbsProgressState.swift`); ring (CAShapeLayer, `strokeEnd` animated), glyph, text; click → `NSPopover` with the rows' bars, note, buttons "Pause"/"Resume" (`onPause: (Bool) -> Void`) and "Prepare subfolders" (`onPrepare: () -> Void`)
- Modify: `Sources/HomeScreenKit/HomeToolbar.swift` (`show(progress:)`, placed right of the sort capsule; hidden first in the narrow-window priority order), `Sources/HomeScreenKit/HomeBrowserView.swift` (`public func setProgress(_ state: ThumbsProgressState?, delay: Duration)` — shows after `delay` of continuous work, hides 1 s after nil, resets on `show(location:)`), `Sources/HomeScreenKit/HomeSource.swift` (`func pauseThumbs(_ on: Bool, in: BrowserLocation)`, `func prepareSubtree(of: BrowserLocation)` with no-op defaults)
- Test: `Tests/HomeScreenKitTests/HomeToolbarTests.swift`, `HomeBrowserViewTests.swift`, `CardSnapshots.swift`

- [ ] **Step 1: Failing tests**: `pillWaitsForTheDelay` (state set, before `delay` hidden, after shown), `pillGoesOutOnANewFolder`, `pillHidesOneSecondAfterDone`, `pillTextAndRingFollowTheState` (fraction 0.25 → `strokeEnd` 0.25; paused → grey), `popoverButtonsReachTheSource`, `narrowToolbarHidesThePillFirst`.
- [ ] **Step 2: Run** `swift test --filter "HomeToolbarTests|HomeBrowserViewTests"` — FAIL. **Step 3: Implement** on Chrome tokens (glass capsule as the toolbar's other capsules). **Step 4: Run** — PASS; whole kit suite. **Step 5: Snapshots** of the three states in both themes beside the board. **Step 6: Commit** `Home: a progress pill for the thumbnails being prepared`.

### Task 9: Wiring, menu items, build L20

**Files:**
- Modify: `Sources/Loupe/FolderBrowserSource.swift` (`setProgress` feed from Task 6 with `Config.thumbsPillDelay`; `pauseThumbs`, `prepareSubtree`; `menu(for:in:)` gains "Prepare thumbnails of folder and subfolders" and "Refresh cover" for folder/archive entries; `thumbsAhead` changes re-ask), `Sources/Loupe/AppDelegate.swift` (View › Thumbnails… opens the pill's popover for the key window)
- Test: `Tests/LoupeCoreTests` where logic is pure (`ThumbsProgress` text already); the app target has no tests — wiring is checked by the build and the manual pass.

- [ ] **Step 1:** Implement the wiring (no new logic outside tested types). **Step 2:** `scripts/test.sh` whole — green but the known flakes. **Step 3:** `LOUPE_BUILD_LABEL=L20 scripts/make-app.sh` → `build/Loupe.app`. **Step 4:** Privacy grep over `git log -p <base>..HEAD` of both repos. **Step 5: Commit** `Home: the thumbnails pill, pause and the subtree command in the app`.
- [ ] **Step 6: Report** for the owner's manual pass (spec "Проверка"): SSD folder with subfolders (pill, shimmer, subfolder covers after waiting in the parent), a share (one listing at a time, pause), subtree depth 2, recency on B and 300 pt, settings in three values.
