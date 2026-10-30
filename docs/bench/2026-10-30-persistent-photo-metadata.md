# Persistent photo metadata

Measured 2026-10-30 on the local Apple M4 Max (14 physical cores, 36 GB), macOS 27.2, debug build, local temporary SSD catalog. Intel and NAS measurements are not available. This adds no UI controls or startup work; the existing native inspector's selection/materialization bench remains in `2026-10-30-progressive-inspector.md`.

The existing thumbnail catalog now retains complete successful `PhotoMetadata` results, plus a portable header, in `photo_metadata`. Fields include capture strings, GPS, software, description, generation text, workflow byte count, created/modified dates, bit depth, alpha, dimensions, type, profile name and orientation. Null optional values in a complete record mean absent. Reader version changes cause a cache miss. Source errors are never persisted. Runtime colour-space objects, decoded pixels, arbitrary dictionaries and full workflow JSON are not stored.

The browser inspector consumes a complete catalog hit before the source debounce and skips the source read entirely. The viewer info panel uses the same persistent store. Records are populated on demand, not by scanning the library. Size/mtime guard reads and conditional writes; replacement/removal through either catalog path removes metadata. A current-stamp hit is read-only. Disk-disabled mode retains no metadata database.

Storage policy: up to 256 KiB per encoded record, 16 MiB total payload and 2048 records, with FIFO eviction. These are maximum storage budgets, not allocations or worker parallelism. Oversized results remain usable in the inspector's existing bounded memory cache but are not persisted. Current PNG text reader already caps text at 64 KiB; raw workflow content is not included in this record.

`PhotoMetadataBudgetTests.catalogLookupBenchmarkWhenRequested`, `LOUPE_METADATA_BENCH=1`: 2048 records with roughly 4.4 KiB of generation text each; serial writes and reads. Independent cache regression tests ran alongside this bench, so the result is not an idle-machine minimum.

| Operation | Total | Per record |
|---|---:|---:|
| Establish file + encode + commit metadata + enforce limits, 2048 records | 682.54 ms | 0.333 ms |
| Primary-key lookup + decode, round 1 | 19.15 ms | 0.00935 ms |
| Primary-key lookup + decode, round 2 | 18.28 ms | 0.00893 ms |
| Primary-key lookup + decode, round 3 | 18.36 ms | 0.00897 ms |

No growing cost on repeated reads. Limits test writes 80 records of 230 KB and verifies total retained payload <=16 MiB and eviction of old entries. Unit coverage includes reopen, all serialized fields, empty results, transient errors, oversized records, stale writes, stamp changes through addFile/sync, deletion, corrupt payload, unknown reader version, two files in one folder, disk-disabled mode, and source avoidance on a complete catalog hit.

Validation: 136 tests in 8 suites passed (metadata, inspector, thumbnail database/store) using an external temporary Swift package pointing at the unchanged working source/test directories. The temporary package excludes executable/UI targets because the current separate toolbar change calls `Playlist.isSourceOrdered`, which does not exist in this checkout and blocks the app's normal test build. No production manifest/dependency pins were changed for this workaround. This validates core behavior, not a successful full application build.

The actual project target `LoupeInspector` also builds successfully with the repository dependency environment (`scripts/libjxl-env.sh`). Full executable validation remains blocked by the separate toolbar reference described above.

Final integration update: Photos integration supplied Playlist.isSourceOrdered and removed the earlier executable build blocker. The standard repository test script now passes (2243 tests in its core pass, 7 skips), including the persistent metadata and encoding checks. The temporary package was needed only for the earlier isolated validation.

Final standard test-script rerun after the catalog-reset fix: 2244 tests passed, 7 skipped.
