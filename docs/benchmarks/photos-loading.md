# Photos loading: request tracing and cancellation

2026-10-30; Apple Silicon, 14 physical cores, macOS 27.0.1. No Intel result.

The work was moved from `polish-3` to the managed `photos-loading` worktree, based on `main`,
transferring only Photos integration and tests. Unrelated inspector and toolbar changes were retained in
the source checkout. A private temporary backup and transfer manifest allow the same hunks to be returned later.

## Reproduction and profile

`PhotosReadBench` is an explicit, read-only diagnostic (`--photos-read-bench`) in a normally signed app.
It does not request permission or write images. Launch it as an app (LaunchServices), with stdout/stderr
redirected to a temporary local log. It prints only stage timings, aggregate counts, formats and error
domains/codes, never identifiers, filenames or pixels. The 60-second watchdog prevents an unattended hang.
The process uses the already-authorized Photos identity; terminal launch attribution may have no permission.

The baseline on approximately 9,500 real still-image records:

| Stage | Elapsed ms |
| --- | ---: |
| Fetch one recent image identity | 65 |
| PhotoKit HEIC bytes, first request | 2,643 |
| Same byte request, warm | 15 |
| HEIC header probe | 4–14 |
| Full collection metadata and resource filenames | 15,168 |
| Viewer repeats full collection preparation | 12,098 |
| Viewer pyramid ready from open | 12,228 |

A two-second `sample` during collection preparation shows nearly all samples under
`PHAssetResource.assetResources(for:)` and PhotoKit/CoreData resource construction/property fetches.
The original implementation repeated resource extraction for every image on grid listing and on open.
The successful direct read and viewer pyramid demonstrate that this measured case was delayed by metadata,
not by HEIC decoding. Failure of arbitrary other or cloud-only images was not established by this sample.

## Changes

- Reuse original resource names by asset ID and modification date from the last complete collection.
  Membership, dates, dimensions and revisions are still queried fresh. The cache retains one listing.
  Cover queries cannot evict it. Nothing is written to an export or metadata file cache.
- Library change details invalidate changed/removed entries; nonincremental changes clear the name cache.
- Cancellation is checked during enumeration and between resource lookups. It prevents further obsolete work
  and does not publish a partial filename snapshot. A single synchronous PhotoKit call remains uninterruptible.
- Selected-image identity lookup has a separate serial user-initiated queue. Bulk metadata and thumbnails
  retain utility QoS, so selected data no longer queues behind a discarded whole-library resource scan.
- Keep Photos identities out of filesystem metadata reads in the viewer inspector.

The cold first complete filename pass still has to read the resources. This change does not claim to eliminate
that cost or to validate arbitrary iCloud/offline behavior. No personal names, IDs, sample assets or configurations
are included in this repository.

## Regression coverage

`PhotosAssetNamesTests` checks unchanged reuse, revision refresh, explicit invalidation, bounded membership,
cancellation after two resource lookups and preserving the other 99 names when one resource changes.
Existing tests cover request cancellation, source routing, real encoded HEIC data, sort/order and source return.
Independent read-only review found no remaining important issues in the cache/cancellation/queue changes.

## Final real-library verification

In an active native window, after the one-time complete name pass, the diagnostic loads the Library grid,
selects the same HEIC asset used by the direct byte/probe check, invokes the browser’s normal Return handler,
and requires that asset identity plus a resident viewer pyramid. It returns to the grid, waits for relisting
and reopens it. An obsolete cold collection query on a second service instance is then cancelled before a
selected-image read. Each readiness/identity assertion must pass; unavailable foreground or failed reopening
is a diagnostic failure, not a success. Earlier diagnostic iterations without an active visible window could
legitimately suppress source reads; those are not counted as successful viewing checks.

| Stage after changes | Elapsed ms |
| --- | ---: |
| Cold complete filename pass | 10,755 |
| Warm Library grid listing/layout | 275 |
| Selected viewer playlist from normal grid opening | 482 |
| Same HEIC resident pyramid ready | 546 |
| Return and reopen | 430 |
| Cancellation of obsolete bulk query | 0.073 |
| Selected byte request after cancellation | 8.14 |

These are elapsed stage times, not main-thread CPU budgets or an Intel result. Cold filename extraction is
not eliminated. The diagnostic ended with PASS. Its temporary log remains outside the repository and is not
part of the change. The selected-image request remained network-capable; this run used warm local rendition
bytes and does not validate cloud-only download failure modes.

The final full default test wrapper passed: 12 app tests, 63 inspector tests and 2,202 core tests (six skips).
The five new filename-cache checks passed. Release compilation completed with build label
`Photos-Loading-Fix`; no application installation was performed. Work remains in the managed `photos-loading`
worktree for user verification before returning it to `polish-3`.

## Persistence correction, 2026-10-30

The user’s subsequent check showed that the collection still loaded slowly after restarting and sort was lost.
Both stores were process memory only. Keeping only the last collection also meant visiting a small album could
evict the full Library’s names.

The shared sort store now saves per-collection name/date key and direction in application preferences. Test
stores can use an isolated preference suite or memory-only mode. Names are persisted as a versioned descriptor
cache under the application’s user cache directory, outside the repository. Only IDs, revision dates and names
are stored, with no image bytes or exports. Reads/writes are lazy on the existing serial utility queue.
Membership, dimensions, dates and revisions are queried fresh from authorized PhotoKit before cached names
are reused. The snapshots retain one whole Library and one most recent album; covers do not replace them.
Invalidation persists immediately, writes are atomic, malformed/version-mismatched files fall back to PhotoKit,
and optional disk data above a conservative 64 MiB safety limit is ignored. Unchanged snapshots are not rewritten.

Four regressions cover reopening preference stores with both sort directions, reopening name caches and
refreshing changed revisions, persisting invalidations, corrupt cache fallback, and Library→album→new store→Library
without resource rereads. Full default tests passed: app 12, inspector 63, core 2,206 (six skips).

Signed-app restart verification passed with `--photos-read-bench --list-only` in two new processes.
Fresh PhotoKit membership and cached names for 9,493 records took 155.509 ms and 156.419 ms elapsed,
versus the prior 10,707 ms uncached pass. Both list-only runs ended PASS. These measure collection metadata,
not complete window display or main-thread CPU. The cache was populated by the initial authorized run.
`--sort-write` followed by `--sort-read` in separate signed processes also passed using an isolated preference
suite (name descending); the test suite is removed afterward without touching the user's actual sort choices.
The optional diagnostic-only preferences flush ensures the write is on disk before that test process exits;
normal application preferences use UserDefaults’ standard persistence.

Build `Photos-Persistent-Library` completed. Label, Photos usage description, entitlement and strict code
signature were verified. No installation or transfer back to `polish-3` was performed.

## Integration into polish-3

The user accepted the feature and requested landing into `polish-3`. Final independent review of the merge
composition found no important issues: source routing/cancellation, file-URL guards, native BackDestination,
Home background/selection and per-window toolbar isolation are preserved. Unrelated dirty inspector/toolbar
work in the main checkout is retained outside the Photos commit.

An existing eviction test imposed a fixed first-five retention cutoff even though the documented keep set
contains only the current image and its neighbour. Transient upload reservations may legitimately evict an
extra unplanned pyramid after the oldest session’s extras are gone. Independent review confirmed the
assertion was over-specified. It now checks the guaranteed keep set plus preferential retention of newer
extras; production eviction policy was not changed. The integrated parallel suite then passed.

The actual combined main checkout passed its full default wrapper: 25 app tests, 63 inspector tests, three
inspector integration tests and 2,229 core tests (seven skips). Validation uses the existing local edited
HomeScreenKit dependency, as `polish-3`'s already-committed inspector needs APIs not yet present in tag 0.11.8.
No edit-mode Package.resolved changes are part of the Photos commits. This lands development work into
`polish-3`; releasing/tagging the other kit work and release CI remain separate.
