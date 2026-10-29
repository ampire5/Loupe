# Persistent detector selection and model switching

User request: retain the last chosen profile after app relaunch and allow choosing another downloaded model.

- Selecting a profile automatically remembers it for the current folder and records a last-used fallback. Existing explicit global/folder defaults retain precedence over the fallback. Smart mode, ordinary zoom settings and composition parameters are not implicitly saved.
- A model selector belongs in the retained SmartZoom Slot panel, independent of the composition profile. Switching models preserves profile/weights, cancels pending composition and starts fresh analysis for the current image if SmartZoom is enabled.
- Discover supported local models off-main, showing name and input resolution where available. Never silently reuse boxes or pending callbacks from another model. Selection survives relaunch. A failed model load leaves the previous working selection available with a clear error.
- Existing per-window foreground/background priorities and bounded queues remain. Models are loaded and preflighted off-main; no photo analysis while Manual.
- The selector supports compiled Core ML object detectors. Model preparation and assets remain private; public documentation describes only user-supplied generic models.
- The model cache retains at most two entries; local A/B/A verification measures load latency, main-thread CPU and peak process RSS. Incompatible Vision observation types are rejected during preflight.
