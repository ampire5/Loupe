# Web Images Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task by task. Checkboxes track execution.

**Goal** — Add a Web Images source in Loupe Home that searches SearXNG, browses images in the viewer, and saves originals to a configured folder.

**Architecture** — Keep the SearXNG client and file operations in LoupeCore. Loupe owns the Home page and each viewer’s ordered search session. Supply Web Images identities to the existing viewer cache through a reader that delegates other URLs to PhotosReader and FileReader.

**Tech stack** — Swift 6, Foundation URLSession, AppKit, HomeScreenKit, SettingsKit, Swift Testing.

**Spec** — [Web Images source](../specs/2026-11-15-web-images-source-design.md)

## Global constraints

- Follow the repository’s architecture and responsiveness rules. Bound concurrent downloads, temporary storage, and decode work. Keep I/O off the main actor.
- Keep the current Everything work intact. Start execution from a baseline that contains the intended Home entry points and isolate the new changes.
- Use `http://127.0.0.1:8888` as the setup suggestion. Keep instance addresses and provider configuration editable by the user. Avoid new package dependencies.
- Use deterministic test responses for routine verification. Use a locally configured SearXNG only for the manual integration check.

## Review focus

- A base URL with a path must retain that path when constructing API requests. Explicit engines and category defaults must stay mutually exclusive.
- A delayed response must never replace results after editing the query or switching servers.
- Restoring a query and removed engines must avoid an implicit search or silently broadening the user's engine selection.
- A failed original download must leave preview and source-page navigation available, including after stepping from the previous result.
- Two concurrent saves of the same original must retain both copies and preserve byte contents.

## Task 1 — SearXNG client

**Files** — Create `Sources/LoupeCore/SearXNGClient.swift` and `Tests/LoupeCoreTests/SearXNGClientTests.swift`.

**Interface** — `SearXNGClient(baseURL: URL, session: URLSession)`; `imageEngines() async throws -> [SearXNGImageEngine]`; `searchImages(query: String, selection: WebImageEngineSelection, page: Int) async throws -> SearXNGImagePage`. Define `WebImageEngineSelection` with `.serverDefaults` and `.explicit([String])`. Each `WebImageResult` carries original URL, optional preview and source page URLs, title, and engine names.

- [ ] Test request URLs against a stub transport, including a base path, Unicode query, page 2, an exact two-engine filter, and no simultaneous category parameter. Test config discovery, disabled-by-default engines, JSON 403, missing originals, and invalid resource URL schemes.
- [ ] Run `scripts/test.sh --filter SearXNGClientTests` and confirm the new tests expose the missing client.
- [ ] Implement asynchronous requests and decoding. Use `/config` for engine discovery and `/search` with `format=json` for search. Preserve partial results when some engines fail and expose the returned engine errors. Report a JSON-format 403 separately from a transport failure.
- [ ] Re-run the focused tests and commit the client changes.

## Task 2 — Settings and Home search

**Files** — Create `Sources/LoupeCore/WebImagePreferences.swift`, `Sources/Loupe/WebImageSearchSession.swift`, `Sources/Loupe/WebImagesPage.swift`, and `Tests/LoupeTests/WebImagesSearchTests.swift`. Modify `Sources/Loupe/LoupeHomeSource.swift` and `Sources/LoupeSettings/Pages/PageInterface.swift` using the existing settings persistence and presentation paths.

**Interface** — `WebImagePreferences` stores `serverURL: URL?`, `saveFolder: URL?`, `lastQuery: String`, and an engine selection scoped to the server URL. `WebImageSearchSession.submit(query: String, selection: WebImageEngineSelection)` explicitly starts a new search. `loadNextPage() async` appends results to the current session and coalesces overlapping requests. `WebImagesPage.onOpenResult` passes the session and clicked result to the viewer.

- [ ] Test restored text and selection with zero network submissions, stale completion after a query or server change, partial engine failure, a removed saved engine, page retry, repeated-result pages, and grid scroll restoration.
- [ ] Run `scripts/test.sh --filter WebImagesSearchTests` and confirm the new cases are red.
- [ ] Add address, connection check, and save-folder controls. Connection check validates the endpoint and distinguishes disabled JSON search when it probes search. Add a Home row once a server is configured. Show the last query in the search box and submit on Return. Populate the engine picker from the configured server, with **Server defaults** available explicitly.
- [ ] Connect the Home page to the session. Request thumbnails as grid cells become visible. Append and deduplicate by original URL. Cancel replaced requests and ignore their completions. End automatic pagination after a page adds zero images. Keep loaded pages after a page failure and expose retry.
- [ ] Re-run focused tests, verify the Home row and settings in Loupe, and commit.

## Task 3 — Viewer navigation and original downloads

**Files** — Create `Sources/LoupeCore/WebImageReader.swift`, `Sources/Loupe/WebImageViewer.swift`, and `Tests/LoupeTests/WebImageViewerTests.swift`. Modify `Sources/Loupe/AppDelegate.swift`, `Sources/Loupe/ViewerSession.swift`, and `Sources/Loupe/ViewerWindowController.swift`.

**Interface** — `WebImageReader: FileReading` resolves session-scoped Web Images identities, with a fallback of `PhotosReader`. `WebImageViewer.open(_ result: WebImageResult, from search: WebImageSearchSession)` starts a viewer-owned sequence using the query and engine selection in force when the result was opened.

- [ ] Test next and previous across a page boundary, duplicate-page termination, cancelling a pending advance by moving backward, and a failed original after a forward step. Verify that a failed result remains navigable and retains the preview and source-page action.
- [ ] Run `scripts/test.sh --filter WebImageViewerTests` and confirm the missing viewer path makes the cases fail.
- [ ] Install the reader at the shared image-cache boundary. Download originals as needed, prioritizing the current image. Use a bounded temporary cache and remove incomplete files. Check the response and support cancellation. Use a source-ordered playlist and bypass local folder scans, file history, and broken-file auto-skip for Web Images.
- [ ] Near the end of the loaded sequence request the next page. A forward step at the boundary may resume once the new page arrives if the same result still has focus. Use the existing Home return path to preserve the grid and scroll. On download failure, keep the preview where present and offer the source page. Save becomes available only after a successful original load.
- [ ] Re-run the focused tests and verify that normal local and Photos viewer routing still passes. Commit the viewer path.

## Task 4 — Save originals and verify the complete workflow

**Files** — Create `Sources/LoupeCore/WebImageSave.swift` and `Tests/LoupeCoreTests/WebImageSaveTests.swift`. Modify `Sources/Loupe/WebImageViewer.swift` and `docs/architecture.md`.

**Interface** — `WebImageSave.save(original: URL, suggestedName: String?, to directory: URL) async throws -> URL`. The input is the fully downloaded local original and the return value is the file actually saved.

- [ ] Test byte equality, missing or inaccessible destination, a filename containing path components, and simultaneous saves of the same name. Verify that an error leaves no partial result.
- [ ] Run `scripts/test.sh --filter WebImageSaveTests` and confirm the cases are red.
- [ ] Wire Save to write directly to the selected folder. Preserve original bytes, sanitize the filename, and use a numeric suffix with an exclusive final write on collision. Report the saved file, or show the error and provide a way to open the folder setting.
- [ ] Document the code ownership and lifetime of search requests, viewer sequences, and cached downloads in the architecture map.
- [ ] Run `scripts/test.sh` and require a passing build and core suite. Run the spec’s acceptance scenarios in Loupe using the local instance. Verify source switching and first entry against the repo’s UI responsiveness guidelines. Commit the save behavior and architecture update.
