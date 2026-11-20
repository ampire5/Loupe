# SmartZoom learning: bounded work and native window

Measured 2026-11-04 on Mac16,6, Apple M4 Max, 14 physical/logical cores, 36 GiB RAM,
macOS 27.2 (26B123). Debug SwiftPM app, no other benchmark running. No real Intel machine was available.

## Workload and method

`Loupe --framing-learning-bench <output-dir>` creates neutral synthetic 1600×1200 PNGs and frozen boxes.
It does not open the personal catalog, detector model or configuration. Twelve photos have both Detail/Overview
references (24 stored rows); the active intention uses 12 references, four independent series, last series held out.
An expanded case uses four Vision categories and 18 generic custom categories, one reference and 1,301 coefficients.
This measures algorithm cost, not detector inference or photographic preference quality. Zero synthetic loss is not
an accuracy claim on photographs.

The production native learning window is created four times, laid out and displayed. Each is hidden and shown again.
`CLOCK_THREAD_CPUTIME_ID` measures main-thread CPU for these actions and the Fit button. Inference runs 20 times,
reporting the sorted upper median and maximum. `getrusage` reports peak resident memory including fixtures,
four windows and previews. Times exclude source detection/capture and first binary launch.

## Final debug measurements

| Action | Main-thread CPU / wall time |
| --- | ---: |
| First native window creation/display | 57.660 ms CPU |
| Later independent creations | 23.746 / 21.918 / 21.921 ms CPU |
| Hide/show existing windows | 0.661–0.872 ms CPU |
| Fit control | 1.406 ms CPU |
| 12-reference fit, 150 profile evaluations | 540.2 ms wall |
| Four-category inference, median / maximum | 1.832 / 1.936 ms wall |
| Expanded 22-category fit | 1,620.6 ms wall |
| Expanded inference, median / maximum | 49.832 / 50.662 ms wall |
| Process peak resident memory | 224,772,096 bytes (214.4 MiB) |

Repeated creation did not grow in CPU cost; returning reuses the window. Real on-screen controls and comparison
previews were checked in a temporary synthetic benchmark bundle. Previews clip to their own panel bounds.
A `cacheDisplay` PNG does not capture all native button layers, so visual verification used the actual window.

## Packaged release measurements

The same workload was then run through the signed `build/Loupe.app` executable built from functional commit
`81ca8a8` on branch `smartzoom-learning` (label: Framing learning). Packaging completed and strict signature
verification passed. No installation was performed.

| Action | Main-thread CPU / wall time |
| --- | ---: |
| First native window creation/display | 54.435 ms CPU |
| Later independent creations | 21.896 / 20.485 / 19.696 ms CPU |
| Hide/show existing windows | 0.614–0.740 ms CPU |
| Fit control | 1.290 ms CPU |
| 12-reference fit | 149.9 ms wall |
| Four-category inference, median / maximum | 0.318 / 0.379 ms wall |
| Expanded one-reference fit | 94.1 ms wall |
| Expanded inference, median / maximum | 3.558 / 3.657 ms wall |
| Peak resident memory | 226,803,712 bytes (216.3 MiB) |

These are measurements on the available M4 Max, not estimates for Intel. Final ordinary verification passed
2,303 tests (seven skipped), plus kit pin checks and whitespace checks. The release compiler emitted existing
warnings in unrelated code; the build completed successfully.

## Profiled optimization

An initial expanded debug inference measured 65.914 ms median / 67.129 ms maximum. A five-second `sample` at 1 ms
intervals showed repeated `FramingEvidence.framing` construction and category sorting beneath feature extraction.
The frozen context was hoisted once per candidate generation, feature extraction and replay, instead of rebuilding
inside each category/group loop. No scoring formula changed.

| Change measured separately | Expanded median / max | Expanded fit |
| --- | ---: | ---: |
| Before context hoist | 65.914 / 67.129 ms | 1,889.5 ms |
| Context hoist only | 50.686 / 53.102 ms | 1,627.5 ms |
| Then explicit later-group proposals | 49.832 / 50.662 ms | 1,620.6 ms |

The final row is a coverage fix, not an additional speed claim. Reproduce profiling separately from timing:

```sh
Loupe --framing-learning-bench <output-dir> &
bench_pid=$!
sample "$bench_pid" 5 1 -file <profile-file>
wait "$bench_pid"
```

## Bounds and remaining validation

The initial standard budget is serial utility work: 160 numeric evaluations, 96 proposals per sample and 16 ranking
epochs. At most 32 round-robin object roots enter neighbor search; at most one third of proposals are reserved for
explicit profile groups. This keeps the default 26-group profile representable while leaving room for new mixtures.
Samples stream through fitting rather than materializing a dataset-sized candidate tensor. These are conservative
prototype budgets measured above, not proven optimal limits for every machine or reference collection.

The app shares one fit lease, yields through an event-driven foreground gate and has no idle polling. Preview
requests use one serial utility decoder, with one running and one replaceable pending request per window. A stress
test verifies replacement; cancellation tests cover gate waits, stale results and the atomic commit cutoff. Storage
has a 4,096-reference ceiling and a 64 MiB bounded read; it preserves incompatible/damaged data.

Outstanding: real Intel window/control budgets, representative personal datasets, mounted-volume latency,
foreground navigation latency under fitting, and long-session memory measurements. Detector inference and image
loading can dominate real use and are not included in inference numbers. No renderer/shader/ViewTransform code
changed; ordinary core/app tests and existing composition tests cover the shared composer refactor.
