# Manual Zoom Navigation Implementation Plan

> **For agentic workers:** Execute the tasks below in order and verify them against the real viewer session.

**Goal:** Make manual zoom repeatable across first visits, revisits, and window shape changes.

**Architecture:** `ViewerSession` owns the tab's bounded photo framing memory and its current folder's zoom reference. `PhotoSwitchView` computes first-visit zoom from the reference, with current-photo pan behavior and the selected carry mode.

**Tech stack:** Swift, AppKit, Swift Testing.

**Spec:** [Stable manual zoom across photo navigation](../specs/2026-11-23-zoom-navigation-design.md).

## Tests and implementation

- [x] In `Tests/LoupeTests/ViewerManualZoomNavigationTests.swift`, exercise real viewer navigation with large and small fixtures. Expect 40%, 100%, and 200% on the smaller photo for Scale, Share of photo, and Share of screen. Expect 40% on the third photo through automatic carry. Navigate back after an explicit zoom on another photo and assert that the first photo restores its own zoom and center at the new window shape.
- [x] Run `scripts/test.sh --filter ViewerManualZoomNavigationTests` and confirm the new assertions detect the missing behavior.
- [x] In `Sources/LoupeCore/PhotoSwitchView.swift`, allow a manual reference distinct from the outgoing photo. Apply the Share of photo cap when using that reference. Keep existing behavior for named modes and the SmartZoom path.
- [x] In `Sources/Loupe/ViewerSession.swift`, record framing at the boundary between displayed photos. Preserve the reference until manual input, a fresh browsing sequence, or Keep Zoom being re-enabled. Restore only for compatible layouts and let existing late refinements keep the displayed transform.
- [x] Wire Keep Zoom changes through the existing effective-config update. Update `docs/architecture.md` for the new ownership. Check rapid navigation, folder changes, and existing SmartZoom and spread paths.
- [x] Run the focused tests and the standard core test pass. Check the diff for whitespace and unrelated changes.
