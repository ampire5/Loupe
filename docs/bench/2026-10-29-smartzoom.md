# SmartZoom composition and Slot panel validation — 2026-10-29

Machine: Mac16,6, Apple Silicon, 14 physical cores. Debug build. Main-thread CPU time measured with CLOCK_THREAD_CPUTIME_ID; layout and Core Animation flush included. Five consecutive rounds. Build jobs capped at four (under one third of physical cores). No Intel machine was available: these measurements do not establish the Intel budget.

## Panel and Slot host

Production SmartZoomPanel, SlotsController and a real NSWindow; 24 groups, 11 object types, lazy retained page. Weights constructed only when expanded. The profile popup initially contains one selected item. Source snapshots are synthetic here; the full controller path is measured separately below.

| Action | Samples | Median CPU ms | Max CPU ms |
|---|---:|---:|---:|
| first-show | 5 | 49.086 | 74.021 |
| return | 25 | 0.534 | 4.964 |
| profile | 25 | 1.290 | 4.829 |
| group | 25 | 0.146 | 0.545 |
| weight | 25 | 0.030 | 0.098 |
| control-action | 1 | 0.869 | 0.869 |

The first inspection caught a bottom-origin scroll document and title overlap with the Slot capsule; the document is now flipped, the top reserves capsule space, and group buttons wrap. The final screenshot was inspected after those changes.

## Full viewer action path

Actual ViewerWindowController and its viewer actions; cached synthetic SubjectBoxes with 81 rectangles, no model execution. The toolbar opens the actual panel; slider actions run its real window override callback, recompose, update status and lay out the window. The mode/group actions are the same handlers as keyboard and mouse. A disposable configuration directory prevents changes to user preferences.

| Action | Samples | Median CPU ms | Max CPU ms |
|---|---:|---:|---:|
| panel-first | 1 | 62.589 | 62.589 |
| mode | 5 | 3.701 | 5.416 |
| group | 5 | 2.365 | 2.826 |
| weight | 5 | 1.031 | 4.192 |
| panel-return | 5 | 0.022 | 14.891 |

All measured actions fit 100 ms (navigation/show) and 50 ms (setting/control) on this Mac. Later rounds did not progressively slow. Menu tracking keeps the page focused and busy; hidden pages do no refresh work. Saving a detector profile runs off main at utility priority, with one save in flight per window.

## Algorithm regressions

The supplied 0034/0030 cached boxes were replayed with current production selection/composition sources. In auto: complete groups contain 5 and 3 boxes. In balanced: 5 and 4 boxes. All selected original rectangles fit in the automatic viewport; current scale 0.2 remains exactly 0.2 in pan-only mode. The selected combinations no longer depend on reach, head growth or box area. Native cap, class normalization, canonical duplicate groups, invalid boxes, pending-input revision, arrival rearming, size memory scoped by profile/group, pan-only/resize non-learning and legacy/new Slot roundtrips have regression coverage.

Ordinary zoom/position carry was also checked in the real viewer on the JPEG XL files; see [zoom carry](2026-10-29-zoom-carry.md). The installed old build's Fit reset came from automatic framing, not the basic main-branch carry implementation.

## Build and integration limits

Core/settings suite: 2164 core tests and 63 settings tests passed. Release product and app bundle builds passed. The bundle is signed with Local Code Signing and passes codesign verification. The standard serial render pass passed 136 tests (80.6 s). No dependency manifests or kit sources were changed. The existing kits-check reports HomeScreenKit's pinned revision outside origin/main, 50 local main commits not pushed and polish-2 not merged; these predate this change and prevent claiming kit integration/merge readiness. Other kit clone notes remain unchanged. This branch is left for review; no SmartZoom changes were merged into main.

## Follow-up after hands-on feedback

SmartZoom-2, same Mac16,6. Auto framing now has a Fit floor (Fit wins over the native-pixel cap). Pan defaults to reducing scale only when necessary to fit the group; `pan-overflow=keep` preserves scale and, if none of the selected boxes is visible, centres the selected box nearest the weighted centre. The Slot panel exposes this setting. Off stops subject requests and ahead scheduling; legacy `subject-analysis=off` is on-demand when SmartZoom is enabled. A delayed neighbour callback rechecks the current policy before queuing work.

Regression tests first reproduced the below-Fit scale (0.2 versus Fit 0.3333), the small-source cap conflict (0.75 versus Fit 10), and the empty-centre/overflow case. Updated tests pass. Full sequential run: 2167 Core tests and 63 Settings tests pass. The initial concurrent run exceeded two unrelated thumbnail-cover timeout budgets; both pass in the sequential run.

Real ViewerWindowController on disposable PNG fixtures, `subject-analysis=off`, SmartZoom initially Off, animation disabled:

- 100%, free zoom, and Fit Width preserve scale and position while Off.
- N enables Pan and reduces 400% to 184.162% to fit the selected group; Fit is 89.503%.
- 0 disables SmartZoom and analysis; legacy subject-target cycling enables Pan.
- The new panel first visit uses 56.386 ms main-thread CPU. Five mode/group/weight/return rounds stay within the existing action budgets; no increasing trend. Raw output: `/tmp/loupe-smartzoom-followup-window2.log`.

Reproduce with `LOUPE_CONFIG_DIR` pointing to a disposable config, `LOUPE_BENCH_WINDOW_RULES=1 LOUPE_BENCH_SMARTZOOM=1 LOUPE_BENCH_PANEL=1 Loupe --zoom-carry-bench <fixture-folder>` (001.png/002.png). No detector inference is required by the injected-box composition checks. Intel remains unavailable; these measurements are not Intel validation.
