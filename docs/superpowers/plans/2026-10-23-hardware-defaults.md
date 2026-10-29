# Hardware Defaults and Memory Tiers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Defaults and Settings notes that follow the Mac's hardware, and on a Mac with a discrete graphics card two
memory tiers: graphics memory sized by Loupe, system memory (with decoded photos kept ready) sized by the user.

**Architecture:** A pure `MachineProfile` (cores, memory, GPU) feeds a pure `HardwareAdvice` (defaults, effective
values, notes, warnings). `CacheLimits` gains `graphicsMemory` (nil on unified memory: one budget, as today);
`CachePlan` and `ImageCache` count pyramids against it and compressed files plus a new `ready` goal (a full decode kept
in system memory) against `cache-memory`. SettingsKit gets a per-row machine note with a «Use recommended» button.

**Tech Stack:** Swift 6, Swift Testing, Metal (device facts only), SwiftUI (SettingsKit), SwiftPM.

**Spec:** `docs/superpowers/specs/2026-10-22-hardware-defaults-design.md`

## Global Constraints

- Repos: the app, branch `pan-lts`; the SettingsKit checkout beside it (`../SettingsKit`), new branch
  `machine-notes-lts` from `origin/lts/macos26`, linked with `swift package edit SettingsKit --path ../SettingsKit`
  (as HomeScreenKit already is). Never commit `Package.resolved`, `Packages/`,
  `release.yaml`. Never push.
- Commits: `git -c user.name="Vladimir Selin" -c user.email=418805+ampire5@users.noreply.github.com commit`, body ends
  with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01UHEgCsxN5juXdhYFYdkB1N`. Stage files by name.
- Public project: no home path, user name, volume or share names, personal folder or file names in code, comments,
  tests, docs or messages; `git diff --cached | rg -n "/Users/[^/]+/"` prints nothing before every commit.
- Performance rules: background never takes every core; background work at `.utility`; the main thread never blocks;
  memory and queues bounded; limits measured and recorded next to the constant (what, which machine, result).
- Policy (user's choice «1»): harmful values take effect clamped, with «Effective …» at the row and one line in the
  `loupe.conf` warnings; suboptimal values take effect as written, with a note and «Use recommended (…)».
- UI strings English. Byte sizes in decimal units like Finder (1 GB = 1 000 000 000 bytes).
- Graphics tier = half the card's `recommendedMaxWorkingSetSize`, no key (4.285 GB on the i7-10700K + Radeon Pro
  5500 XT iMac, 8.57 GB working set). Only when `hasUnifiedMemory == false`.
- `cache-memory` default: discrete card — a fifth of the memory, down to a 256 MiB step, at least 1 GiB, no upper
  bound; unified memory — as today (`Machine.cacheMemory(memoryBytes:)`, 1–4 GiB).
- `jxl-threads-other`: default `max(1, min(2, physicalCores / 4))`; harmful above `max(1, physicalCores / 4)` →
  effective that. `jxl-threads-current`: suboptimal above `physicalCores` (recommended
  `Machine.jxlThreadsCurrent(performanceCores:)`). `cache-memory`: suboptimal above half the memory (recommended
  the default).
- Ready decodes: only on a discrete card, only while the zoom needs level 0 (`CacheFocus.needsFull`) or the entry
  already holds one; filled one at a time at `.utility`; dropped first under pressure and eviction.
- Tests: `scripts/test.sh` (core) and `scripts/test.sh render` when LoupeRender changes; kit `swift test`. Known
  failures on this Intel iMac in `scripts/test.sh full` (also on the base branch): `srgbImagesUnchanged`,
  `nilColorKeepsPipeline`, `downsampleAveragesInLinearLightAndClampsToLevel`,
  `downsampleReadsEachSourcePixelFromItsOwnTile`, `tileDrawMapsLevelPixelsToViewPixels`,
  `tileDrawClampsToLevelSoApronIsNeverRead`, `orientationUpIsUnchanged`, `bothTargetsBlendInTheSameLight`. Known
  flaky under load: `cubeBuildTime`, `batchCommitsByTime`, `hungLocalDiskTimesOut`.

## Review Focus

1. A photo bigger than the graphics tier (147 MP on a 4 GB card: tier ~2.1 GB, one full pyramid 0.78 GB): the current
   photo still shows at 100 %; only neighbours lose their full levels (Task 5 test `currentFullExemptFromGraphicsTier`).
2. Memory pressure `critical` with the ready tier full: ready decodes go first, the current photo's bytes never
   (Task 6 test `pressureDropsReadyBeforeBytes`).
3. Stepping onto a photo whose ready decode is still running at `.utility`: the full job waits for it and does not
   decode again (Task 6 test `fullJobWaitsForReadyInFlight`).
4. An unprobed photo planned ready at the estimated size turns out larger: after the replan the system tier is back
   within `cache-memory` (Task 6 test `readyReplannedWhenProbedLarger`).
5. A `loupe.conf` written on a bigger Mac (`jxl-threads-other=8` on 8 cores): effective 2, one warning line per reload,
   the file untouched (Task 2 test `harmfulValueWarnsOnceAndKeepsTheFile`).

---

### Task 1: Machine profile and hardware advice

**Files:**
- Create: `Sources/LoupeCore/MachineProfile.swift`, `Sources/LoupeCore/HardwareAdvice.swift`
- Modify: `Sources/LoupeCore/Config.swift` (defaults of `cacheMemory`, `jxlThreadsOther`; `memoryText` → `static func
  memoryText(_:) -> String` internal, not private), `Sources/LoupeCore/JXLOptions.swift` (default `threadsOther`)
- Test: `Tests/LoupeCoreTests/HardwareAdviceTests.swift`

**Interfaces:**
- Produces:
  - `public struct GPUProfile: Equatable, Sendable { public var unifiedMemory: Bool; public var workingSetBytes: Int;
    public var name: String }`
  - `public struct MachineProfile: Equatable, Sendable { public var physicalCores, performanceCores, memoryBytes: Int;
    public var gpu: GPUProfile; public static let current: MachineProfile }` — `current` from `Machine.*` and
    `MTLCreateSystemDefaultDevice()` (`hasUnifiedMemory`, `recommendedMaxWorkingSetSize`, `name`); without a device:
    unified, working set = memory.
  - `public enum HardwareAdvice` with:
    - `static func graphicsMemory(_ p: MachineProfile) -> Int?` — nil when `p.gpu.unifiedMemory`, else
      `p.gpu.workingSetBytes / 2`.
    - `static func defaultCacheMemory(_ p: MachineProfile) -> Int`
    - `static func defaultJXLThreadsOther(_ p: MachineProfile) -> Int`
    - `static func effectiveJXLThreadsOther(_ written: Int, _ p: MachineProfile) -> Int`
    - `public enum Severity: Sendable { case harmful, suboptimal }`
    - `public struct Note: Equatable, Sendable { public let severity: Severity; public let text: String; public let
      recommended: String }` (`recommended` as `loupe.conf` spells it)
    - `static func note(forKey key: String, value: String, on p: MachineProfile) -> Note?` — nil for keys without a
      rule, for unparsable values and for values inside the rule.
    - `static func warnings(for config: Config, on p: MachineProfile) -> [String]` — harmful ones only.

- [ ] **Step 1: Write the failing tests** in `HardwareAdviceTests.swift`, with fixtures
  `imac = MachineProfile(physicalCores: 8, performanceCores: 8, memoryBytes: 64 << 30, gpu: GPUProfile(unifiedMemory:
  false, workingSetBytes: 8_573_157_376, name: "AMD Radeon Pro 5500 XT"))`, `card4 = (4 cores, 16 GiB, discrete,
  4_294_967_296)`, `m4max = (16, 12, 64 GiB, unified, 48 GiB)`, `m1 = (8, 4, 8 GiB, unified, 5_726_623_744)`,
  `intelIGPU = (4, 4, 16 GiB, unified, 1_610_612_736)`:
  - `graphicsTierIsHalfTheCardsWorkingSet`: `graphicsMemory(imac) == 4_286_578_688`, `graphicsMemory(card4) ==
    2_147_483_648`, nil for `m4max`, `m1`, `intelIGPU`.
  - `cacheMemoryDefaultFollowsTheTier`: `defaultCacheMemory(imac) == 13_690_208_256` (64 GiB / 5 down to 256 MiB:
    12.75 GiB), `card4 == 3_221_225_472` (16 GiB / 5 → 3 GiB), `m4max == 4 << 30`, `m1 == 1536 << 20`.
  - `neighbourThreadsAreAQuarterOfTheCores`: defaults `imac 2, card4 1, m4max 2, m1 2`; `effectiveJXLThreadsOther(8,
    imac) == 2`, `(1, imac) == 1`, `(4, m4max) == 4`, `(5, m4max) == 4`.
  - `notesNameTheRuleAndTheRecommendedValue`:
    - `note("jxl-threads-other", "8", imac) == Note(.harmful, "Effective 2 on this Mac: more would take over a quarter
      of its 8 cores in the background.", "2")`
    - `note("jxl-threads-current", "16", imac) == Note(.suboptimal, "More threads than this Mac's 8 cores only burn
      CPU.", "8")`
    - `note("cache-memory", "40G", imac) == Note(.suboptimal, "Over half of this Mac's 68.7 GB of memory: macOS would
      squeeze other apps before the cache gives way.", "13056M")` (the recommended text is `Config.memoryText` of the
      default)
    - nil for `("jxl-threads-other", "2", imac)`, `("cache-memory", "20G", imac)`, `("zoom-stops", "x", imac)`,
      `("jxl-threads-other", "abc", imac)`.
  - `harmfulValueWarnsOnceAndKeepsTheFile`: a `Config` parsed from `"jxl-threads-other=8\njxl-threads-current=16\n"`
    → `warnings(for:on: imac) == ["jxl-threads-other=8: using 2 on this Mac (8 cores)"]`; the config's own
    `jxlThreadsOther` stays 8.
  - `defaultsNeverNote`: for every key with a rule, `note(key, Config().text(forKey: key)!, .current) == nil`.
- [ ] **Step 2: Run** `scripts/test.sh --filter HardwareAdvice` — expected FAIL (types missing).
- [ ] **Step 3: Implement** the two files; `Config` defaults become `HardwareAdvice.defaultCacheMemory(.current)` and
  `HardwareAdvice.defaultJXLThreadsOther(.current)`; `JXLOptions.init` default `threadsOther` the same.
  `Machine.cacheMemory` stays (the unified rule) and its doc names `HardwareAdvice` as the place defaults are chosen.
  Memory in note texts: decimal GB with one decimal (`64 GiB` → `68.7 GB`).
- [ ] **Step 4: Run** `scripts/test.sh --filter "HardwareAdvice|Machine|ConfigTests"` — PASS (update
  `MachineTests.cacheMemoryFollowsTheMemory`'s last line to compare with `HardwareAdvice.defaultCacheMemory(.current)`).
- [ ] **Step 5: Commit** «Hardware advice: defaults, notes and warnings from the Mac's cores, memory and graphics card».

### Task 2: Effective values and warnings in the app

**Files:**
- Modify: `Sources/LoupeCore/CacheLimits.swift`, `Sources/LoupeCore/JXLOptions.swift`, `Sources/Loupe/Settings.swift`
  (`reload`), `Sources/LoupeBench/Replay.swift` (nothing to change if it uses `init(config:)`; check)
- Test: `Tests/LoupeCoreTests/HardwareAdviceTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces: `CacheLimits.graphicsMemory: Int?` (nil = one budget, today's behaviour);
  `CacheLimits.init(config: Config, profile: MachineProfile = .current)` sets `memory = config.cacheMemory`,
  `graphicsMemory = HardwareAdvice.graphicsMemory(profile)`; `JXLOptions.init(config: Config, profile: MachineProfile =
  .current)` sets `threadsOther = HardwareAdvice.effectiveJXLThreadsOther(config.jxlThreadsOther, profile)`.
  `CacheLimits()` (no config) keeps `graphicsMemory = nil`.

- [ ] **Step 1: Tests** `limitsCarryTheGraphicsTier` (`CacheLimits(config: Config(), profile: imac).graphicsMemory ==
  4_286_578_688`, `profile: m4max` → nil), `neighbourThreadsTakeEffectClamped` (config `jxl-threads-other=8`,
  `JXLOptions(config:profile: imac).threadsOther == 2`, `m4max` → 4).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** In `Settings.reload`, the found warnings become
  `configWarnings + HardwareAdvice.warnings(for: loaded, on: .current) + inputWarnings` (the existing `found !=
  warnings` check keeps a reload quiet when nothing changed).
- [ ] **Step 4: Run** `scripts/test.sh` — PASS. **Step 5: Commit** «Settings: neighbour threads take effect clamped
  to the Mac, and the cache learns the graphics tier».

### Task 3: SettingsKit machine notes

**Files (kit `../SettingsKit`, branch `machine-notes-lts`):**
- Modify: `Sources/SettingsKit/SettingsStore.swift`, `Sources/SettingsKit/SettingsModel.swift`,
  `Sources/SettingsKit/RowViews.swift`, `Tests/SettingsKitTests/MemoryStore.swift`
- Test: `Tests/SettingsKitTests/MachineNoteTests.swift`

**Interfaces:**
- Produces:
  - `public struct SettingsNote: Equatable, Sendable { public enum Severity: Sendable { case harmful, suboptimal };
    public let severity: Severity; public let text: String; public let recommended: String?; public init(...) }`
  - `SettingsStore.machineNote(forKey key: String) -> SettingsNote?`, default implementation `nil`.
  - `SettingsModel.machineNote(_ key: String) -> SettingsNote?`, refreshed with the folder overrides (on `register`,
    on every `.settingsStoreDidChange`, on `refreshFolderOverrides()`).
  - `SettingsModel.useRecommended(_ key: String)` — `set(key, note.recommended)` when there is one.
  - Row view: under the folder note, `MachineNote`: 11 pt label in `style.secondaryText`, symbol
    `exclamationmark.triangle` (harmful, tinted `.orange`) or `info.circle` (suboptimal), then a small button
    «Use recommended (\(recommended))», help «Write the value recommended for this Mac».

- [ ] **Step 1: Tests** `machineNoteFollowsTheStore` (MemoryStore with a `notes` dict; register; note visible; store
  change → note gone), `useRecommendedWritesTheValue` (`useRecommended("a")` → `store.value(forKey: "a") == "2"`),
  `machineNoteDefaultsAreInert` (a store without the method → nil).
- [ ] **Step 2: Run** `swift test --filter MachineNote` in the kit — FAIL. **Step 3: Implement.** **Step 4:** kit
  `swift test` — PASS. **Step 5: Commit** (kit) «Rows show the store's note for this machine, with Use recommended».
  Then in the app: `swift package edit SettingsKit --path ../SettingsKit` (not committed).

### Task 4: Loupe settings: notes, graphics row, texts

**Files:**
- Modify: `Sources/LoupeSettings/ConfigSettingsStore.swift`, `Sources/LoupeSettings/Pages/PagePerformance.swift`
- Create: `Sources/LoupeSettings/GraphicsMemoryView.swift`
- Test: `Tests/LoupeSettingsTests/MachineNotesTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3.
- Produces: `ConfigSettingsStore.init(..., profile: MachineProfile = .current)`; `machineNote(forKey:)` → the
  `HardwareAdvice.note` of the key's written value as `SettingsNote` (nil when the key is not written);
  `SettingsPanel.performancePage(on profile: MachineProfile) -> SettingsPage`, `static let performance =
  performancePage(on: .current)`.

- [ ] **Step 1: Tests:** `writtenHarmfulValueHasANote` (store over a temp `loupe.conf` with `jxl-threads-other=8`,
  profile `imac` → note `.harmful`, recommended "2"; key not written → nil); `graphicsRowOnlyOnADiscreteCard`
  (`performancePage(on: imac)` has a row titled "Graphics memory"; `on: m4max` has none);
  `cacheMemoryDescriptionNamesTheTier` (discrete page's `cache-memory` row description contains "decoded" and
  "graphics memory is Loupe's").
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.**
  - Discrete page: `cache-memory` row title "Memory limit", description «System memory for photos kept decoded and
    ready and for compressed files; graphics memory is Loupe's (\(gfx) here, below). M or G, or bytes; default a fifth
    of this Mac's memory (\(here) here).»; unified page: today's description.
  - Graphics row (discrete only), right after `cache-memory`: `.custom("Graphics memory", searchTexts: { ["Graphics
    memory", "GPU", "VRAM", "Video memory"] }) { GraphicsMemoryView(...) }`, laid out like the other rows (symbol
    `cpu`), text «\(tier) of \(workingSet) on \(gpu name), set by Loupe for this card», e.g. «4.3 GB of 8.6 GB on AMD
    Radeon Pro 5500 XT, set by Loupe for this card». (Spec's «of 8 GB» names the card; Metal reports the working set,
    8.6 GB: the text uses what Metal reports.)
- [ ] **Step 4: Run** `scripts/test.sh` — PASS. **Step 5: Commit** «Settings: notes for this Mac's values, and the
  graphics memory Loupe sets».

### Task 5: Two memory tiers in the cache

**Files:**
- Modify: `Sources/LoupeCore/CachePlan.swift`, `Sources/LoupeCore/ImageCache.swift`,
  `Sources/LoupeCore/ImageCache+Jobs.swift` (`upload`'s room-making), `Sources/LoupeCore/ImageCacheEntry.swift`
  (`CacheStats`), `Sources/LoupeCore/StatsLine.swift`
- Test: `Tests/LoupeCoreTests/CachePlanTests.swift`, `Tests/LoupeCoreTests/ImageCacheTests.swift`

**Interfaces:**
- Consumes: `CacheLimits.graphicsMemory` (Task 2).
- Produces: `CachePlan` with `graphicsMemory != nil` counts `coarse`/`preview`/`full` against it and `bytes` against
  `memory`; with nil, exactly today's single total. `ImageCache.usedGraphicsBytes() -> Int` (pyramids + upload
  reserves), `usedSystemBytes() -> Int` (compressed bytes; ready decodes from Task 6); `evictToFit()` brings each
  tier within its limit (`graphicsMemory` as is; `memory / pressure.divisor`); with nil, today's combined rule.
  `CacheStats` gains `graphicsUsedBytes: Int`, `graphicsLimitBytes: Int?`; with a graphics tier `usedBytes` /
  `limitBytes` / `effectiveLimitBytes` describe the system tier. `StatsLine` appends « · GPU \(used) / \(limit) GB»
  to «Cache use» when `graphicsLimitBytes != nil`.

- [ ] **Step 1: Tests:**
  - `unifiedPlanUnchanged`: for several focuses, `CachePlan.make` with `graphicsMemory = nil` equals the plan made
    before this task (pin a few item lists from the current tests).
  - `filesStayWhenPyramidsFillTheGraphicsTier`: 147 MP, `graphicsMemory` = 2 full pyramids, `memory` 4 GiB,
    `files` 24 → plan holds 24 `bytes` items and pyramids within 2 full.
  - `currentFullExemptFromGraphicsTier`: `graphicsMemory` 0.5 GiB, needsFull → current `.full` planned, no neighbour
    `.full`.
  - `uploadsEvictPyramidsNotBytes` (ImageCacheRig, graphics tier for 2 full): after stepping 4 photos at 100 %,
    `usedGraphicsBytes() <= graphicsMemory` and the neighbours' bytes still resident.
  - `pressureLeavesTheGraphicsTier`: pressure `.warning` halves the system tier only.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** `EvictionStep` keeps its order; pyramid steps count against the
  graphics tier, `.bytes` against the system tier. **Step 4: Run** `scripts/test.sh` — PASS.
- [ ] **Step 5: Commit** «Cache: on a discrete card pyramids fill graphics memory and files system memory».

### Task 6: Ready decodes in system memory

**Files:**
- Modify: `Sources/LoupeCore/CachePlan.swift`, `Sources/LoupeCore/ImageCache.swift`,
  `Sources/LoupeCore/ImageCache+Jobs.swift`, `Sources/LoupeCore/ImageCacheEntry.swift` (`CacheEntry.ready`,
  `CacheStats.readyCount`)
- Test: `Tests/LoupeCoreTests/CachePlanTests.swift`, `Tests/LoupeCoreTests/ImageCacheTests.swift`
  (fakes in `CacheFakes.swift` as needed)

**Interfaces:**
- Consumes: Task 5's tiers.
- Produces:
  - `CacheGoal.ready` (raw value after `.full`) and `var isPyramid: Bool` (`coarse`, `preview`, `full`). Every place
    that compares or takes the max of goals for residency (`degrade`'s `top`, `state(of:)`, `wantedLevel`,
    `isSatisfied`, `previewed`, `firstGoal`) filters with `isPyramid`; `.ready` is never a pyramid state.
  - `EntryFacts.readyKept: Bool`. Plan step 5a (only `graphicsMemory != nil`): after the bytes, `.ready` for the
    current photo (and companion), then `neighbours()` in order, for entries whose `.bytes` are planned, while the
    zoom needs level 0 (`focus.needsFull`) or `readyKept`; cost = 64-byte-aligned row × height of the (estimated)
    size; against `memory`.
  - `CacheEntry.ready: LevelImage?` (level 0). `isSatisfied(.ready) = ready != nil`; `usedSystemBytes` adds
    `ready.image.buffer.length`. `EvictionStep.ready`, first in the system tier (farthest first), before `.bytes`.
  - `ImageCache.readyPool = DecodePool(slots: 1, reserved: 0, qos: .utility)`; a `.ready` job reads (same `mayRead`
    rule), probes, decodes full with the `.other` role through `readyPool` (and `progressiveFull` when progressive, as
    `.full` does), stores `e.ready`, uploads nothing.
  - The `.full` job: uses `e.ready` when present (no decode); when a `.ready` job of the entry is past waiting, awaits
    its task first; after decoding itself, keeps the image in `e.ready` when `.ready` is planned for the entry.

- [ ] **Step 1: Tests:**
  - `readyPlannedOnlyOnADiscreteCardAtFullZoom`: graphics tier set + needsFull → `.ready` items nearest first within
    `memory`; needsFull false → none; graphics nil → none.
  - `stepBackUploadsTheReadyDecode` (rig, counting decoder): forward 5 at 100 % with dwell, back 4 → no extra
    `decodeFull` calls for photos whose ready decode was kept; uploads happen.
  - `fullJobWaitsForReadyInFlight`: a gated ready decode for n2; step to n2; release → one `decodeFull` call total.
  - `pressureDropsReadyBeforeBytes`: pressure `.critical` → ready decodes gone first, current photo's bytes kept.
  - `readyReplannedWhenProbedLarger`: two unprobed entries planned ready at the estimate; probe reports 4× the pixels
    → after `reconcile`, `usedSystemBytes() <= memory`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `scripts/test.sh` and `scripts/test.sh render`
  — PASS (render: only the known Intel failures).
- [ ] **Step 5: Commit** «Cache: decoded photos kept ready in system memory, a step back is an upload».

### Task 7: Measure, record, build

**Files:**
- Modify: `Sources/LoupeBench/ReplayScript.swift` (script `backfast`: 15 × (+1, 1.5 s), 14 × (−1, 600 ms), zoom
  100 %, named "back-fast"), `Sources/LoupeBench/Replay.swift` (summary gains `ready` count from `CacheStats` if it
  prints cache counts), comments at `HardwareAdvice.graphicsMemory` and `ImageCache.readyPool` with the measured
  numbers
- Create: `docs/bench/2026-10-23-memory-tiers.md` (neutral data description: "five 147 MP JPEG XL (transcoded JPEG)
  linked twenty times, local SSD")

- [ ] **Step 1: Run** on this iMac, with defaults (no `--conf`): `LoupeBench replay --script 100,backfast --screen
  5120x2880 <folder>` twice, and the same on the base commit `fdc4140` (a checkout of it). Record per
  script: shown sharp / not shown, back-step shown p50 / max, CPU s, RAM and GPU peaks.
- [ ] **Step 2: Expected:** back-fast 29 of 29 sharp, back steps ≤ ~260 ms; GPU peak ≤ ~6.6 GB; 100-steps no worse
  than base. If not, stop and report numbers.
- [ ] **Step 3:** Write the bench doc and the constants' comments; `LOUPE_BUILD_LABEL=L15 scripts/make-app.sh`.
- [ ] **Step 4: Commit** «Bench: memory tiers on a discrete card, measured».

## Out of scope (spec «Не входит» and «Apple Silicon»)

Neighbour decodes at `.utility` in the main pool, larger defaults on Apple Silicon, upload pieces on unified memory:
measured on the M4 Max first. Profiles, runtime tuning, thumbnail threads.
