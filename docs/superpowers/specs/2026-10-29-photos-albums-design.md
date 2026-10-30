# Apple Photos albums and viewing

Status: approved by the user; implemented. Local automated and synthetic-window checks passed. Real Photos/iCloud, Intel and release dependency validation remain outstanding (see the bench document).

## Intent and agreed scope

Make Apple Photos available inside Loupe. The initial request covered albums and photo paging; on 2026-10-30 the user also requested Library with all photos, including those outside albums.
Photos remain managed by Apple Photos; Loupe is a viewer. This document specifies the proposed implementation,
including defaults that the user has not individually selected.

## Approaches

The preceding discussion proposed a separate Photos source through PhotoKit, and the user confirmed albums and
paging as the scope. Use this approach: it provides album identity, image access and library change notifications
without depending on the private library layout. A system photo picker provides a selection flow rather than a
persistent album browser. Exporting complete albums into folders duplicates the library and delays opening. Neither
fits browsing albums in place.

## Proposed experience

- Add a Photos source to the existing Home sidebar. Opening it lists ordinary user albums and their containing
  folders. Opening an album lists its still images with original filenames and capture dates; name/date sorts are available in both directions. Empty albums have an empty state.
- Clicking a photo opens the existing Loupe viewer at that position. Existing photo paging controls move within
  this album and stop at its boundaries. Going back returns to the same album and grid position.
- Preserve stable album and asset identities across navigation. A title is display text, never an identity.
- Request Photos access on the first deliberate visit, never at launch. Show denial, restricted access, empty
  library and loading failures as actionable states. Respect the authorization scope returned by the system.
- Show the current edited appearance supplied by Photos by default. An image-only asset is a still; Live Photos
  contribute their still image. Video playback, shared-album discovery and smart-album discovery are deferred.
- Photos menus expose only supported viewing/navigation actions. Editing, deletion, album management, copying a
  private library path, and moving Photos assets through filesystem actions are outside this release.
- Normal Loupe zoom/pan/rendering remains available. Support the existing album grid and viewer filmstrip rather
  than building another viewer. Persistence of Photos tabs across app restarts is deferred; live tab routing and
  returning to the album must work.

## Existing architecture and required changes

`LoupeHomeSource` currently routes folder browsing to `FolderBrowserSource` and named sources to `CollectionSource`.
Add an app-owned Photos adapter and route Photos locations, pictures, actions and cancellation to it. Reuse the
HomeScreenKit browser UI; keep Photos-specific APIs and names out of general-purpose kit behavior. Check the
released kit's location/entry contracts during implementation. If a general API extension is required, follow
`docs/kits.md`: a matching kit branch, kit release first, then tagged dependency updates in Loupe.

`OpenTarget` currently represents files, folders and Stash galleries. Add an explicit Photos opening target carrying
album and asset identifiers. Matching an already-open album can focus its tab and select the requested asset.
Honor the existing explicit new-tab and new-window controls.

`ViewerSession`, `Playlist`, filesystem watchers and image-cache work currently depend on file URLs. Introduce a
source-aware album sequence whose ordering and membership come from PhotoKit. The Photos sequence must never
trigger folder scans, filesystem existence checks, filesystem folder stepping or filesystem writes for
Photos identifiers. Do not disguise an album as a directory or infer its contents from materialized files.

Keep stable source identity separate from the file used by the existing decoder. A PhotoKit content adapter
resolves only requested assets to the current image rendition, off the main thread. Where the existing rendering
pipeline needs a local file, use an app-owned bounded cache with atomic publication and active-file pinning.
File-backed current renditions can be copied into that cache; adjustment/rendered content must use an appropriate
PhotoKit rendition request rather than substituting an unedited original. The exact adapter/decoder seam is left
to the implementer after checking current decoder and metadata contracts. Every consumer of the current URL
(metadata, positions, recent items, saved sessions, Finder actions and rendering) must explicitly support Photos or
omit unsupported behavior. Temporary cache paths must not become saved album identities or Recent folders.

Use `PHCachingImageManager` for album covers, grid cells and filmstrip thumbnails. Cache keys include asset identity,
requested rendition/size and a revision token. A library change invalidates affected thumbnails/materialized
renditions; album reloads preserve the selected asset when possible. If it disappears, select the nearest remaining
item; an emptied/deleted album returns to its empty state or album browser. Leaving Photos unregisters unused
observers and cancels outstanding work. Main-actor updates are small and generation-checked.

## Permissions and packaging

Add a neutral `NSPhotoLibraryUsageDescription` to the application bundle. Use PhotoKit authorization for library
reading (`.readWrite` is the API access level; no mutations are performed). Verify the requirements of the actual
signed app and sandbox configuration, adding the Photos library entitlement where required. Test the packaged app,
not only the SwiftPM executable. Do not inspect Photos' private SQLite database or bundled directory layout.

## Responsiveness and resource use

- Fetch album/asset metadata off the main thread; publish bounded batches for large listings.
- Request thumbnails only for the visible area and a small near-visible range; cancel obsolete requests.
- Prioritize the current image. Limit prefetch to nearby assets already local; never download an entire iCloud album.
- Allow network access for the selected asset, show download progress where available, and allow navigation to
  cancel its request. Late progress/completion cannot replace the newly selected image.
- Bound pending requests, decoded memory and materialized-file disk use. Share requests for the same rendition
  across tabs and retain files while consumers use them. Choose and document limits from measurements, using
  physical-core-aware background scheduling and existing cache budgets where applicable.
- Pause background work for hidden windows/tabs and stop repeating work at rest. Main-thread budgets remain
  approximately 100 ms for navigation and 50 ms for controls; downloads do not block input.

## Verification and delivery criteria

Automated checks cover ordered album navigation, asset identity independent of materialized paths, tab matching,
stale request cancellation, authorization states, changes/deletion during viewing, and cache ownership/eviction.
Use an injectable Photos boundary so these checks need no personal photo library. Existing file/folder/archive
navigation and rendering checks must still pass.

Manually verify the signed app with an explicitly authorized test library: permission grant and denial, nested and
empty albums, an edited photo, a Live Photo still, an iCloud-only photo, offline failure, rapid paging, returning
to the grid, multiple windows and changes made in Photos. Never add personal assets or library identifiers to the
public repository.

Before handing over a build, bench the real Photos pages on an Intel Mac: main-thread CPU time for first and return
visits, opening an album and paging; several consecutive rounds, plus bounded memory/disk/request counts and idle
behavior. Record machine, data size, limits and measurements under `docs/benchmarks/`. If the machine or an iCloud
scenario is unavailable, report that validation gap explicitly instead of claiming it passed.

## Deferred capabilities

Mutations, export UI, original/edited version selection, RAW pair selection, Live Photo animation, video playback,
smart/shared album discovery, arbitrary library-file selection, cross-album paging and Photos session restoration.

## Implementation decisions

The existing reader injection accepts PhotoKit image bytes directly; there is no need for a materialized-file disk
cache. Stable source URLs identify an asset and rendition independently of encoded file data. The viewer uses an
explicitly ordered playlist matching the clicked grid’s name/date sort. Asset IDs remain authoritative when filenames repeat. Original names and extensions are metadata; the decoder detects the actual bytes supplied by PhotoKit.

Full-image prefetch is disabled for Photos: selection starts a fresh network-capable request, while thumbnails
remain local-only. Background thumbnail-driven auto-colour analysis and filesystem-only metadata are omitted
for Photos in this first release. Source-specific snapshots/Recent entries remain deferred as specified above.

The signing script includes a Photos library entitlement as well as the usage-description bundle key. The built
executable was verified in a disposable signed bundle without requesting access to a personal library. See
`docs/benchmarks/photos-albums.md` for measured costs, regression evidence and remaining validation.

## Library addition, 2026-10-30

Photos root includes a leading Library card, even when there are no user albums. Library is not repeated inside
album folders. Its source-owned collection ID is `@library`; it uses the same grid, thumbnails, viewer sequence,
return navigation and event observation as albums. Image assets are fetched directly from PhotoKit in ascending
creation-date order, within the existing authorization scope. This includes images not assigned to any album and
does not duplicate photos that belong to several albums. The view retains the existing still-image-only scope.

A synthetic regression check first reproduced the absent root card/title, then verified Library routing, photos
outside albums and opening such a photo through the existing viewer target. No personal library access is needed
for this check.

## Presentation and return corrections, 2026-10-30

The user requested name/date sorting, actual image names/extensions, and return to the same Photos view.
PhotoKit resource metadata supplies original names; there is no JPEG conversion in the reader. Dates are asset
creation dates. Sort choices are remembered per collection in the current process, shared as defaults across
windows; each displayed grid and each active viewer keeps its own order. A click snapshots that order before
asynchronous library work. All browser-return actions recognize source URLs and restore their collection and
selection instead of constructing a filesystem parent path. Reopening the same asset refreshes its sequence.

## Persistence correction

Sort key/direction are saved per collection in application preferences. The name cache now persists resource
descriptors in the user cache directory, validates fresh PhotoKit membership and revisions on each fetch, and
keeps the Library snapshot while visiting albums. Only descriptors are cached on disk, never image exports.
The new behavior supersedes the earlier process-memory-only choices and one-listing filename-cache limit.
