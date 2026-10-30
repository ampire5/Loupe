# Viewer mouse workflows implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline. No parallel writers in shared files.

**Goal:** Implement the approved mouse/keyboard workflow with bounded folder navigation and native toolbar pinning.
**Architecture:** Extend the pure input recognizer and action tables; route contextual actions through the current viewer/browser. Preserve SmartZoom policy while tracking a per-photo manual hold. Native toolbar pinning remains in its existing compatibility boundary.
**Tech Stack:** Swift, AppKit, Swift Testing.
**Spec:** docs/superpowers/specs/2026-10-30-mouse-workflows-design.md

## Constraints and review focus
- Preserve inspector and other existing dirty hunks; HomeScreenKit stays with the inspector task.
- No general app packaging or installation here. Debug and tests only in the allocated SwiftPM window.
- Test modifier release order, precise/momentum scrolls, discarded wheel bursts, reverse wrapping, empty groups, pending detection after manual changes, and fullscreen policy/stats restoration.

## Tasks
- [x] Add failing tests for RMB wheel/chord parsing, recognition and tap suppression, including Panel+RMB+wheel.
- [x] Extend PressKind/InputConf/InputMap/ButtonGestures and update defaults/help; preserve custom overrides and File View history.
- [x] Add reverse group/profile actions and tests; wire keyboard/mouse dispatch and SmartZoom selection without implicit activation.
- [x] Verify per-photo manual hold and preserve SmartZoom across manual presets/gestures; test late results and next-photo resume.
- [x] Drop excess wheel folder steps using existing repeat policy and pending-transition guard; no queued wheel tasks.
- [x] Add B pin/autohide action and stats suppression, with native fullscreen bench checks.
- [x] Run targeted then standard tests, real-window bench, diff checks. Record measurements/limits.
- [x] Return shared-file ownership and validation results to inspector coordinator; leave final build/install there.

## Validation ledger
- Direct user approval received for both shared viewer files and shared debug/test runs. The prepared integration was applied while preserving inspector changes.
- Pure input scratch pass: 119 tests passed. Shared standard suite and native bench results are recorded in `docs/bench/2026-10-30-mouse-workflows.md`.
- Read-only review caught modifier channel stealing, lost RMB releases, profile cycling with an unavailable model, modifier input cancelling SmartZoom, explicit pin under a hidden-fullscreen preference, and misleading stats menu state. Each was corrected and covered by recognizer/app tests or the native bench.
- Back/Forward and Gesture clicks dispatch on release; movement cancels their clicks. Panel wheel chords retain their channel across either release order. User input.conf overrides remain intact.
- Existing SmartZoomArrival tests cover same-photo cancellation and rearming on a different photo; app tests cover manual preset/thumb input retaining Auto/Pan and invalidating late pending requests.
- Existing folder-repeat throttle and pending FolderRequest guard are reused; no navigation queue or polling loop was added.
- No packaging, installation, commits, kit changes, or release operations in this task. Final packaging remains with the inspector coordinator.

## Hardware regression correction
- User clarified the requested preserved vertical gesture is RMB, not LMB. LMB panning stays unchanged.
- Reproduced the regression with `rightDragRemainsAvailableUntilModifierInputIsUsed`: it failed three assertions before the fix because adding the RMB wheel binding suppressed drag at press time.
- RMB drag is now available until wheel/chord use; a consumed modifier wheel ends its pending drag so it cannot retain a stale anchor. A fresh RMB press restores zoom.
- Real ViewerView event test verifies vertical drag changes scale, invalidates pending framing only on movement, retains SmartZoom power, and cannot resume after modifier-wheel use.
- Hardware-inaccessible RMB+Panel defaults removed from InputMap/template/help tests. Custom input syntax remains supported. Final user choice: Panel long press toggles Vibrance; RMB+middle stays Fit Width; strength is adjusted in the toolbar, with no wheel binding.
