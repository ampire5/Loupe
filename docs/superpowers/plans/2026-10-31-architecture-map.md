# Architecture Map Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Supply current architecture entry points across the family and give Loupe inspector metadata a separate owner.
**Architecture:** Documentation follows Package.swift and current source ownership. ViewerMetadataLoader owns async
selection state; ViewerWindowController consumes it and continues to own presentation.
**Tech Stack:** Swift 6.2 toolchain, SwiftPM, AppKit, Swift Testing, Markdown.
**Spec:** docs/superpowers/specs/2026-10-31-architecture-map-design.md

## Global Constraints
- No UI redesign, kit API change, dependency/pin update or new background concurrency.
- Use architecture-map branches; do not publish or merge.
- Keep public examples neutral and preserve local instructions.

## Review Focus
- A late answer after A→B→A must not overwrite a newer read of A.
- Stop must prevent size, metadata and delayed pending notifications.
- Non-file and nil selections must not start filesystem work.
- A quick answer must cancel the pending indicator.
- Maps describe actual ownership, including MouseService integration, rather than obsolete designs.

### Task 1: Current architecture maps
**Files:** docs/architecture.md and README.md in all seven repositories; local AGENTS.md entry points.
**Interfaces:** Maps link to existing targets/source/test/bench paths and one another where useful.
- [x] Read manifests and central ownership/concurrency implementations.
- [x] Write maps, README links and agent entry points; do not turn historical plans into current contracts.
- [x] Validate local Markdown paths and source symbols.

### Task 2: Viewer metadata ownership
**Files:** Sources/Loupe/ViewerMetadataLoader.swift, Sources/Loupe/ViewerWindowController.swift,
Tests/LoupeTests/ViewerMetadataLoaderTests.swift.
**Interfaces:** @MainActor ViewerMetadataLoader exposes private(set) url, size, metadata, isPending;
select(_ url: URL?), stop(), onChange: ((Bool) -> Void)? (Bool requests forced presentation).
Inject @Sendable async stamp/metadata readers; production defaults retain catalog and shared metadata caching.
- [x] Run existing inspector tests as baseline.
- [x] Write loader tests for progressive size/result, pending cancellation, stop, replacement and A→B→A.
- [x] Run them before adding the type; confirm the missing loader is the expected failure.
- [x] Extract loader and replace controller's duplicated task/state fields with one loader.
- [x] Run focused tests then full Loupe suite; inspect existing benchmark applicability (the browser benchmark does not exercise viewer metadata).
- [x] Review diff, validate docs and kits-check; record results and limitations.

## Validation results

- Baseline: 57 inspector/metadata tests passed before production edits.
- RED: new tests failed to compile because ViewerMetadataLoader did not yet exist.
- GREEN: 7 lifecycle tests passed, including A→B→A, stop during stat/read, pending and non-file selections.
- Ordinary Loupe suite: 2252 tests in 108 suites passed (6.670 s test time), using the repository decoder environment,
  `swift test --skip-update --jobs 4 --triple "$DEPS_TRIPLE" --skip LoupeRenderTests`.
- Architecture Markdown links, source/test paths and git whitespace checks passed across all seven repositories.
- `python3 scripts/kits-check.py --no-fetch`: kits: ok; kit clone branch/dirty notes reflect documentation in progress.
- Independent read-only review found no actionable code or architecture-map issues.
- No kit source/API or package pins changed; kit test suites were not rerun for documentation-only edits.
- No UI controls/screens or render code changed. The existing `LoupeBench inspector` exercises the browser inspector,
  not this viewer loader; running it would not measure this extraction. No UI latency improvement is claimed.
- Intel hardware and real-network latency were not measured. Heavy Metal render tests were not rerun.

The small cancellation correction is intentional: a cancelled read of A can no longer overwrite a newer read after
A→B→A. Each selection still starts at most the same two tasks (read and delayed pending) as the original controller.
