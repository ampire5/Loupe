# Progressive inspector data

User request: retain a stable inspector, show already catalogued/card facts immediately, mark missing section data as requested, and replace values as reads finish.

Use existing FileFacts (dimensions, capture settings, header facts) synchronously from the selected entry. If those are not attached yet, one bounded catalog stage queries ThumbnailStore before any source read. Retain the latest-only worker bound and stale-reply checks. Metadata cache hits publish immediately, without a placeholder round trip. Preview can arrive from the thumbnail cache before source metadata.

Keep primary rows and four local-file sections present across pending/completed states; use section-local status text. Reuse controls, skip identical row updates, preserve scroll on selection changes. Missing completed values use a dash or a section's no-information state, never the previous file's values.

- [x] Add regressions for catalog facts before completion, section stability, immediate cache hits and catalog-before-source staging.
- [x] Implement progressive content/loader and catalog/thumbnail connection.
- [x] Verify native view identity/values, full tests and real-window timings; report catalog coverage accurately.

Independent user follow-up delegated through dispatching-parallel-agents: filter photo/video table columns and update/install FrameScrub locally on polish-3. Main inspector changes do not edit kit table files.


## Execution ledger

- Existing catalog coverage verified in schema, FileFacts and card delivery; no schema/indexing added. Source-only metadata remains asynchronous.
- Core/card/seed/cache regressions RED→GREEN. Scoped review found partial facts could suppress the seed; fieldwise filling now preserves newer card values while adding missing catalog fields. A catalogue-race regression failed before the fix and passed afterward.
- Native blocked-reader regression confirms the same four section controls remain present, new card values show synchronously, stale replies never replace them, and section request text disappears on completion.
- Controlled native timings recorded in docs/bench/2026-10-30-progressive-inspector.md; first open 104.399 ms, selection medians 8.598–9.382 ms. No Intel claim.
- Full native/settings/presentation suites passed; full parallel core run has an intermittent evictsOldestInactiveFirst failure. Isolated rerun and full nonparallel ImageCacheSessions plus inspector suites passed (47 tests). No unrelated cache logic was changed to mask that failure.
- Delegated photo/video column filtering completed in HomeScreenKit, with 683 kit tests passing. FrameScrub on polish-3 uses the local kit edit dependency; full suite 1741 pass, 20 skipped, table bench passes; installed app signature and binary checked. Original FrameScrub Package.resolved preserved.
- Loupe also built and installed from local polish-3, with compilation limited to four jobs. This is a local development installation, not a kit release/pin update. Other working-copy changes preserved; no commit/push/merge.
