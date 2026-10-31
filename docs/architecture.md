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

## Threads, cancellation and persistence

`ViewerSession` and AppKit coordination run on the main actor. `ImageCache`, `ThumbnailStore` and
`PhotoMetadataCache` isolate shared state in actors. `FileReader` and `DecodePool` bound I/O/decoding. Thumbnail
activity follows foreground cache work; keep the existing foreground/background priority relationship.
`RenderLoop` passes locked snapshots to its own thread, pauses the display link at rest and stops it on close.
Metadata stat work is utility work; synchronous filesystem reads do not belong in a main-actor callback.
Navigation uses cancellation plus request identity checks because a cancelled filesystem/decode call may finish.

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
| Decode/cache scheduling | `Sources/LoupeCore/ImageCache.swift`, `Sources/LoupeCore/ThumbnailStore.swift` | cache tests and `docs/bench` |
| Browser inspector | `Sources/LoupeCore/BrowserInspectorLoader.swift`, `Sources/LoupeInspector` | `Tests/LoupeInspectorTests`, `LoupeBench inspector` |
| Viewer metadata | `Sources/Loupe/ViewerMetadataLoader.swift` | `Tests/LoupeTests/ViewerMetadataLoaderTests.swift` |
| Rendering | `Sources/Loupe/RenderLoop.swift`, `Sources/LoupeRender` | serial render pass in `scripts/test.sh` |

Use `scripts/test.sh` for everyday tests and `scripts/test.sh full` before merging renderer/transform changes;
see [testing policy](testing.md). Run `python3 scripts/kits-check.py --no-fetch` after local dependency work.
UI performance requires real-window CPU measurements; a model-only microbench cannot establish window latency.
