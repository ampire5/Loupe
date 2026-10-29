# SmartZoom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Priority-complete object groups, constrained weighted composition and a pan-first, independently switchable SmartZoom with an optional Slot panel.

**Architecture:** Keep detection unchanged. Calculate composition from cached oriented boxes in LoupeCore; centralize mode and group selection in the viewer session. A lazy AppKit Slot page edits window overrides and uses the same actions as keyboard and gestures.

**Tech Stack:** Swift, AppKit, XCTest, existing HomeScreenKit Slots.

**Spec:** docs/superpowers/specs/2026-10-29-smartzoom-composition-design.md (approved 2026-10-29 with left-hand Option shortcut amendment).

## Global Constraints

- No new detection for composition controls; no synchronous file I/O on main.
- Preserve profile order, all instances, existing configuration comments and other profiles.
- Auto zoom cap in original physical pixels, initially 100%; manual zoom unaffected.
- Panel is lazy and retained; no idle timer; benchmark actual UI and disclose unavailable Intel measurements.
- Option shortcuts use left-hand keys: power ⌥S, keep legacy bindings as configurable aliases.
- Work on existing non-main polish-2 checkout; do not move another active task's checkout or touch AGENTS.md.

## Review Focus

- Wholly outside, empty or non-finite boxes must not count as a complete group.
- Identical frames for distinct groups remain independently selectable.
- Late detection cannot override manual input or an Off transition.
- A small original can be displayed below Fit to respect the native cap.
- Old slot records and multi-panel singleton relocation survive round trips.

### Task 1: Group selection and composition

**Files:** Detector.swift, SubjectFraming.swift, PhotoSwitchView.swift, BrowseFraming.swift, ZoomRules.swift; DetectorTests.swift, SubjectFramingTests.swift, BrowseFramingTests.swift.
**Interfaces:** `SubjectFraming.pick(_:_:)->[CGRect]?` includes all valid instances, requires every part; `SubjectFraming.composition(_:kind:options:)->Composition?`, `CompositionOptions`, `Composition.transform(_:autoZoom:size:)->ViewTransform` supply weighted constrained framing.

- [x] Write tests for separated multi-instance groups, missing/invalid member, equal-looking groups, class normalization, projection, native cap below Fit and explicit-size-only memory.
- [x] Run focused tests and observe failures.
- [x] Implement bounded linear selection, parsing global/profile composition options, weighted center and projected pan; route transforms through composition and remove detector's forced auto zoom.
- [x] Run focused suite; update legacy reach/min-frame expectations to new documented semantics.
- [x] Commit task files.

### Task 2: Shared SmartZoom mode and inputs

**Files:** SmartZoom.swift (core), ViewerSession.swift, ViewerView.swift, ViewerWindowController.swift, KeyMap.swift, InputConfTemplate.swift; SmartZoomTests.swift, KeyMapTests.swift.
**Interfaces:** `SmartZoomMode` off/pan/frame and `SmartZoomState` power/mode transitions. `ViewerView.applySmartZoom(cycleGroup:)` is the shared explicit command; session applies same framing on photo changes.

- [x] Test power preserves last mode, pan/auto transition from Off, default pan, no implicit activation on profile/group, late request invalidation.
- [x] Observe failures, implement shared state and actions: ⌥S power, ⇧Z auto toggle, N group, M profile. Keep Z Fit/100%; smartMagnify configurable.
- [x] Preserve manual view on Off and auto→pan; pan keeps scale even with oversized group; guard pending requests with current photo and input revision.
- [x] Run core tests and build app.
- [x] Commit task files.

### Task 3: Slot panel and persistence

**Files:** FolderSlotSettings.swift, ViewerSlotsController.swift, SmartZoomPanel.swift, ViewerWindowController.swift; slot codec tests.
**Interfaces:** singleton `smartzoom` tab registered lazily; `SmartZoomPanel.refresh(...)` updates only while visible; callbacks invoke shared viewer actions. Composition window overrides persist explicitly to folder or detector profile.

- [x] Test old/new seven-field slot roundtrips and singleton normalization per ID.
- [x] Observe failures, implement multi-ID codec and lazy retained panel with explicit three states, profiles/groups, cap/size/margin, type weights/normalization, diagnostics and save actions.
- [x] Verify app build, core tests and slot persistence. Benchmark first/return panel and controls via real AppKit window thread CPU over repeated rounds.
- [x] Commit task files.

### Task 4: Configuration, review and handover

**Files:** docs/bench/2026-10-29-smartzoom.md, user detector.conf (backed up, no personal contents committed), spec/plan progress.
**Interfaces:** only supported parser keys written; optional balanced profile appended without changing default.

- [x] Verify actual cached regression photos' full group instances and centers using private harness.
- [x] Add optional balanced profile/weights and pan-first input settings to user's config with backup; preserve all other profiles/comments.
- [x] Run full relevant tests, build and kits check; obtain fresh review, fix important findings, record actual measurements and limits.
- [x] Finish with concrete changed behavior and remaining manual visual checks; do not claim unavailable Intel validation.
