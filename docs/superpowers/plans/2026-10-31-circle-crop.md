# Circle crop implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add circle-based rectangular framing and per-class clipping protection with shift before outzoom.

**Architecture:** Keep configuration in CompositionOptions, geometry in LoupeCore and UI in the retained AppKit
SmartZoom panel/profile editor. Detection remains shared and independent of composition preferences.

**Tech Stack:** Swift, CoreGraphics, AppKit, Swift Testing.

**Spec:** docs/superpowers/specs/2026-10-31-circle-crop-design.md

## Global Constraints

- Build on local main c1984a3; preserve the metadata-loader extraction.
- Radius uses oriented image pixels; the final group support is rectangular.
- Shift before reducing scale; manual zoom remains unrestricted; Pan Keep zoom retains scale.
- Public fixtures and documentation are neutral. No private models, paths or assets in the repository.
- Existing glass/slot lifetime and input-hold behaviour remain intact.

## Review Focus

- Profile defaults and explicit Off overrides must survive save/load and per-folder override paths.
- Non-square images must have physically round circles; callers must supply the actual image size.
- Protection must work for a class outside the chosen priority group and for boxes near photo edges.
- Keep zoom conflicts and manual holds must not silently change the user's zoom.
- Class-table reuse, invalid text and editing menus must preserve drafts and panel interaction holds.

### Task 1: Circle options and geometry

**Files:** CompositionOptions.swift (new extraction), SmartComposition.swift; CircleCompositionTests.swift.
**Interfaces:** `SubjectFraming.composition(_:kind:options:imageSize:)`; options for radius/class overrides and protection.
- [x] Write failing tests for pixel-radius geometry, overrides, parsing and profile round trips; watch RED.
- [x] Implement validated options and circle support; pass actual image sizes through all composition call sites.
- [x] Run focused composition/profile tests and record results.

### Task 2: Protected framing solver

**Files:** SubjectComposition+Protection.swift (new), SmartComposition.swift; CircleProtectionTests.swift.
**Interfaces:** `SubjectComposition.resolve(_:autoZoom:size:preferredCenter:)` returns transform and adjustment reason.
- [x] Write failing tests for shift without scale loss, minimum outzoom, per-edge limits, scope, padding and Keep zoom.
- [x] Implement feasible centre projection, soft-margin fallback and protection diagnostics; preserve transform wrapper.
- [x] Run geometry tests, including deterministic randomized constraints and invalid/source-edge cases.

### Task 3: Session integration and stable browsing

**Files:** BrowseFraming.swift, ViewerSession.swift, ViewerSession+Status.swift, ViewerWindowController.swift, SubjectOverlay.swift.
**Interfaces:** stable previous centre from BrowseFraming; result note passed to the existing panel snapshot.
- [x] Write failing tests for stable consecutive targets, current-photo protection and profile/manual-input boundaries.
- [x] Integrate resolution and diagnostics, accurate overlays and protected kinds already present in shared analysis.
- [x] Run browsing/session/overlay tests.

### Task 4: Profile editor and quick controls

**Files:** DetectorProfileEditor.swift, SmartZoomPanel.swift, DetectorProfileDraft.swift; relevant LoupeTests.
**Interfaces:** existing edit/save callbacks carry validated CompositionOptions keys.
- [x] Write failing draft/editor action tests for class radius/cut/padding, invalid edits and explicit Off/inheritance.
- [x] Add global controls and class detail editing using native controls, retained views and existing glass treatment.
- [x] Verify live edits, profile save/reopen and folder overrides with neutral fixtures.

### Task 5: Verification and delivery

**Files:** README/configuration docs, docs/architecture.md if ownership changes.
- [x] Document controls and per-edge semantics with neutral examples.
- [x] Run ordinary repository tests, focused UI checks, kits check and diff/privacy inspection.
- [x] Request a fresh whole-branch review; fix material findings with regression tests and repeat relevant checks.
- [x] Leave the completed work on circle-crop; report validations and any limitations, without pushing or merging.
