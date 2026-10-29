# Persistent profile and detector model selection

Mac16,6, Apple Silicon. Two user-supplied compatible object detectors, with 320×320 and 640×640 inputs. Model assets,
identities, sources and preparation instructions are private; this report contains only generic measurements. Intel
was unavailable.

## Real-window verification

The actual SmartZoom panel model selector was exercised on neutral PNG fixtures. In an isolated preference suite:

- Choosing a profile remembers its folder selection and a last-used fallback without saving Smart mode/composition.
- A → B → A loads the selected model, receives photo boxes with that setup's analysis identity, preserves the profile,
  and remembers the model selection. The same photo's old-model callback cannot satisfy a new-model request.
- Selecting another model while Manual preserves mode and viewport.
- A corrupt compiled-package selection fails, preserving the previous runtime and remembered model.
- Existing crop overlays are cleared when analysis identity changes; their replacements are requested after settling.
- A neutral generated-image preflight rejects classifier/raw feature observations rather than accepting them as an
  object detector with an empty result.

Raw private test output: `/tmp/loupe-model-switch-runtime-final.log`. Reproduce using a disposable `LOUPE_CONFIG_DIR`,
a unique `LOUPE_DETECTOR_PREFERENCES_SUITE`, and `LOUPE_BENCH_WINDOW_RULES=1 LOUPE_BENCH_MODEL_SWITCH=1 Loupe
--zoom-carry-bench <neutral-fixture-folder>`. Two compatible local models and a configured detector profile are needed.
The benchmark restores its prior detector preference values. The first uninstrumented attempt timed out; later runs
isolate preferences and report their stage explicitly.

## Responsiveness and bounded models

Main-thread CPU uses CLOCK_THREAD_CPUTIME_ID. Input-resolution labels come from compiled metadata. Measurements are
process first loads of already prepared local models; Core ML's persistent hardware caches may be warm.

| Action | Elapsed | Main-thread CPU |
|---|---:|---:|
| First retained panel visit | — | 47.262 ms |
| Select 320×320 | 442.932 ms | 16.163 ms |
| Select 640×640 | 1030.409 ms | 24.472 ms |
| Return to 320×320 | 11.581 ms | 8.345 ms |

Peak process RSS after both models was 288,653,312 bytes (about 275 MiB), unchanged on the return. A second run reached
about 292 MiB. The model cache is capped at two entries to cover the measured fast/large pair without retaining an
unbounded catalog of models. Loading, preflight and inference stay off-main; photo analysis starts only in active
SmartZoom. Model choice in Manual is an explicit user operation and may perform preflight on a generated image.

## Tests and review

2175 Core tests and 63 Settings tests pass in the sequential full run, `/tmp/loupe-models-full-final.log`. Regression
coverage includes profile-only persistence, removed profiles, distinct identities for equal-class different models,
JSON identity round-trip, neutral catalog metadata/invalid packages, incompatible Vision observations, and ordinary
key/template repeat compatibility. Independent review found and verified fixes for stale crop overlays and unsupported
model acceptance.
