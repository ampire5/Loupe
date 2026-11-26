# Sessions and viewer metadata

Measured November 26, 2026 on a Mac16,6 with an M4 Max, 14 physical cores and macOS 27.2.1.

## Session commands

The temporary database had 200 named sessions, one previous-run session and a deferred current-run snapshot.
Every snapshot had 80 tabs. A native AppKit window queued an independent button action 20 ms into each operation.
The baseline repeated the synchronous database path, including the pending write and catalog decode.
The patch used `SessionStore.last()` and the Save Session As name-conflict path. These timings stop at the
database result. They exclude constructing restored viewers and displaying sheets.

Each cell gives the first round and the median of the next three. Main-thread CPU for the patch measures
submitting the task. The database result arrives on a later turn.

| Operation and measurement | Synchronous (ms) | Asynchronous (ms) |
|---|---:|---:|
| Previous run, wall time | 28.169 / 28.282 | 0.373 / 0.347 |
| Previous run, main CPU | 28.044 / 28.247 | 0.007 / 0.003 |
| Previous run, input lateness | 21.674 / 8.306 | 0.305 / 0.365 |
| Save As name conflict, wall time | 29.737 / 28.759 | 0.158 / 0.107 |
| Save As name conflict, main CPU | 29.697 / 28.706 | 0.005 / 0.004 |
| Save As name conflict, input lateness | 9.779 / 8.800 | 0.761 / 0.686 |

The baseline decoded 201 snapshots in either command. Reading the previous run now decodes one snapshot.
A name conflict reads only the ID and revision. `SessionStoreTests` checks that both reading the previous run
and listing Sessions leave the pending write alone, that an outdated confirmation requires another prompt, and
that reopening the database reads the saved snapshot. A separate write/read probe also verified the same temporary
database across two processes. `SessionWindowTests` reproduces the rename/delete race with two AppKit viewer
windows and verifies the alert and the refreshed lists. Intel timings remain unmeasured.

## Viewer metadata

Two viewer loaders held either stat or EXIF, then processed five paired selections before releasing the gate.
Start counts measure actual calls into the blocking reader. The latest-result interval starts at gate release
and ends when both viewers have metadata. It was observed with 1 ms polling.

| Held operation | Peak calls before / after | Intermediate starts before / after | Latest results before / after (ms) |
|---|---:|---:|---:|
| Stat | 13 / 3 | 8 / 0 | 2.09 / 2.14 |
| EXIF | 12 / 2 | 8 / 0 | 2.06 / 2.09 |

A follow-up used two real viewer windows with their Info panels open and six photo selections per window.
Stat reached three running calls while filling the pool, and EXIF reached two. After the pool filled, only the two
final selections started. In this single run both panels received their final metadata after 2.4 ms for stat
and 37.1 ms for EXIF, including time for AppKit and other viewer work on the main actor.

The cap sweep ran both viewers over 20 stock JPEGs, about 20 MiB, on APFS and on a mounted SMB volume.
Times cover stat and ImageIO. Each cell gives the first run and median of 20 repeats. One stat slot was reserved.

| EXIF slots | APFS (ms) | SMB (ms) |
|---|---:|---:|
| 1 | 0.275 / 0.189 | 82.735 / 52.504 |
| 2 | 0.106 / 0.097 | 27.403 / 26.495 |
| 3 | 0.101 / 0.093 | 26.741 / 26.175 |
| 4 | 0.519 / 0.090 | 25.799 / 26.193 |

Two EXIF slots handle both viewers in parallel, with about 0.3 ms further median improvement from extra slots on
SMB. The setting is capped by half the physical cores. `ViewerMetadataLoaderTests` also checks that closing one
viewer leaves the other viewer's shared read intact. `PhotoMetadataStoreTests` holds the pool full while a cold
catalog lookup is cancelled and checks that the filesystem resolver never starts.
