# Loupe architecture

Current code map. Start here, then read only the relevant subsystem and its tests. `Package.swift` is the authority
for target dependencies. Update this map when ownership, target boundaries, persistence or cancellation changes;
historical documents under `docs/superpowers/` explain decisions, not necessarily today's implementation.

## Targets and boundaries

| Target | Responsibility | Entry points |
|---|---|---|
| Loupe | AppKit lifecycle, windows, input, source adapters and coordination | `Sources/Loupe/AppDelegate.swift`, `Sources/Loupe/WindowRegistry.swift`, `Sources/Loupe/ViewerWindowController.swift` |
| LoupeCore | Navigation, image/cache policies, decoding, configuration and persistence | `Sources/LoupeCore/ImageCache.swift`, `Sources/LoupeCore/ThumbnailStore.swift` |
| LoupeRender | Metal resources, tiled pyramid loading and rendering | `Sources/LoupeRender/MetalPyramidLoader.swift`, `Sources/LoupeRender/TileRenderer.swift` |
| LoupeInspector | Reusable browser inspector presentation | `Sources/LoupeInspector/BrowserInspectorController.swift` |
| LoupeSettings | SettingsKit integration and application settings pages | `Sources/LoupeSettings` |
| LoupeBench | Executable measurements of core/render/UI paths | `Sources/LoupeBench/main.swift` |

The executable assembles the targets. Core does not depend on the executable or render target; it uses loader
abstractions. System modules CTurboJPEG and CJXL expose native decoders; CHeif is also used by the bench.

## Ownership and lifetime

- `AppDelegate` owns the process-wide image cache, thumbnail store, database and position/recent/session stores.
  It creates windows through `WindowRegistry`; windows do not create independent copies of these caches.
- `WindowRegistry` retains viewer controllers, tracks native tab selection and visibility, and selects the cache's
  active session. A native tab is a separate window/controller/session.
- `ViewerWindowController` owns the AppKit view hierarchy, source adapters, panel presentation and one
  `ViewerSession`. `ViewerView` handles input/visual motion; `RenderLoop` owns the render thread.
  Raw trackpad contacts distinguish held folder and toolbar swipes from unpressed photo and filmstrip swipes.
  Primary click handling pairs light contacts for the status bar and plain presses for the browser. Force
  pressure invalidates both candidates before the mouse button is released. Horizontal
  swipes can reverse along the locked axis without lifting. Filmstrip scrolling previews a candidate
  without changing the viewer session until the strip settles. AppKit feedback marks panel changes, zoom
  stops and limits, photo boundaries and committed folder changes. Logitech feedback uses MouseService.
- `WindowToolbarController` retains the native toolbar and applies the native bottom tab accessory's fullscreen
  minimum height. `ViewerWindowController` reconciles `fullscreen-tabs`, the temporary B override and stats layout
  on native tab layout, selection and settings changes. Shown tabs keep the whole header stable; auto mode hides
  tabs and toolbar together. Layout requests coalesce into one deferred main-queue update, skipped after close or
  fullscreen exit, to avoid mutating AppKit chrome during layout. This adds no polling or recurring timers.
- `ViewerSession` owns playlist, displayed cache entries, transform, spread and navigation intent. Loading and
  residency belong to the shared cache. `close()` stops watchers/tasks and unregisters its cache/thumbnail requests.
- `ViewerMetadataLoader` owns the viewer info panel's selected file, stat/result and read/pending task lifetime.
  The controller owns panel layout, hold policy and diagnostics. `BrowserInspectorLoader` is the separate browser
  selection pipeline; it must not be confused with the viewer loader.

## Important flows

1. Finder/menu/argument → `AppDelegate` → `WindowRegistry.open` → controller → session playlist/focus.
2. Session focus → `ImageCache` planning → file read/decode/Metal pyramid → qualifying entry → session →
   `ViewerView`/`RenderLoop` snapshot → `TileRenderer`. Keep the shown image pinned until its replacement is ready.
3. Home browser → `LoupeHomeSource`, `FolderBrowserSource` or `PhotosBrowserSource` → streamed listings and
   thumbnail requests. The app supplies data; HomeScreenKit owns browser UI, selection and sorting interaction.
4. Viewer info selection → `ViewerMetadataLoader` → stat → thumbnail catalog metadata or `PhotoMetadataCache` →
   panel refresh. A replaced/stopped request cannot publish, even after returning to the same URL.
5. Session/position changes → app-owned stores → `StateDatabase`; explicit flushes and shutdown preserve state.
6. Shared subject detections → `CompositionOptions` and `SubjectFraming.composition` → physical circle support and
   protected regions → `SubjectComposition.resolve` → feasible pan before minimum outzoom. `BrowseFraming` owns
   cross-photo centre memory; current-photo constraints always win. The profile editor owns only its draft;
   `DetectorProfileFiles` serializes profile writes, and tab/folder options use the existing config layering.

## Threads, cancellation and persistence

The package uses Swift 6 language mode without blanket default actor isolation.
`ViewerSession` and AppKit coordination run on the main actor. `ImageCache`, `ThumbnailStore` and
`PhotoMetadataCache` isolate shared state in actors. `FileReader` and `DecodePool` bound I/O/decoding. Thumbnail
activity follows foreground cache work; keep the existing foreground/background priority relationship.
`RenderLoop` passes locked snapshots to its own thread, pauses the display link at rest and stops it on close.
A / Shift-A control the existing Lanczos limiter and its default. MetalFX uses the system spatial scaler
without an additional anti-ringing stage. Retired experimental MetalFX-limiter config and folder keys
are ignored when reading old state; they are absent from the schema, UI and render snapshots.
`DebandSettings` adds opt-in pre-scaling cleanup in `DebandCache`/`DebandKernels`. The render-thread cache
holds at most two weakly source-keyed FP16 tile windows of the selected resident level, within 1/32 of physical
RAM capped at 1 GiB. The visible input plus reconstruction padding is filtered; a fitting image can occupy the
complete level, but no pyramid is duplicated. Global tile coordinates and compact columns/slice offsets preserve
sampler, apron and EXIF geometry. The original remains immutable. Cache hits reuse cleanup across final colour/grain
changes; settings, source or coverage changes invalidate/replace bounded entries. Source reads use encoded views
where available, with linear-light unpremultiplication for alpha. Double recomputes its first-pass neighborhood;
Reference samples immutable originals with at most four iterations. No history, worker queue or timer is added.
Inactive/empty frames release cleanup caches. Allocation/budget failure keeps the original and emits one scoped
notice through RenderLoop's main-actor callback to the viewer toast. Completed/in-flight GPU buffers retain
resources normally; the cache budget is retained storage, not a process peak-memory guarantee.
Deband's private shader library and pipeline compile only on first active use on the render thread. MSL transfer
functions are shared with the normal library. Its buffer ABI is 64 bytes. Resample/compose reuse their former
padding for compact slice offsets without changing strides. MetalFX chooses encoded FP16 perceptual input/output
only for a cleaned frame, retaining sub-code values without changing processing mode. The compose pass encodes;
the final pass decodes each sampled texel before bilinear mixing. Limiting references the actual FP16 composed
input (half-rounding encoded values when reconstructing the first checker). Off keeps the original RGB8 path.
Reference adaptation provenance and LGPL license live in `third_party/libplacebo` and are copied into the app.
`MetalFXSource` supplies source geometry for final grain positioning and alpha coverage; its 16-byte
uniform also selects FP16 output decoding for debanding. No luminance limiter or image-profile luma
cache is retained. Grain remains fused into the final output shader.
`EffectFolderKeys` groups deband and grain modes with their parameters. N/J toggle the current
folder through `FolderSettings`, with the normal nearest-parent inheritance and asynchronous DB
persistence. Shift-N/Shift-J call the existing viewer `saveAsDefault` path for all parameters of the
effect: explicit values in other folders stay intact; redundant current-folder entries are removed
only when their inherited replacement matches. A failed save leaves folder entries intact.
Last non-off modes live as private metadata in the same bounded folder entries/DB batches; config
layering, folder override UI and default saving exclude that metadata. No schema or timer is added.
SmartZoom target stepping uses Option-N/Option-Shift-N. Menu checkmarks follow the active folder.
The app wires `ConfigSettingsStore` Quality filter editors to merged folder values and a folder-write
callback. Controls read the effective mode/parameters (including parent inheritance), write only the
current folder, and leave saved defaults untouched. With no photo they edit the defaults. Own-only
values remain separate for removable override notes. Folder/viewer changes refresh both editor values
and notes via a scoped settings-store notification; opening Settings refreshes cached editor values.
Explicit Shift commands still save the complete effective parameter group through the normal default path.
`GrainSettings` (including `grain-stage=before|after`, default before) travels in the resampling snapshot.
Before-upscale grain is a discrete field in original stored image
coordinates, independently bilinear-filtered into each output path using full source extent and level geometry.
It moves/zooms with the photo, independent of resident pyramid level; MetalFX never receives it as input.
Minification uses a fixed four-stratum filter and attenuates unresolved noise, keeping cost bounded.
Its radius approaches zero at 100% and is computed once per frame in `grainState`, then passed in the 40-byte grain uniforms.
After-upscale grain instead samples immutable banks in physical output pixels; its size/phase stay fixed through
zoom, pan and viewport clipping. Both stages use the same final output overlay, alpha coverage and color order.
J preserves the stage; neither stage feeds noise into MetalFX or allocates another pass/viewport buffer.
All output shaders apply this nonadaptive monochrome grain
after color correction, weighted by source alpha, before output-curve encoding. The immutable White/Fine/Soft/AV1/
Particles banks are prepared lazily on the render thread and cached by `MetalContext` behind a separate grain lock,
so file I/O never holds the pipeline-cache lock. Missing banks are cached as unavailable and leave the image intact.
Banks and their provenance/license are SwiftPM resources copied into the app by `make-app.sh`. Off binds only a
small zero texture; enabled grain has no masks, temporal seeds, full-screen intermediates, worker or recurring work.
The model cache owns loading, preflight and inference on one utility serial queue; only Sendable detection
values and booleans leave it. Vision/CoreML model references never escape the queue.
Clearing a window’s `SubjectFinder` queue (Manual mode or close) invalidates running requests and crops as well as
queued photos. Generation checks suppress stale callbacks, skip work after catalog/proxy reads and stop between
Vision stages and model crops, including before loading a model after waiting for its serial queue. A Vision call
already executing can finish; no subsequent stage starts for that request.
Metadata stat work is utility work; synchronous filesystem reads do not belong in a main-actor callback.
Navigation uses cancellation plus request identity checks because a cancelled filesystem/decode call may finish.
Home reachability and free-space checks share a utility `DecodePool`, capped at four calls and half the physical
cores. Their async deadlines cancel pending admission without waiting for a blocked kernel call; that call retains
its slot and path reservation until it actually returns. Reachability submits only a bounded batch of task waiters
and treats missing or timed-out answers as unavailable for cover reads. A cancelled cover that never acquired its
limiter slot does not release one.

`StateDatabase` backs positions, folder settings, recent folders, sessions and file viewing history. Thumbnail
catalog data is owned by `ThumbnailStore`. `Settings` and config stores handle user configuration; panel/window
preferences also use UserDefaults. Check each store's flush/lifetime contract before changing persistence.

## Shared packages

HomeScreenKit supplies Home/browser, chrome, filmstrip and slots; InfoPanelKit supplies viewer panel UI;
SettingsKit supplies settings controls; StashKit supplies server/path/web integration. Logitech input in the app
comes through `MouseClient` from MouseService; LogiHIDPP supplies shared hardware types and lower-level support.
See [kit release workflow](kits.md); change kits on the app's branch name and consume released tags.

## Where to change and verify

| Change | Read first | Verification |
|---|---|---|
| Window/tab routing | `Sources/Loupe/WindowRegistry.swift` | `Tests/LoupeTests`, session/tab core tests |
| Navigation, zoom, spread | `Sources/Loupe/ViewerSession.swift`, `Sources/LoupeCore/ViewTransform.swift` | `Tests/LoupeCoreTests`, relevant viewer tests |
| SmartZoom composition/profiles | `CompositionOptions.swift`, `SmartComposition.swift`, `SubjectComposition+Protection.swift`, `DetectorProfileEditor.swift` | circle composition/protection/browsing and native editor tests |
| Decode/cache scheduling | `Sources/LoupeCore/ImageCache.swift`, `Sources/LoupeCore/ThumbnailStore.swift` | cache tests and `docs/bench` |
| Browser inspector | `Sources/LoupeCore/BrowserInspectorLoader.swift`, `Sources/LoupeInspector` | `Tests/LoupeInspectorTests`, `LoupeBench inspector` |
| Viewer metadata | `Sources/Loupe/ViewerMetadataLoader.swift` | `Tests/LoupeTests/ViewerMetadataLoaderTests.swift` |
| Rendering | `Sources/Loupe/RenderLoop.swift`, `Sources/LoupeRender` | serial render pass in `scripts/test.sh` |

Use `scripts/test.sh` for everyday tests and `scripts/test.sh full` before merging renderer/transform changes;
see [testing policy](testing.md). Run `python3 scripts/kits-check.py --no-fetch` after local dependency work.
UI performance requires real-window CPU measurements; a model-only microbench cannot establish window latency.

## Gesture ownership

`GestureAxisLock` in Core fixes the first intentional scroll axis through momentum; a new non-momentum
begin resets it immediately. Phase-less scrolling re-arms after a 0.25 s gap. Loupe's `ViewerView` filters deltas
for button and folder gestures. Precise events that reach photo panning use both original deltas from the first
event through momentum. FrameScrub's `GestureRouter` filters before command routing. Pointer right-drag
zoom and right-button scrolling keep their first owner until release. Button recognition ignores zero deltas;
middle-button scrolling must cross a wheel step (12 precise points or one notched unit) before cancelling a click.
State is local to the existing input owners; no polling, new queues or dependencies are introduced.

`ZoomStopGesture` resolves continuous zoom stops for right-button drag, pinch and the thumb wheel's Pause
mode. It uses raw input speed to capture stops slightly early during slow movement and lets faster gestures
carry more of their travel through. It reports one haptic event per input event that reaches or crosses a stop.
Slow landings pause briefly. A small nudge after the pause selects a close neighboring stop in its direction.
Fast input can interrupt the pause. Mouse inertia stops
at its first landing and stays idle if the drag releases on a stop.
The minimum and maximum zoom remain limits, with the existing optional stretch.
