# Architecture maps and inspector metadata ownership

## Intent
Make routine changes navigable without reconstructing the whole repository. Document the current code in Loupe,
FrameScrub, HomeScreenKit, SettingsKit, InfoPanelKit, StashKit and LogiHIDPP. Keep historical feature designs separate
from the current architecture map. The user requested implementation of architecture maps followed by one small,
verified refactor.

## Approach
A current `docs/architecture.md` per repository describes targets, state ownership, important event/data flows,
concurrency, cancellation, persistence, change entry points and verification. README and agent instructions link to
it. Maps refer to source files, not fragile line numbers, and must change alongside architectural changes.

Alternatives considered: an exhaustive class catalogue duplicates the code and ages quickly; a broad controller
rewrite increases risk before the boundaries have been documented. Use concise maps and one focused extraction.

## Refactor
Extract viewer inspector metadata state and task lifetime from `ViewerWindowController` into an internal
`@MainActor ViewerMetadataLoader` in Loupe. It owns selected URL, stat size, result, pending indicator, read task and
slow-read task. Inject async stat and metadata readers and the delay for deterministic tests. The controller retains
panel layout, hold policy, diagnostics and presentation. Production reader keeps the existing thumbnail catalog,
process-wide PhotoMetadataCache, utility stat I/O and one-second pending delay. Stop on panel close; never publish
results belonging to a cancelled selection, including A→B→A. Non-file URLs do not start file reads.

## Constraints and verification
No UI redesign, new background concurrency, new dependency or kit API change. Existing app/kit tags remain pinned.
Work on `architecture-map` branches; do not publish or merge. Preserve local instruction files. Check map links
against files, run kits-check, focused loader tests and the Loupe test suite. The extraction adds no UI controls or
screen construction; inspect the existing inspector benchmark before using its numbers: it measures the browser, not viewer metadata. Intel hardware is not
available in this session: no claim of Intel validation. Public documentation uses neutral examples only.
