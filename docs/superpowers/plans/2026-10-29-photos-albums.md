# Photos Albums Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Browse Apple Photos albums and page through their still images in Loupe.

**Architecture:** An app-owned Photos Home adapter uses PhotoKit through a core service. Stable `loupe-photos` URLs identify assets independently of the filesystem; an ordered playlist bypasses folder enumeration. A source-aware `FileReading` adapter supplies current PhotoKit image bytes directly to the existing image cache, avoiding a second disk cache.

**Tech Stack:** Swift, AppKit, PhotoKit, existing HomeScreenKit and Metal renderer; macOS 26.

**Spec:** `docs/superpowers/specs/2026-10-29-photos-albums-design.md`

## Global Constraints

- Photos is viewing-only: albums, nested folders and still images; no mutations.
- Read current edited renditions. Network access is allowed only for selected viewer assets.
- No filesystem scans, writes, Recent entries or persisted temporary paths for Photos assets.
- Bounded work off the main thread; obsolete requests cancel; hidden views stop thumbnail work.
- Use released kit APIs. No dependency changes planned.
- Do not include personal photo assets or identifiers in the repository.

## Review Focus

- Album order must survive filenames, duplicate names and identifiers containing slashes.
- A cancelled request must finish its continuation exactly once even when cancellation precedes request registration.
- Returning from the viewer must retain the album and selected image.
- Photos identities must not reach filesystem actions, saved sessions or directory watchers.
- A change/deletion in Photos must invalidate old images and safely update selection.

### Task 1: Stable identities and ordered playlists

**Files:** create `Sources/LoupeCore/PhotosLocation.swift`, `Tests/LoupeCoreTests/PhotosLocationTests.swift`; modify `Sources/LoupeCore/Playlist.swift`, `OpenRouter.swift`; extend router tests.

**Interfaces:** `PhotosLocation.assetURL(album:asset:revision:)`, `PhotosLocation.asset(in:)`, `PhotosLocation.album(in:)`; `Playlist(ordered:current:)` preserves authoritative order; `OpenTarget.photos(album:asset:)` routes by album identity.

- [x] Write tests for identifier round trips, revision changes, ordered navigation and boundaries, replacement after deletion, router same/different album and forced tabs.
- [x] Run `scripts/test.sh --filter 'PhotosLocationTests|OpenRouterTests'`; verify missing APIs fail.
- [x] Implement identity encoding, ordered playlist state and explicit Photos routing, preserving existing folder behavior.
- [x] Run the targeted tests and record the result.

### Task 2: PhotoKit service and cancellable image reading

**Files:** create `Sources/LoupeCore/PhotosLibrary.swift`, `PhotosImageRequest.swift`, `PhotosReader.swift`, and request/reader tests.

**Interfaces:** `PhotosLibrary.shared` supplies authorization, child collections, album assets, thumbnail requests and change events; `PhotosReader: FileReading` delegates ordinary URLs and reads Photos bytes with current rendition options. `PhotosImageRequest<Value>` owns exactly-once continuation and request cancellation.

- [x] Write/run failing cancellation race and reader delegation tests using an injectable source boundary.
- [x] Implement a serial utility PhotoKit metadata queue, bounded image requests, selected-image-only network access, off-main async request bridging and revision stamps.
- [x] Run targeted tests; verify SDK compilation.

### Task 3: Albums in Home

**Files:** create `Sources/Loupe/PhotosBrowserSource.swift`; modify `LoupeHomeSource.swift`, `ViewerWindowController.swift`, `Resources/Info.plist`, `AppDelegate.swift`.

**Interfaces:** `PhotosBrowserSource` supplies source listings/info/thumbnails/open actions; `onOpen: (OpenTarget, HomeClick) -> Void`. Source locations encode collection IDs. Existing Home source methods dispatch by Photos prefix.

- [x] Add tests of pure collection/asset entry construction and authorization error presentation at the core boundary.
- [x] Add Photos sidebar source, nested collections, image grid, empty/permission errors and visible-range thumbnails.
- [x] Superseded by the 2026-10-30 user correction: use original resource names and capture dates, expose name/date sorts, and preserve the clicked grid’s order in the viewer.
- [x] Add bundle usage description and source reader injection. Build the app.

### Task 4: Viewer integration and lifecycle

**Files:** modify `ViewerSession.swift`, `ViewerWindowController.swift`, `AppDelegate.swift`, and filmstrip/info adapters as required by their existing contracts.

**Interfaces:** `ViewerSession.openPhotos(_ files:[URL], current:URL)` opens an ordered source sequence. Controller owns current Photos album/asset and reload generation.

- [x] Add tests proving Photos playlists do not sort/relist as folders and selected assets survive revised URLs/deletions.
- [x] Open PhotoKit sequences in the existing viewer and route focus/new-tab/new-window correctly.
- [x] Guard folder watcher, folder stepping, saved view/Recent/session persistence and Finder/copy actions; deliver filmstrip thumbnails through PhotoKit.
- [x] Preserve browser return state, cancel obsolete opens, refresh on Photos changes and pause hidden work.
- [x] Build and run targeted tests.

### Task 5: Verification and documentation

**Files:** create `docs/benchmarks/photos-albums.md`; update spec status and this checklist.

- [x] Run the project test/build wrapper, `python3 scripts/kits-check.py` and `git diff --check`; inspect all failures (results below).
- [x] Verify packaged bundle description/signing requirements and run available synthetic resource/lifecycle measurements.
- [x] Record unavailable Intel, authorization, real Photos and iCloud checks explicitly; do not claim user-library validation without authorization.
- [x] Request one independent whole-change code review, fix important findings, rerun relevant checks and report the actual delivery state.

## Execution ledger

- User approved the design with “go”. Execute inline without another approval round.
- Existing branch: `codex/release-0.2.1`; user work consists of untracked `AGENTS.md`. Keep that file untouched.
- Ruling: use the existing reader injection to supply image bytes directly, so no materialized-file cache is necessary; this avoids disk ownership and eviction risks.
- Updated ruling (2026-10-30): preserve the chosen name/date order through metadata-bearing cards and an explicitly ordered viewer playlist, using existing kit APIs.

- Tasks 1–4: implemented and verified with the project wrapper. Bare SwiftPM commands lack Loupe's patched JPEG XL environment; use `scripts/test.sh` or source `scripts/libjxl-env.sh`.
- Ruling: full-image Photos prefetch is disabled. PhotoKit cannot promote an already-running local-only request into an iCloud download, so a full-image request starts only when its asset is selected. Thumbnail prefetch remains local-only. Cost: fewer prefetched full images; avoids displaying a false offline/unavailable error on selection.
- Ruling: unsupported filesystem metadata and thumbnail-driven auto-colour analysis are omitted for Photos in this first release. Zoom, pan and the renderer remain shared. Cost: Photos does not yet have all file-source metadata/analysis features.
- The working checkout acquired concurrent inspector/cache/folder changes during execution. They and their staged hunks were preserved. No commits, dependency restoration or branch renames were performed.
- Independent whole-change review found four important lifecycle defects. Regression checks reproduced each before fixes; Photos-to-Photos subscription order, rebinding observers, selected-only full-image reads and Home/hidden-view read cancellation were corrected. An additional interrupted-open check caught losing the explicitly selected asset on resume and was corrected.
- Targeted Photos/router checks passed. Full project checks passed (see final verification count in `docs/benchmarks/photos-albums.md`). The optional real-window synthetic UI bench also passed: four rounds, 10,000 records, main-thread CPU within 100 ms on this Apple Silicon host.
- Bundle verification: a disposable copy of the built executable plus Info.plist was ad-hoc signed with `Resources/Loupe.entitlements`; strict signature validation and assertions for the Photos entitlement/usage description passed. No application installation or library authorization occurred.
- `git diff --check`, Info.plist/entitlement validation and `bash -n scripts/make-app.sh` passed.
- Release validation remains open: `scripts/kits-check.py` reports a missing HomeScreenKit pin while concurrent kit work is in edit mode. Do not restore or commit that shared dependency state from this task. Real Photos/iCloud permission/rendering and Intel measurements are also outstanding; details are in the bench document.

- 2026-10-30 user addition: include the main Library, not only albums. Added a leading source-owned `@library`
  collection and a direct image-asset PhotoKit fetch sorted by creation date; existing viewer routing is reused.
  Regression check failed before the change and passed afterward. Targeted run: seven app Photos checks and
  33 core/router checks passed, including the 10,000-record real-window bench. Independent delta review clean.
  Full run has one unrelated toolbar layout test failure; kit pin and real-library/Intel gaps remain documented.

Development snapshot: `scripts/make-app.sh --label Photos-Library` completed and produced `build/Loupe.app`.
The label, Photos usage description, Photos entitlement and strict code signature were verified with access to
this machine's certificate trust store. The app was neither installed nor launched by this task. This is a
working-branch test build, including concurrent changes; it is not a release-validation claim. The toolbar test,
kit pin, real-library/iCloud and Intel validation gaps above still apply.

## User-reported presentation fixes, 2026-10-30

- [x] Reproduce Photos-to-filesystem return bug; make BrowseTarget recognize Photos source and selection.
- [x] Replace numbered names and fake .jpg extension with original resource metadata; test real HEIC bytes.
- [x] Expose name/date ascending/descending and share a collection default with viewer/new-tab opening.
- [x] Keep each clicked grid’s order when another window changes its choice during metadata fetching.
- [x] Refresh the playlist when routing to an already-open matching asset.
- [x] Complete UI benchmark and project tests; development snapshot packaging is recorded in the bench document. Kit release validation, real PhotoKit/iCloud and Intel checks remain outstanding.
