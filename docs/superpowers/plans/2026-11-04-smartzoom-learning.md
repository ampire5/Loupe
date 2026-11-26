# SmartZoom Learning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach local SmartZoom profiles from explicit reference pan/scale, with object-aware diagnostics and reversible application.

**Architecture:** Value snapshots and pure replay/evaluation live in LoupeCore. A serial utility worker fits bounded parameter neighborhoods and the app owns asynchronous capture, comparison, and profile scope. A separate atomic private dataset avoids changing the existing state database schema.

**Tech Stack:** Swift, Foundation, AppKit, existing composition resolver and profile configuration, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-04-smartzoom-learning-design.md`

## Global Constraints

- No cloud service or image upload is part of this project.
- The supervised target is the complete displayed transform: horizontal position, vertical position (pan), and scale.
- Concrete user-supplied labels and their mapping stay private.
- Closing the learning window cancels its run.
- Fitting never silently changes the current viewer or persisted profile.
- No synchronous I/O, encoding, decoding or fitting on the main actor; no polling at rest.
- Preserve unrelated working-copy changes; no kit edits or dependency updates are needed.

## Review Focus

- Manual gestures disabling SmartZoom must preserve originating profile, behavior and Pan input.
- Pending detection after navigation must never attach another photo's boxes.
- Multiple windows or stale fits must not overwrite newer dataset/profile changes.
- Invisible reference objects and repeated same-class boxes must not distort scoring.
- Corrupt/newer datasets and failed writes must not destroy references or claim successful persistence.

### Task 1: Reference values and private storage

**Files:** create `Sources/LoupeCore/FramingReference.swift`, `Sources/LoupeCore/FramingReferenceStore.swift`, `Tests/LoupeCoreTests/FramingReferenceTests.swift`.

**Interfaces:** `FramingGeometry` captures/reconstructs a settled `ViewTransform`; `FramingProfile` snapshots name, chain, size and composition using existing config serialization; `FramingReference` holds stable ID, source revision/bookmark, input/target, behavior, detections, category mapping, thresholds, group and split. `FramingReferenceStore` asynchronously snapshots and atomically upserts/removes/reassigns records with a dataset revision.

- [ ] Write tests for round trips, invalid geometry, profile/viewport replacement identity, all-category evidence, group splits, restart, write failure and unknown schema preservation; run to observe missing-symbol failures.
- [ ] Implement versioned Codable values and a serial off-main atomic store, preserving previous data on failed writes; source stat/bookmark work runs on that queue.
- [ ] Run `scripts/test.sh --filter FramingReferenceTests`; require PASS, then commit task files.

### Task 2: Pure production replay and diagnostics

**Files:** create `Sources/LoupeCore/FramingEvaluation.swift`, `Tests/LoupeCoreTests/FramingEvaluationTests.swift`; modify `SubjectBoxes.swift`, `CompositionOptions.swift`, `SmartComposition.swift` for explicit captured detector context.

**Interfaces:** `FramingReplay.transform(reference:profile:) -> ViewTransform` uses frozen score/head context without global mutation. `FramingEvaluation.measure(reference:predicted:)` returns signed X/Y, log scale, overlap and stable per-instance projected geometry/visibility/edge errors; `loss` combines global and category-normalized object terms.

- [ ] Test Auto/Pan parity, no subjects, captured context independent of global detector, same-scale pan errors, clipped/full centers, exclusions, duplicate instances and candidate-independent weights; observe RED.
- [ ] Add explicit context to shared composition with existing defaults for existing callers; implement projections through ViewTransform and robust bounded category-normalized losses.
- [ ] Run `scripts/test.sh --filter FramingEvaluationTests --filter SmartComposition --filter Circle --filter Protection`; require PASS, then commit.

### Task 3: Parameter registry and bounded fitter

**Files:** create `Sources/LoupeCore/FramingParameters.swift`, `Sources/LoupeCore/FramingFitter.swift`, `Tests/LoupeCoreTests/FramingFitterTests.swift`.

**Interfaces:** Registry enumerates supported numeric/discrete/chain neighbors and applicability. `FramingFitter.fit(profile:references:budget:checkpoint:progress:) async throws -> FramingFitResult` uses only training references, deterministic search, cancellation/yield checkpoints, immutable reports and held-out evaluation after search. Results include baseline, candidate, dataset identity, evaluations and per-sample diagnostics.

**Approved amendment:** Primary selection uses `FramingCandidates` (bounded instance/neighborhood crops plus chain baseline), `FramingFeatures` (category-normalized displayed geometry) and versioned `FramingPolicy` (local learned ranking). Fit pairwise reference/proposal feature differences using object-aware crop loss; report oracle candidate coverage separately from learned ranking. Preserve chain-only fallback. Task 4 applies and rolls back a private intention policy containing its own numeric proposal parameters; Task 5 previews the policy's actual inference output.

- [ ] Test behavior recovery for numeric and chain choices, every composition field registered, unobserved fields unchanged, training/validation isolation, series weighting, bounded evaluations, cancellation and deterministic results; observe RED.
- [ ] Implement multiscale coordinate/block neighborhoods plus bounded seeded restarts, shared evaluator and baseline-preferring ties. Keep steady framing unchanged without sequences. Optional per-example search reports best found, never impossibility.
- [ ] Run `scripts/test.sh --filter FramingFitterTests`; require PASS, then commit.

### Task 4: Viewer capture and safe application

**Files:** create `Sources/Loupe/FramingLearningCoordinator.swift`, `Tests/LoupeTests/FramingLearningTests.swift`; modify `ViewerSession.swift`, `ViewerWindowController.swift`, `AppDelegate.swift`, `WindowRegistry.swift`, `DetectorProfileEditor.swift`, `SmartZoomPanel.swift`.

**Interfaces:** AppDelegate/registry share one reference store. Session retains originating behavior/input snapshot. Viewer capture freezes URL, geometry, effective profile and complete detector evidence; pending requests are identity checked. Coordinator loads records, runs fitting with foreground-yield checkpoint, checks revisions and applies a tab candidate or atomically persisted private policy with rollback.

- [ ] Test gesture-origin capture, navigation during pending capture, unsupported spread/rotation, stale dataset/profile apply, writer failure and rollback; observe RED.
- [ ] Wire Save reference and Learn actions into the panel/editor and Zoom menu. Capture all enabled classes, never silently translate absence into a negative. Reset destination transient framing state on apply.
- [ ] Run `scripts/test.sh --filter FramingLearningTests`; require PASS, then commit.

### Task 5: Learning window and comparison

**Files:** create `Sources/Loupe/FramingLearningWindow.swift`, `Tests/LoupeTests/FramingLearningWindowTests.swift`.

**Interfaces:** Retained native window lists references and editable series/validation membership, bounded progress/cancel, per-object error details, per-example diagnosis, baseline/candidate image previews, balanced hidden labels and four persisted votes. Apply to tab, Save profile and Undo call coordinator methods with stale checks.

- [ ] Test close cancellation, balanced comparison assignment, vote persistence, revisions, disabled stale actions and remove/group controls; observe RED.
- [ ] Implement virtualized tables, off-main bounded image preview loading and native comparison, with error states and usable/missing counts. Keep UI responsive and idle without timers.
- [ ] Run `scripts/test.sh --filter FramingLearningWindowTests`; require PASS, then commit.

### Task 6: Measurement, architecture and final verification

**Files:** add learning workload to `Sources/LoupeBench`, native-window bench in `Sources/Loupe`; update `docs/architecture.md`, add `docs/bench/2026-11-04-smartzoom-learning.md` and usage documentation.

- [ ] Measure serial candidate/sample throughput and peak memory on generic synthetic workloads; choose bounded defaults from measurements and record machine and dataset size.
- [ ] Exercise the real native window repeatedly with main-thread CPU timing, first/return visits, control actions, cancellation and foreground navigation. Report Intel verification as outstanding if hardware is unavailable; never substitute Apple Silicon/Rosetta for a real Intel timing claim.
- [ ] Run `scripts/test.sh`, relevant render checks if transform behavior changed, `python3 scripts/kits-check.py --no-fetch`, and `git diff --check`; require passing checks or clearly isolate pre-existing failures.
- [ ] Run one independent whole-change review, resolve important findings with regression tests, inspect the diff for private data, and commit verified changes. Do not merge, push or install without task scope requiring it.

## Execution record

Tasks 1–5 are implemented, independently reviewed and covered by regression tests. The implementation uses bounded
parameter neighbors plus a deterministic candidate ranking fit; the initial optional seeded restart/per-example
optimizer is deferred. Best-proposal coverage remains visible. Votes are stored for evaluation, not fed into training.
Task 6 measurements and final checks are recorded in the bench document. Real Intel hardware and a representative
private reference collection are unavailable in this session; their responsiveness/quality validation remains open.
