# Lazy Inspector Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for inline execution.

**Goal:** Keep a hidden File View inspector unallocated until first requested, retain it afterward, and audit other startup work.
**Architecture:** HomeScreenKit accepts a one-shot inspector factory. A toolbar toggle or visible-state restore materializes its split item; parking does not. Loupe registers the factory and optional callbacks without instantiating the controller. Explicitly requested visible startup state is honored.
**Tech Stack:** Swift, AppKit, Swift Testing.
**Spec:** Follow-up to 2026-10-29-file-inspector-design.md; user explicitly requested lazy creation and an audit.

## Constraints

Preserve all concurrent dirty work and existing matching kit/app branches. No new app branch, releases, commits or Package.resolved reset. No idle prebuilding. Keep visible restore, focus, width, divider collapse and metadata lifecycle working. The user glass guide remains absent; no motion/material changes in this task.

## Tasks

- [x] Add failing native tests: factory untouched by configuration/layout/parking, materialized by first toolbar or visibility request, reused after hide and parking, latest selection available on first construction, restored-visible intent while parked materialized on unpark.
- [x] Add one-shot `configureInspector(width:make:)` while retaining existing immediate installation API; wire Loupe's factory without accidental creation through callbacks.
- [x] Benchmark real Home with eager and deferred inspector registration in separate processes; record CPU for hidden startup, first open and returns. Profile the baseline before drawing performance conclusions.
- [x] Audit other eager startup views/controllers/menus; implement only clear, bounded changes supported by evidence, and report the rest as candidates rather than claiming measured savings.
- [x] Run focused and full relevant tests and build; request a scoped review; document release-pin and hardware limitations.

## Review focus

Hidden configuration must allocate no inspector or native controls. Toolbar stays available before construction. A parked visibility change does not allocate. First open reads the current selected item. Closing and reopening returns the same controller. Native collapsing still updates visibility and activity. No lazy property is accidentally touched by layout, input routing, menu validation or settings notifications.

## Execution ledger

- Tests RED: three new lifecycle cases could not compile because the lazy registration API did not exist. GREEN: all seven inspector lifecycle/selection tests pass.
- Added one-shot factory registration; kept the immediate installation API for existing owners. Loupe registers a weak-owner factory; selection/activity reads only the existing optional controller.
- Full kit and Loupe core/settings/native suites passed. No render implementation changed, so the render suite was not repeated in this follow-up.
- A/B benchmark preserved the old eager path in a separate process. Deferred registration measured 0.004 ms versus 1.347–2.181 ms; zero controllers before first show versus one. Populated first open through the factory measured 104.212 ms; subsequent selection/reopen rounds reuse one controller. Exact cold-application startup savings are not inferred from Home timings.
- Ruling: honor a saved visible inspector at startup rather than postponing explicitly visible UI. Closed startup remains unallocated; a parked visibility request waits for unpark.
- Ruling: app branch changed externally to polish-3; created the matching kit branch from its existing HEAD with every dirty change preserved. No branch reset, commit, push or release.
- Audit completed: viewer toolbar, eager Zoom/Scaling menus, neighbouring-folders UI, and small overlay shells. These are candidates only; no speedup is claimed and no unrelated lifecycle was changed. Existing lazy InfoPanelKit/SmartZoom/Settings/Stash/cheat-sheet text paths were verified.
- Independent requesting-code-review review found no important findings. Native benchmark and static diff checks passed. Measurements and audit are in docs/bench/2026-10-29-lazy-startup.md.
