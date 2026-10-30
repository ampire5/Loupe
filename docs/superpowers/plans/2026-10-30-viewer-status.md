# Viewer Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Implement the approved unified, interactive 46 pt viewer status.

**Architecture:** Keep session facts typed and separate from presentation. A retained AppKit view lays out three sections by frames, delegates commands to the window, and builds menus/popovers only on demand. The existing Info panel and keyboard/action paths remain authoritative.

**Tech Stack:** Swift, AppKit, LoupeCore, existing HomeChrome glass.

**Spec:** docs/superpowers/specs/2026-10-30-viewer-status-design.md

## Global Constraints

- 46 pt fixed height, supported minimum window width 320 pt; font size at least 11 pt.
- EXIF, profile and group remain visible; folder navigation is excluded.
- No synchronous file I/O, model preparation or repeating work in the status view.
- Preserve unrelated staged/unstaged work on the existing polish-3 branch; no broad staging or reset.
- Neutral examples and no assistant attribution.

## Review Focus

- Missing versus delayed EXIF must not retain the previous photo's metadata indefinitely.
- Long profile/group names must not overlap adjacent values or lose their accessible full text.
- Native toolbar compression differs from standalone view resizing.
- Exact zoom must enter Manual and invalidate pending SmartZoom work.
- Numeric position/zoom must reject nonfinite and out-of-range input; menus must use current choices.

### Task 1: Typed status and regression tests

**Files:** ImageStatus.swift, ViewerSession+Status.swift, Tests/LoupeTests/ViewerToolbarStatusTests.swift.
**Interfaces:** ImageStatus.ZoomDetails carries mode/profile/group/scale/keepingZoom. Existing facts remain compatible with StatsBar.

- [x] Add a failing native toolbar regression: a 46 pt status with inline Profile/Group controls and no duplicate zoom/navigation items.
- [x] Run the regression and confirm the missing controls/duplicate item failure.
- [x] Add typed zoom details to the session status, including Manual state and empty/loading cases.

### Task 2: Native view and existing action routing

**Files:** new ViewerToolbarStatusView.swift, new ViewerStatusPopover.swift; modify ViewerToolbarController.swift, ViewerWindowController.swift, ViewerView.swift.
**Interfaces:** ViewerStatusAction routes Info, navigation, presets, exact zoom, modes, profiles and groups; ViewerStatusChoices is queried on menu open.

- [x] Implement retained three-section layout and metadata hold rules, then test 46 pt geometry, long strings and missing/pending EXIF.
- [x] Implement lazy native menus and retained numeric popovers; validate their bounds and current-state action routing.
- [x] Connect the existing session actions and remove redundant toolbar items, keeping advanced menus.
- [x] Run the focused core and native tests, then the ordinary suite.

### Task 3: Verification and review

**Files:** Tests/LoupeTests/ViewerToolbarStatusTests.swift; docs/bench/2026-10-30-viewer-status.md.

- [x] Benchmark a real window: first/return separately over repeated rounds, using CLOCK_THREAD_CPUTIME_ID. Save a native preview.
- [x] Build with the prepared project decoder dependencies and run kits-check without changing release pins.
- [x] Request an independent scoped review and fix actionable findings.
- [x] Record local evidence and any unavailable physical Intel verification. Commit these changes separately without mixing unrelated staged work.

Verification outcomes and remaining release gates are recorded in docs/bench/2026-10-30-viewer-status.md. The ordinary main-checkout run has unrelated Photos failures; kit branch release and physical Intel validation remain pending.
