# Progressive inspector updates

## Catalog coverage

The thumbnail catalog stores file size and modification time, image dimensions/UTI/progressive/profile/orientation, and serialized FileFacts: camera, lens, exposure, aperture, ISO, focal length, exposure bias and capture date. The source already sends these facts to cards through ThumbnailStore.facts/headerFacts and HomeBrowserView.setFacts. The initial inspector consumed only dimensions and listing facts, so it hid usable capture/header values while reading the source.

The catalog does not currently persist the complete PhotoMetadata payload: GPS, description/software, generation text/workflow information, creation date, bit depth and alpha still need the source reader. No new schema or background indexing is introduced.

## Update sequence

1. A changed explicit selection immediately publishes that card's known facts in the appropriate groups. Unknown primary values show Requesting; the four local-file sections stay present with section-local request status.
2. One bounded worker asks ThumbnailStore for cached EXIF, header and 160 px preview before source I/O. Fields merge individually, preserving newer nonnil card values. Partial/header-only facts never suppress richer catalog data. A card update during lookup fills remaining fields instead of dropping the seed.
3. Source reads retain the 120 ms debounce, utility priority and latest-only/stale-token rules. Full metadata supplements known values. A successful in-memory metadata cache hit publishes synchronously, avoiding an empty/loading frame on returning to that file.
4. The panel retains its native controls, skips identical row-group updates and does not reset its scroll position on each selection. Per-section status has reserved height so changing its text does not move the whole panel. Missing completed sections say No information in file; source failure retains available catalog facts with an error.

Catalog/thumbnail stages and source work remain one worker per inspector plus one replaceable pending selection. A hidden/obsolete stage cannot publish for another selection. Preview lookup uses stored thumbnails, not another source decode. No timer or polling is added.

## Verification

Regressions cover immediate capture/profile/format from the card, stable section/primary-row identities across pending/failure, immediate metadata cache reuse, catalog publication while source reading is blocked, partial-card/seed arrival races, and preservation of newer camera values alongside catalog lens/profile values. A controlled native test changes files during a blocked source read: new card values appear immediately, old values disappear, request text remains local to the section, and all four disclosure controls keep their identity after completion.

The partial-seed regression failed with missing Lens/Profile before fieldwise merging and passed after the fix. An independent review identified that gap; the remaining lifecycle findings were clear. One unrelated ImageCacheSessionsTests.evictsOldestInactiveFirst failure occurred during a parallel full run; its isolated rerun and following full run passed. Final verification follows the last merge change.

## Native timing

Existing real-window InspectorBench, M4 Max / 36 GB, macOS 27.2 debug; 1000 synthetic entries, three rounds, CLOCK_THREAD_CPUTIME_ID. This measures populated native UI and reuse, not NAS or SQLite throughput. First open 104.399 ms (registration 0.050, materialization 20.635, layout/display 36.352, later run-loop work 47.362).

| Round | Selection median ms | Selection max ms | Reopen median ms | Reopen max ms |
| --- | ---: | ---: | ---: | ---: |
| 1 | 9.183 | 16.218 | 16.604 | 18.288 |
| 2 | 9.382 | 11.042 | 17.525 | 18.601 |
| 3 | 8.598 | 9.646 | 19.725 | 21.078 |

The first-use budget remains approximate on this Apple Silicon machine; Intel is not measured. The progressive transition itself is covered by the blocked-reader native test, not inferred from the immediate synthetic reader used by the benchmark.

## Media columns and local installation

HomeScreenKit FileStyle now declares semantic photo/video media capability. The table picker and effective saved/rendered columns are filtered together. Loupe does not offer duration/codec/fps/bitrate/HDR-video columns; FrameScrub does not offer camera/EXIF/photo-reading columns. Generic names, dimensions, sizes and folder metadata remain available. Renaming the file noun does not change the capabilities.

FrameScrub and HomeScreenKit are on local polish-3 branches. The kit is consumed in SwiftPM edit mode; tracked release pins remain unchanged. FrameScrub installed in the user's Applications folder; binary digest and strict signature checked. Its complete suite passed 1741 tests (20 skipped); the complete kit suite passed 683 tests. These are local development builds, not published kit releases or a tagged dependency update.

Final verification: the native inspector presentation suite passed 3 tests, including the blocked-reader identity/value test; the selected inspector plus full ImageCacheSessions suites passed 47 tests without parallelization. The full parallel core run reached 2214 tests with one intermittent evictsOldestInactiveFirst failure; isolated and nonparallel session-suite reruns passed. Native integration (25) and settings (63) passed. Full FrameScrub and HomeScreenKit verification is recorded above. Loupe and FrameScrub local polish-3 app bundles were installed, with installed/build executable digests matched and strict codesign verification passed. No commit, push, tag or merge in this follow-up.
