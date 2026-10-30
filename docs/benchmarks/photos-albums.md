# Photos albums: verification and responsiveness

Date: 2026-10-29. Host: Apple Silicon (`arm64`), 14 physical cores, macOS 27.0.1.
The host cannot substitute for the required real Intel Mac check.

## Real Home window, synthetic library

Command: `LOUPE_PHOTOS_UI_BENCH=1 scripts/test.sh --filter realBrowserRoundTripsAlbumsWithoutLosingOrder`.
Full metrics are printed in `.build/test.log` as `PHOTOS_UI` lines.

This opens the actual Home window and browser with an injected library: one album containing 10,000 still-image
records. No personal library is read and no Photos permission is requested. Each move waits for its listing and
300 ms of settling, then lays the window out. CPU time is `CLOCK_THREAD_CPUTIME_ID` on the main thread, including
main-thread work during settling, rather than elapsed download time. Thumbnail pixel content is absent in the
fixture; this measures navigation, listing and grid layout, not PhotoKit decoding or iCloud.

| Round | Albums page CPU ms | Album, 10,000 photos CPU ms |
| --- | ---: | ---: |
| 1, first visits | 65.277 | 20.237 |
| 2, return | 8.315 | 14.865 |
| 3, return | 14.052 | 21.531 |
| 4, return | 13.086 | 17.427 |

All measured navigation actions fit the approximately 100 ms main-thread budget on this host; repeated rounds
do not show steadily increasing costs. Permission UI and real-image requests are not part of these numbers.

## Data-only sequence costs

Command: `. scripts/libjxl-env.sh && swift run -c release --triple "$DEPS_TRIPLE" LoupeBench photos --files 10000 --rounds 5`.
This deliberately has no UI or PhotoKit access. Preparing 10,000 numbered entries and stable source URLs took
36.271 ms CPU; that preparation runs off the main thread in the app.

| Round | Ordered playlist CPU ms | 10,000 steps CPU ms | Grid ordering CPU ms |
| --- | ---: | ---: | ---: |
| 1 | 3.738 | 0.018 | 5.536 |
| 2 | 3.329 | 0.019 | 3.918 |
| 3 | 3.361 | 0.018 | 4.057 |
| 4 | 3.359 | 0.018 | 3.690 |
| 5 | 3.746 | 0.018 | 3.912 |

## Lifecycle regression checks

The independent review's four findings were reproduced before fixes:

- `movingFromAlbumsToAnAlbumDoesNotCancelTheNewListing`: destination list yielded zero entries instead of two.
- `libraryChangesFollowTheSecondAlbumOpenedInTheSameViewer`: changes in the second album never reached its viewer.
- `sourceImagesAreReadOnlyWhenSelectedSoPromotionCannotReuseALocalOnlyRequest`: an unselected asset was read once.
- `leavingPhotosViewerCancelsItsCurrentRead`: Home left the selected source read active.

Fixes preserve the destination subscription, rebind the album observer, start full-image reads only on selection,
and deactivate the Photos viewer's cache activity while Home or a hidden tab is shown. The source read's moving
priority cancels the PhotoKit request when it ceases to be current; returning to the viewer allows a new request.
The request bridge also covers cancellation before registration, duplicate callbacks and cancellation after success.

## Automated and packaging verification

The final full project wrapper passed with 2,206 tests and five skips, including the permission-denial and
interrupted-open checks. The optional UI bench is normally skipped and was run separately. `git diff --check`, both property lists and the signing script's shell syntax
were checked. A disposable bundle containing the actual built executable and Info.plist passed strict ad-hoc
signature verification with the Photos entitlement present; it was not installed or launched against a library.

Apple documents the usage-description key and Photos entitlement in
[Saving captured photos](https://developer.apple.com/documentation/avfoundation/saving-captured-photos).
Both normal and ad-hoc branches of `scripts/make-app.sh` now include `Resources/Loupe.entitlements`.

## Resource policy and remaining validation

Metadata queries run on one utility queue. At most one full-image PhotoKit request and one thumbnail request are
active. Full-image prefetch is disabled for Photos, avoiding local-only requests that cannot be promoted in place
to download an iCloud asset. Only a selected image may use the network. Thumbnail initiation uses the utility queue;
browser thumbnail work is serial and filmstrip requests are restricted to visible cells. Each PhotoKit request lane
has a bounded wait list of 128 tickets; cancellation removes queued requests. This is a conservative first-release
safety bound, not a throughput-tuned value. Real-image request/memory profiling is still required before tuning it.

There is no exported-file disk cache. Existing renderer/cache budgets bound resident image data. Photos assets
do not enter the filesystem thumbnail catalog, folder watcher, Recent store or saved file-tab snapshots. No polling
timer is added. Library observers are event-driven; hidden viewers defer refresh work.

Still required before calling a distributable build validated:

- Signed application: permission grant/denial and Photos privacy settings, including revocation while viewing.
- Real library: ordinary/nested/empty/deleted albums, edited image, Live Photo still, large image and rapid paging.
- iCloud: cloud-only selected image, progress, navigation/Home/tab cancellation and offline retry.
- Real Intel Mac: the actual Home pages and viewer, first/return visits over repeated rounds, CPU, memory, in-flight
  request counts and idle behavior; repeat with real thumbnail pixels.
- Kit release/pin check once concurrent kit development has returned the checkout to released dependencies.

Personal assets and library IDs must remain outside the repository. The automated UI and lifecycle checks use
only generic synthetic records.

## Library addition, 2026-10-30

The Photos root now includes a leading Library collection. It fetches image assets directly from PhotoKit,
chronologically, rather than collecting the contents of albums. A synthetic check verifies that Library is present
with no user albums, includes an unfiled image, has the correct title, and opens that image through the existing
viewer target. This check failed for the missing card/title before the implementation and passed afterward.
Independent review of the Library delta found no important issues.

The targeted run with `LOUPE_PHOTOS_UI_BENCH=1` passed: seven app-level Photos checks (including the real Home window)
and 33 core/router checks. The wrapper reports the last test-runner summary, so these counts are recorded separately.
The root now has Library plus the fixture album. On the same 14-core arm64/macOS 27.0.1 host, main-thread CPU ms:

| Round | Photos root with Library | Album, 10,000 photos |
| --- | ---: | ---: |
| 1 | 56.686 | 17.948 |
| 2 | 9.734 | 12.548 |
| 3 | 8.248 | 13.300 |
| 4 | 8.992 | 12.885 |

The full project run also reported an unrelated failure in the concurrently developed toolbar:
`ViewerToolbarStatusTests.narrowLayoutKeepsCaptureProfileAndGroupInsideTheSurface` (controls overflow narrow widths).
No toolbar code was changed for the Library addition. The dependency check still reports HomeScreenKit without a pin
while it is in edit mode. Real PhotoKit membership/permission checks and Intel measurements remain outstanding.

Development snapshot: `scripts/make-app.sh --label Photos-Library` completed and produced `build/Loupe.app`.
The label, Photos usage description, Photos entitlement and strict code signature were verified with access to
this machine's certificate trust store. The app was neither installed nor launched by this task. This is a
working-branch test build, including concurrent changes; it is not a release-validation claim. The toolbar test,
kit pin, real-library/iCloud and Intel validation gaps above still apply.

## Names, sorting and Photos return, 2026-10-30

User reports were traced to disabled sort keys, numbered display names plus a fabricated `.jpg` URI suffix,
and BrowseTarget constructing a filesystem parent for every URL. The reader did not transcode images.
Regression tests now cover original HEIC/PNG names (including duplicates), name/date sorts, selected identity
after sorting, same-asset sequence refresh, and browseFolder/goBack/showHome returning to the same source and
selection. The byte test encodes a real 64×64 HEIC through ImageIO, passes it through PhotosReader unchanged,
and probes it with the normal HEIC decoder. This does not substitute for a real PhotoKit library test.

Per-collection sorts are saved in application preferences (updated by the persistence correction in `photos-loading.md`). Each browser retains its displayed choice; opening a photo
captures it synchronously so another window’s later sort change cannot alter the pending open or observer refresh.
Resource filename extraction is on the existing serial utility metadata queue; its cost on a real library remains
unmeasured. Source names describe the original resource; a current edited rendition may have a different encoded
format, which is still detected from the bytes.

The full test run also exposed shared NSToolbar identifiers synchronizing Home/viewer item mutations across windows.
The window host now has a unique identifier per instance, while retaining the same toolbar for its lifetime.
The two-window regression checks that changing one window leaves the other’s items unchanged. The benchmark’s
standalone NSWindow now disables release-on-close because ARC owns it, preventing a test-harness over-release.

Actual ViewerWindowController, injected 10,000 named records, last photo selected; command:
`LOUPE_PHOTOS_UI_BENCH=1 scripts/test.sh --filter realViewerReturnsToPhotosLibraryWithTenThousandNamedImages --no-parallel`.
Same 14-physical-core arm64/macOS 27.0.1 host, main-thread CPU including 300 ms settling and layout:

| Round | Open viewer CPU ms | Return to Library CPU ms |
| --- | ---: | ---: |
| 1, first | 72.793 | 67.082 |
| 2 | 59.034 | 81.484 |
| 3 | 61.940 | 84.465 |
| 4 | 68.146 | 64.874 |

All fit the ~100 ms navigation budget here, with no steadily increasing rounds. The grid-only run with original
filenames measured Photos root 55.816/20.181/22.257/16.816 ms and the 10,000-photo grid
21.565/17.718/18.593/20.479 ms. As above, fixtures contain no real thumbnail pixels and do not exercise PhotoKit
permission, iCloud, metadata extraction or Intel performance.

Final default wrapper with both UI benches enabled passed: 22 app tests, 63 inspector tests and
2,211 core tests (five skips). Log: `/tmp/loupe-photos-final-raw.log`. In that full run viewer open CPU was
71.242/64.278/60.785/60.203 ms and return CPU 66.572/68.428/88.717/68.208 ms.
Independent review found no remaining important issues in the names/sort/return delta and toolbar isolation fix.
`git diff --check` and property-list validation passed. The kit check still fails because HomeScreenKit has
no Package.resolved pin during concurrent edit-mode development. This remains a development snapshot,
with real PhotoKit/iCloud and Intel checks outstanding.

Updated development snapshot: `scripts/make-app.sh --label Photos-Names-Sort` completed.
`build/Loupe.app` was verified for that label, the Photos usage description, Photos library entitlement and
strict deep code signature using the host trust store. It was not installed or launched by this task.
