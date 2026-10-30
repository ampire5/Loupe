# File Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Inspect the selected browser file in a fast, native right pane.
**Architecture:** HomeScreenKit exposes selected entry changes and hosts an optional inspector split item and toolbar action. Loupe owns the content model, latest-only asynchronous reader and AppKit inspector. Existing viewer info stays separate.
**Tech Stack:** Swift, AppKit, ImageIO, Swift Testing.
**Spec:** docs/superpowers/specs/2026-10-29-file-inspector-design.md

## Global Constraints

Preserve pre-existing dirty work in both repositories and the matching codex/release-0.2.1 branches. No kit publishing or Package.resolved restoration. No synchronous filesystem access on the main actor, unbounded task queues or idle timers. Native reads are bounded and stale responses discarded. Public examples remain neutral. Work in place to preserve active edit-mode dependencies and concurrent source additions; use precise patches only.

## Review Focus

- Selection cleared by navigation, filtering, deletion, or an empty listing must clear old info.
- A slow file A followed by B then C must show C and never start B.
- Hiding/parking during a read must prevent late UI updates and pending reads.
- Metadata errors and unsupported sources must remain readable without stale sections.
- Disclosure/width persistence and focus must survive closing and returning to File View.

## Tasks

### 1. Browser integration boundary
- [x] Add HomeScreenKit tests for selected-entry callbacks on selection, updated listing and empty results; optional inspector placement, parking and toolbar toggle.
- [x] Watch tests fail, then expose `selectedEntry`, `onSelectionChange`, and optional inspector hosting in HomeView. Keep inspector absent for existing clients.
- [x] Run HomeScreenKit tests.

### 2. Content and latest-only reads
- [x] Add LoupeCore tests for grouped file facts, optional capture/generation, errors, and latest-only bounded reads with hide cancellation.
- [x] Watch failures, then add BrowserInspectorContent and BrowserInspectorLoader. Reuse PhotoMetadata parsing with a separate bounded reader/cache.
- [x] Run focused tests and the core suite.

### 3. Native inspector and window wiring
- [x] Add persistent AppKit disclosure rows, summary, scroll view, copy/reveal actions and thumbnail. Host in HomeView; wire Cmd-I, toolbar, visibility and lifecycle with precise ViewerWindowController patches.
- [x] Build, run a real-window benchmark for first/return and repeated selections, inspect UI and record evidence in docs/bench.
- [x] Run appropriate full checks and kits-check; review the scoped diff. Report release-mode dependencies and hardware limitations honestly.

## Execution ledger

- Ruling: work in place on the existing matching branches — both repos contain active, unrelated changes and Loupe consumes HomeScreenKit in edit mode; avoid snapshotting, resetting or committing those changes.

- Task 1: selected-entry callbacks, listing changes and optional native split inspector tests RED→GREEN. Full kit run exposed two existing toolbar membership/order expectations; updated them for the new item.
- Task 2: content and bounded latest-only reads tests RED→GREEN (6 tests). Additional regression caught duplicate reads when thumbnail facts enriched the same file without a stamp; retain the current read for identity/stamp-equivalent entries.
- Task 3: native inspector and Cmd-I/window lifecycle wired. Real-window debug bench completed on M4 Max; screenshot inspected. First creation 107.4 ms CPU; subsequent file selections median 8.3–10.4 ms, max 15.6 ms; reopening median 18.3–20.2 ms, max 21.2 ms.
- Review: independent reviewer found native divider collapse bypassing activity/persistence and hidden native tabs bypassing visibility. Native-collapse regression failed before KVO reconciliation, then passed; use WindowRegistry's explicit selected-tab visibility delivery for inspector activity as well.
- Ruling: first-install inspector creation is part of Home's one-time construction; reopening reuses every control. No speculative preloading. The missing user glass guide prevents specifying custom reveal timings; the initial inspector is docked and uses native material.
- Ruling: no kit release, merge or restoration of Package.resolved — HomeScreenKit was already in edit mode with concurrent work. kits-check correctly reports its missing release pin; releasing the combined kit branch and updating the app pin is required before release.

- Final verification: HomeScreenKit 673 tests pass; Loupe core 2206 and settings 63 pass, render 136 pass; optimized LoupeBench builds. Overall LoupeTests still reports PhotosBrowserTests.leavingPhotosViewerRemovesItsCurrentReadPriority from concurrent Photos work. No inspector test failures remain.
- Final review: both important findings fixed. Minor deferred: summary rows retain first-appearance order. Full-text actions are connected for both summary and disclosure sections.
- Final status: implementation retained in the shared working copies, without committing, merging, releasing kits, installing an app, or resetting other work. Measured first open is 112 ms on M4 Max, so the Intel budget is explicitly unverified.

- Final focused verification after full-text action wiring: 7 inspector tests pass; git diff --check is clean.
