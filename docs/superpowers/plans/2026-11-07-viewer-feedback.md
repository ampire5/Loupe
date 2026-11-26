# Viewer Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Collect optional explicit feedback during normal photo viewing without changing existing ideal crops.

**Architecture:** Extend the private serial atomic dataset with optional object annotations. Viewer helper owns mutation cancellation and one revision-fenced undo checkpoint. Reuse native context menu and existing input action routing and comparison window.

**Tech Stack:** Swift 6, AppKit, Swift Testing.

**Spec:** docs/superpowers/specs/2026-11-07-viewer-feedback-design.md

## Global Constraints

- No synchronous filesystem work on main; bounded serial writes.
- Existing references remain untouched by object annotation.
- Missing labels are unknown; private labels stay outside the repository.

## Review Focus

- Old datasets decode with no annotations.
- Overlapping objects and empty pointer positions produce accurate choices.
- Undo cannot erase a later mutation from another window.
- Changed sources and stale detector contexts cannot accept feedback.
- Right drag zoom and mouse chords retain their behavior.

## Tasks

- [x] Add store tests for independent annotations, old JSON, invalid input and revision-fenced undo; run red.
- [x] Implement frozen object annotations, hit selection, store transaction/restore; run core tests green.
- [x] Add viewer helper tests for saving/undo and generic mouse action names; run red.
- [x] Implement confirmation wording, object context menu, assignable actions, comparison entry and undo command; run viewer tests green.
- [x] Update architecture and learning guide, run relevant suites and native UI checks, inspect diff, build/install.

## Execution notes

- Runtime object menus use fresh captured-image detection rather than URL caches. A same-URL replacement test
  also required clearing Foundation URL metadata caches before reading the source revision.
- Manual viewing captures Fit as a replay baseline, while a separate flag preserves Manual on save-and-next.
- Menu preparation is bounded to one request per viewer and cancelled on image replacement/window teardown.
- Existing reference geometry and the live private dataset remain untouched by the implementation/benchmark.
- Native layout bench and test limitations are recorded in docs/bench/2026-11-07-viewer-feedback.md.
