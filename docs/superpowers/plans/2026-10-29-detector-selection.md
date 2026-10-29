# Persistent Detector Selection Plan

Execute inline with superpowers:executing-plans; review the final change independently.

1. Add regression tests for remembering profile without saving Smart mode or ordinary zoom; automatically remember per-folder selection and last-used fallback.
2. Inspect available models and format. Add an off-main model catalog and a retained model selector.
3. Make inference/model caches and boxes model-specific, reject stale completions after selection changes, and persist selected model.
4. Verify profile relaunch behavior and model A→B→A, errors, Manual/no inference, UI responsiveness; build and sign.


## Completed verification

- Profile choice now writes only detector/profile keys for the folder and remembers a last-used fallback. Invalid/removed remembered profiles are ignored.
- Model catalog supports user-supplied compiled Core ML packages; metadata and directory enumeration run off-main. Model preparation scripts and assets remain private, outside the repository.
- Setup snapshots and analysis identities separate model/class/look results in memory and catalog. Same-photo callbacks and crop results check identity; model changes clear old crop overlays.
- Preflight runs a neutral generated-image request off-main and rejects incompatible Vision result types. Failed selection retains the previous model; selecting a model in Manual preserves mode/view.
- Real-window A/B/A model switching, remembered folder profile, Manual, and invalid-model paths pass. Main-thread CPU and peak RSS measured; see docs/bench/2026-10-29-detector-models.md.
- Full sequential run: 2175 Core + 63 Settings tests pass. Fixed the ordinary Fill key's repeat policy to match the input template, caught by the broader check.
- Independent review completed, both findings fixed and rechecked. Final bundle label SmartZoom-4. Public diff inspected for private specifics.
