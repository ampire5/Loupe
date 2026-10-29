# Separate Zoom Workflows Implementation Plan

> Execute inline with superpowers:executing-plans; one fresh-context review at the end.

**Goal:** One direct command enters Auto; ordinary zoom and SmartZoom have independent settings and save scopes.
**Architecture:** Keep the existing composition pipeline and shared mode state. Replace state-dependent command toggles and mixed saves with pure policies in SmartZoom/ZoomKeys and explicit controller/view routes.
**Tech Stack:** Swift, AppKit, Swift Testing.
**Spec:** docs/superpowers/specs/2026-10-29-zoom-workflows-design.md

## Constraints
Existing branch polish-2 only. No kit changes, no main integration. Keep analysis bounded and off in Manual. Retain Slot pages, no synchronous file I/O for new controls.

## Tasks
- [x] Add failing policy tests: direct Auto repeated, first power Auto, fixed digits, disjoint saves; implement policies.
- [x] Wire direct commands, preserve profile at Fit, remove implicit profile-size learning and apply Auto over saved ordinary views.
- [x] Replace toolbar set switch, expose separate saves and clear status, update help.
- [x] Add real-window regression scenarios and measure actual controls; run Core/Settings checks, review diff, build/sign app, commit.

## Review Focus
Restored per-photo views cannot bypass Auto; ordinary keep/carry settings cannot affect Auto; 0 cannot erase profile; mouse alias must be idempotent; saving either world cannot persist the other.


## Rulings and verification

Option-S preserves the view on exit; resuming reapplies Smart composition. G is a compatibility power alias, not a keyboard-set switch. Fixed numeric 3 now means ordinary Fill; legacy fill-subject remains an explicit configurable action without a default key.

Settings.reload now loads detector.conf as defaults before applying explicit loupe.conf profile selection; a pure parser regression covers precedence. Legacy writes of step-pan/step-zoom no longer change Smart state. Auto bypasses ordinary saved/collapsed arrivals and uses profile size, without teaching from manual zoom.

Fresh independent review completed; no important findings remain. Real-window workflow checks and performance were run on Mac16,6; see bench report. Full sequential 2170 Core + 63 Settings pass. Later key-label/menu regressions pass separately after fixing 3. App artifact built with SmartZoom-3 label; no main integration requested.
