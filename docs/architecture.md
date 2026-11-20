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
  on native tab layout, selection and settings changes. In the viewer, the default auto mode hides tabs and toolbar
  together. The shown mode keeps the whole header stable, and File View keeps its toolbar pinned.
  Layout requests coalesce into one deferred main-queue update, skipped after close or
  fullscreen exit, to avoid mutating AppKit chrome during layout. This adds no polling or recurring timers.
- `ViewerSession` owns playlist, displayed cache entries, transform, spread and navigation intent. Loading and
  residency belong to the shared cache. `close()` stops watchers/tasks and unregisters its cache/thumbnail requests.
- `EmbeddedPlayback` is created per viewer only for filesystem media. Loupe owns media selection, the
  poster, provider activation and standalone handoff. FrameScrub supplies the remote picture, transport
  and playback engine through the separately installed `local.framescrub.playback` extension.
- `ViewerMetadataLoader` owns the viewer info panel's selected file, stat/result and read/pending task lifetime.
  The controller owns panel layout, hold policy and diagnostics. `BrowserInspectorLoader` is the separate browser
  selection pipeline; it must not be confused with the viewer loader.

## Important flows

1. Finder/menu/argument or `loupe://open?path=…` → `AppDelegate` → `WindowRegistry.open` → controller → session playlist/focus.
   `OpenLink` decodes the percent-encoded absolute file or folder path before tab routing or instance handover.
2. Session focus → `ImageCache` planning → file read/decode/Metal pyramid → qualifying entry → session →
   `ViewerView`/`RenderLoop` snapshot → `TileRenderer`. Keep the shown image pinned until its replacement is ready.
3. Home browser → `LoupeHomeSource`, `FolderBrowserSource` or `PhotosBrowserSource` → streamed listings and
   thumbnail requests. The app supplies data; HomeScreenKit owns browser UI, selection and sorting interaction.
   `FolderBrowserSource` normalizes the URLs used by photo marks in the background task that orders them.
   A new listing cancels that preparation and only the current listing can publish its marks.
   Grid and sidebar favorite commands share `BrowserPlaces`. It keeps the existing ordered `browser_pins` rows,
   commits changes before publishing them, and notifies every Home window sharing the store. The sidebar separates
   Favorites from system Places and exposes the same ordered folders as a separate Favorites source.
   The source uses the normal folder cover queue and resolves each favorite's catalog location independently.
   Recursive browsing sends flattened image entries through the existing thumbnail and viewing-history flow.
   Opening a photo from that grid passes its listing, root sort and name filter through WindowRegistry to the
   viewer. ViewerSession shows the photo while a shared worker prepares the sequence. Later opens and navigation
   cancel unfinished preparation. The resulting snapshot supports normal file thumbnails and viewing history;
   single-folder watches and re-reads do not replace it.
   The walk is cancelled when the browser changes listing. The thumbnail catalog keeps its last successful
   result in a separate table by volume and folder and serves it provisionally during a fresh walk.
   Opening a folder from the sidebar in a new tab uses WindowRegistry and starts that native tab in Home's browser.
4. Viewer info selection → `ViewerMetadataLoader` → stat → thumbnail catalog metadata or `PhotoMetadataCache` →
   panel refresh. A replaced/stopped request cannot publish, even after returning to the same URL.
5. Session/position changes → app-owned stores → `StateDatabase`; explicit flushes and shutdown preserve state.
6. Shared subject detections → `CompositionOptions` and `SubjectFraming.composition` → physical circle support and
   protected regions → `SubjectComposition.resolve` → feasible pan before minimum outzoom. `BrowseFraming` owns
   cross-photo centre memory; current-photo constraints always win. The profile editor owns only its draft;
   `DetectorProfileFiles` serializes profile writes, and tab/folder options use the existing config layering.
7. Zoom menu crop shortcuts (⌥1/⌥2, plus Shift to save and advance) route only to the key viewer; repeats and
   attached sheets and text input are rejected. `MainMenu` admits only these Option-digit commands alongside
   the existing Command/Control shortcuts. The viewer shows intent/file confirmation after successful persistence.
   Normal-viewing confirmations and frozen per-object notes are independent; missing labels remain unknown.
   Explicit reference command → `ViewerView` commits the zoom target and stops inertia/elastic motion →
   `ViewerFramingLearning` freezes source/profile/input/desired transform, using the same clamped centre as rendering
   and removing historical elastic residuals from replay input → decoded
   cache entry's `sourceStamp` checked against off-main stat → fresh `SubjectFinder` detection on the captured image
   → private `FramingReferenceStore`. All enabled custom classes and Vision face/person/object/saliency remain evidence.
8. `FramingLearningWindow` → `FramingLearningCoordinator` → serial utility `FramingFitter`: tune proposal geometry,
   generate bounded instance/neighborhood candidates, learn their score from reference differences. Reports include
   overall X/Y/scale and per-instance placement/visibility/cut errors. Validation series never train the model.
9. Explicit Apply installs a tab policy; Save persists it atomically with references. Each Detail/Overview policy
   has a stable external baseline and its own internal proposal parameters; applying one cannot change the other's
   fingerprint. `ViewerSession.smartFraming` uses an asynchronous predicted crop when ready, otherwise the existing
   chain. Prediction identity includes frozen geometry/detections/detector context, and manual input rejects late work.

7. Filesystem playlist or Home listing → `PlaybackMedia` → video poster or animated GIF/WebP frame-zero
   poster. Regular GIF and WebP photos use the image viewer. Video paths stay in playlist order, sit alone
   in two-page mode, and skip the photo cache. ThumbnailStore requests video posters using its existing
   catalog and worker limits. AVFoundation generates the still and reads stream facts from the same asset when
   the system can decode it. Card badges use the stream's display dimensions and frame rate. Older video cache
   entries that hold only poster dimensions are rebuilt on demand.
   The photo cache, thumbnail store and metadata readers use a complete first frame cut from a bounded
   GIF prefix. The provider receives the untouched file descriptor for playback and seeking.
8. Play or `playback-autoplay` → `EmbeddedPlayback` → ExtensionKit discovery and the remote `player` scene.
   A protocol handshake precedes the read-only file descriptor. The poster stays visible until the
   provider acknowledges its first picture, or when the extension is unavailable. XPC errors arrive on
   the connection's queue and dispatch to the main actor. Detached scenes discard errors and pending
   frame requests. Protocol v4 advertises
   the provider's active playback key bindings. Loupe owns Scrub Lock and captures modifier gestures at
   the window. It keeps the route through the momentum tail and discards the tail when the session ends.
   FrameScrub maps captured events to playback actions using its own input settings. Loupe handles a right
   click on the poster. The remote FrameScrub picture receives its own button events and toggles playback
   on release within click slop. Loupe receives wheel events over both surfaces. A vertical wheel event
   can claim the press for frame stepping and cancels a pending click in the provider. The viewer keeps
   the first input owner and consumes the scrub's momentum after release. A first step on the poster opens the
   provider paused at the requested frame. The host sends one frame-step request at a time and folds
   further travel into one pending delta. Plain arrows navigate
   Loupe outside the lock, and Option-Shift-arrows step the provider. Protocol v5 toggles play/pause
   with Space in the viewer and defines a fixed transport row. The floating strip and its reveal zone
   start above that row, and scroll over the transport cannot turn into file navigation. A beside strip
   keeps its own space below the player. The host forwards indirect three-finger touches from the
   picture to its existing playlist recognizer and cancels any provider scroll that started with two fingers.
   A left double click on the picture goes back to the folder. Protocol v6 routes Auto Color
   and vibrance to FrameScrub Core. Standalone handoff asks for the last presented timestamp and sends
   a paused FrameScrub link.

## Threads, cancellation and persistence

The package uses Swift 6 language mode without blanket default actor isolation.
`ViewerSession` and AppKit coordination run on the main actor. `ImageCache`, `ThumbnailStore` and
`PhotoMetadataCache` isolate shared state in actors. `FileReader` and `DecodePool` bound I/O/decoding. Thumbnail
activity follows foreground cache work; keep the existing foreground/background priority relationship.
`RenderLoop` passes locked snapshots to its own thread, pauses the display link at rest and stops it on close.
The viewer loading indicator stops animating while Home covers it or the window is hidden. Reduce Motion
keeps its loading mark static.
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
For playback, WindowRegistry reports native tab visibility and activity. Navigation, leaving the viewer,
hiding, and disconnect invalidate the remote scene and XPC connection. Cancelling an open also invalidates
its selection check. The blocking descriptor open and viewer poster have separate single-slot pools shared by
windows. They keep their slots until the blocking calls return. A poster alone does not start a playback or
indexing process. `make-app.sh` packages `Contents/Extensions/Loupe.appexpt` to register the external extension
point with the system.
Home reachability and free-space checks share a utility `DecodePool`, capped at four calls and half the physical
cores. Their async deadlines cancel pending admission without waiting for a blocked kernel call; that call retains
its slot and path reservation until it actually returns. Reachability submits only a bounded batch of task waiters
and treats missing or timed-out answers as unavailable for cover reads. A cancelled cover that never acquired its
limiter slot does not release one.
Places keeps a system root navigable when the check has no answer, so the sidebar can reveal the current folder
under that root. A negative check dims the place. Sidebar Favorites publish the saved order with cached status
and share one background directory check across Home windows for the same set of paths. Unavailable or
unanswered folders stay in order and dimmed. Mount changes restart the check and refresh cached system Places.

`StateDatabase` backs positions, folder settings, recent folders, sessions and file viewing history. Thumbnail
catalog data is owned by `ThumbnailStore`. `Settings` and config stores handle user configuration; panel/window
preferences also use UserDefaults. Check each store's flush/lifetime contract before changing persistence.

`AppDelegate` owns a shared `FramingLearningLibrary`, its private atomic reference/policy store and event-driven
foreground gate. Cache `.current` activity pauses the single app-wide fit; no timer polls at rest. Each viewer owns
`ViewerFramingLearning`; its learning window owns a coordinator. Close cancels work before its mutation commit cutoff;
an already-started atomic write finishes. Dataset revisions reject stale apply/undo, and tab policies stay transient.
`ViewerFramingLearning` also prepares a native optional object menu from fresh captured-image detections (one preparation
per viewer), checks source revision before and after detection, and stores source/intent-specific notes separately
from reference targets. It binds the viewer's plain right-click action when SmartZoom's saved **Object feedback on
right-click** option is enabled. The Zoom menu also exposes **Object Feedback under Pointer…**. A viewer-owned
one-step dataset checkpoint uses the exact post-edit revision to reject undo after any intervening mutation.
Object notes and comparison votes are collected explicitly and are not yet used by the fitter. Input actions expose
confirmations, object menu, comparison, undo and intent switching to the existing mouse/key binding system.
Manual viewing without an automatic origin captures Fit as the replay baseline. No historical crop is migrated.
Stored samples preserve source revision, detector mapping/thresholds, viewport, Auto/Pan input and Detail/Overview
intent. Changed sources must be recaptured, not restamped from newer pixels or silently treated as missing objects.

## Shared packages

HomeScreenKit supplies Home/browser, chrome, filmstrip and slots; InfoPanelKit supplies viewer panel UI;
SettingsKit supplies settings controls; StashKit supplies server/path/web integration. Logitech input in the app
comes through `MouseClient` from MouseService; LogiHIDPP supplies shared hardware types and lower-level support.
See [kit release workflow](kits.md); change kits on the app's branch name and consume released tags.

The Everything Home source uses the versioned `EverythingSearchUI` product of EverythingMac and
HomeScreenKit's page source. The app opens resolved file URLs through its normal window controller. Folder results
go to File View. The page owns its search session and suspends requests off-screen. The shared package saves the
latest search and library in the host app’s preferences. The sidebar shows Everything when Network Everything has
a saved connection. Back from an opened photo returns to the same search page.

Web Images also uses a retained Home page. Settings hold a SearXNG address and a destination folder. Loupe
remembers the last query and each server’s engine selection in preferences. `SearXNGClient` discovers image
engines and fetches results with optional original pixel dimensions. `WebImageSearch` appends unique originals
in server order and owns cancellation and page retry. The saved minimum resolution applies to each submitted
sequence using only the dimensions supplied by SearXNG. An unfiltered page determines whether pagination can
continue. Editing the query or engine selection discards the grid’s sequence. Changing the resolution starts a
new sequence for the submitted query. An open viewer keeps its original query, filter and order. Back and
double-clicking an image reuse the Home page and its scroll position. Thumbnail size and captions are saved
display options.

`WebImageViewer` supplies session-scoped URLs to the source-ordered playlist. At a page boundary it can resume
an advance while that result still has focus. `WebImageReader` resolves those URLs at the existing image-cache
boundary and delegates other URLs to `PhotosReader`. Thumbnail and original downloads use separate bounded
temporary stores. The grid, strip and viewer share decoded thumbnails kept with the cached files. The viewer
prepares the next and previous thumbnails after the selected thumbnail, one at a time, starting speculative
downloads only while the thumbnail network pool is idle. Navigation and hiding the viewer cancel that work.
The optional original prefetch starts after the current image is displayed and uses the same original store
and per-file limit as on-screen reads. The saved depth is one to three originals in each direction. The
viewer queues the nearest first. The saved concurrency defaults to one and is capped at three and one
quarter of physical cores, with a minimum of one. Background transfers start when the on-screen pool is idle
and use separate slots. The temporary store can retain up to seven files at maximum depth. The viewer adopts an in-flight prefetch of its newly
selected original. Lowering the depth discards work outside the new range. Disabling prefetch or leaving
the viewer cancels speculation. Loupe removes both temporary stores on quit. A failed original
can still show its thumbnail and offer the source-page action. Saving copies the original bytes via an exclusive
rename in the chosen folder. Web Images does not write file positions or Recent history. See the
[Web Images window measurements](bench/2026-11-18-web-images.md).

## Where to change and verify

| Change | Read first | Verification |
|---|---|---|
| Window/tab routing | `Sources/Loupe/WindowRegistry.swift` | `Tests/LoupeTests`, session/tab core tests |
| Navigation, zoom, spread | `Sources/Loupe/ViewerSession.swift`, `Sources/LoupeCore/ViewTransform.swift` | `Tests/LoupeCoreTests`, relevant viewer tests |
| SmartZoom composition/profiles | `CompositionOptions.swift`, `SmartComposition.swift`, `SubjectComposition+Protection.swift`, `DetectorProfileEditor.swift` | circle composition/protection/browsing and native editor tests |
| Reference learning and learned selection | `FramingReference.swift`, `FramingReferenceStore.swift`, `FramingCandidates.swift`, `FramingFitter.swift`, `ViewerFramingLearning.swift`, `FramingLearningCoordinator.swift` | `Framing*Tests`, real `--framing-learning-bench` window workload |
| Decode/cache scheduling | `Sources/LoupeCore/ImageCache.swift`, `Sources/LoupeCore/ThumbnailStore.swift` | cache tests and `docs/bench` |
| Browser inspector | `Sources/LoupeCore/BrowserInspectorLoader.swift`, `Sources/LoupeInspector` | `Tests/LoupeInspectorTests`, `LoupeBench inspector` |
| Mixed media and optional playback | `Sources/LoupeCore/PlaybackMedia.swift`, `Sources/Loupe/EmbeddedPlayback.swift` | `Tests/LoupeCoreTests/PlaybackMediaTests.swift`, signed app pair on local files and SMB |
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

`ZoomStopGesture` owns continuous stop state for right-button drag, pinch and thumb-wheel Pause.
In Adaptive mode the gesture tracks, holds at a stop or departs with that stop suppressed until clearance.
Signed raw input from capture drives breakaway (`zoom-stop-breakaway`, scale doublings), and only excess
travel moves the view after release. Early capture applies when entering the approach zone. Inside the zone,
fine adjustment stays free up to the exact stop. Raw-input speed narrows the approach zone and reduces the
breakaway threshold chosen at capture, down to full bypass with crossing feedback. Fixed mode holds in the approach direction until reversal or a new gesture.
Mouse inertia keeps the drag's mapping, lands on the first eligible stop it crosses and stays idle if the drag
releases on a stop. The minimum and maximum zoom remain limits, with the existing optional stretch.
`ViewerView` discards stop state on cancellation, when a different photo replaces the current one, or when
the window loses key status or changes fullscreen state.
Pinch and thumb-wheel end events discard their state. Right-button release can hand its state to mouse inertia.
See the [Soft Detents / Semantic Stops](../AGENTS.md#soft-detents--semantic-stops) interaction guidelines.
