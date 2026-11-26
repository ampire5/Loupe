# Photo Comparison Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement and verify each task.

**Goal:** Compare a fixed pair of photos from File View or two tabs with independent and linked transforms.

**Architecture:** A two-transform model in LoupeCore owns the geometry. A native comparison surface displays two Metal viewports inside a viewer tab, using the tab's existing cache session and a two-item focus. WindowRegistry owns the selected photo and opens the transient tab.

**Tech Stack:** Swift 6, AppKit, Metal, Swift Testing.

**Spec:** [Photo comparison](../specs/2026-11-24-photo-comparison-design.md)

## Tasks

- [x] Add `PhotoComparison` in LoupeCore. Test a 6000 × 4000 and 3000 × 2000 pair at equal display size, common pan limits, manual relinking and zoom limits. Run `scripts/test.sh --filter PhotoComparisonTests`.
- [x] Add the native viewport and the pair's cache focus to Loupe. Use oriented source sizes, existing render settings and visible-tab lifecycle. Verify loading, pan, zoom, keyboard input and closing on real windows.
- [x] Wire File View selection and the two-step File menu flow to WindowRegistry. Ensure original tabs are untouched and comparison tabs are skipped in stored sessions.
- [x] Run the repository tests and measure the comparison window workload. Update the architecture map.
