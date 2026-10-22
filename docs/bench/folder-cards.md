# Folder cards: cover and summary in one task

What: `LoupeBench thumbs --covers <folder>` — Home's cards of every subfolder of a folder through a `CoverQueue`
(two covers at a time, the default), the first 12 visible and the rest the margin, each card getting its folder's date
as the parent's listing gives it. Two passes: **made** (an empty catalog: each folder listed, four thumbnails made and
kept) and **catalog** (a fresh store on the same catalog: the next session). The column "first 12" is the time until
the 12 visible cards all have their cover and, after the change, their summary.

- Before: fab2c4b, `ThumbnailStore.folderCover` (a names-only listing, no summary).
- After: `ThumbnailStore.folderCard` (on a local volume the listing has each photo's date and size, one `fstatat` per
  photo in the same `readdir` pass; the summary is counted from it and goes to the catalog with the store's next batch).
  In the catalog pass a fresh summary and the four thumbnails make each card without a listing.

Machine: Intel iMac, 8-core i7 (16 threads), SSD, macOS 26; release build; other apps open (runs vary by about ±10 %).

Data, generated for the bench in a temporary directory on the internal SSD:

- **200**: 24 subfolders × 200 baseline JPEGs, 1600 × 1200, ~140 KB each, modification dates spread over a year.
- **2000**: 24 subfolders × 2000 entries (hard links to the same files): the listing's share of the work grows.

Three runs each, seconds (CPU: the process's CPU time for the pass).

| data | pass | before: first 12 | after: first 12 | before: all 24 | after: all 24 | before: CPU | after: CPU |
|---|---|---|---|---|---|---|---|
| 200 | made | 0.27 / 0.28 / 0.29 | 0.30 / 0.33 / 0.36 | 0.60–0.64 | 0.68–0.82 | 1.8–1.9 | 1.9–2.0 |
| 200 | catalog | 0.05 / 0.06 / 0.06 | 0.05 / 0.05 / 0.06 | 0.11–0.14 | 0.12–0.13 | 0.2 | 0.2 |
| 2000 | made | 0.54 / 0.56 / 0.60 | 0.67 / 0.68 / 0.74 | 1.16–1.26 | 1.42–1.55 | 2.9–3.0 | 3.4–3.6 |
| 2000 | catalog | 0.05 / 0.05 / 0.06 | 0.05 / 0.05 / 0.05 | 0.11–0.13 | 0.11–0.13 | 0.2 | 0.2 |

Reading:

- Folders of a few hundred photos: the summary costs nothing measurable; the cards' time is the thumbnails'.
- Folders of 2000 photos, first visit: about +0.1 s to the first 12 cards and +0.5 s of CPU for 48 000 entries,
  ~10 µs an entry, most of it the `fstatat` (a separate measurement of one 2000-file folder: names alone 2 ms, names
  and `fstatat` 13 ms, `contentsOfDirectory` with resource values 22 ms, so the listing uses the first two). It runs
  in the covers' utility threads, within the queue's two covers at a time; cores busy stay at ~2.4.
- The next session (the catalog pass) is as fast as before and now has the summaries too: no listing at all.
- An earlier version that counted the summary through `URL` parts (`lastPathComponent`, `pathExtension` per entry)
  cost 3.7 s of CPU on the 2000 set; counting by the listing's names brought it to 3.4–3.6.

## First launch after the update: thumbnails in the catalog, no summary yet

A third pass between the two (`no summaries`): the catalog of the made pass with its `folder_summaries` rows removed.
Each card's pictures come from the catalog at once; the folder is listed once for its summary (with dates on a local
volume), whatever that listing does to the pictures. Same machine and data, after the review fixes (the catalog's
pictures never wait on the summary listing's outcome; a share goes offline as a whole), three runs:

| data | pass | first 12 | all 24 | CPU |
|---|---|---|---|---|
| 200 | made | 0.28 / 0.29 / 0.30 | 0.61–0.71 | 1.8–2.0 |
| 200 | no summaries | 0.07 / 0.08 / 0.09 | 0.16–0.20 | 0.3 |
| 200 | catalog | 0.05 / 0.05 / 0.05 | 0.10–0.11 | 0.2 |
| 2000 | made | 0.66 / 0.66 / 0.66 | 1.34–1.38 | 3.3 |
| 2000 | no summaries | 0.30 / 0.30 / 0.31 | 0.61 | 1.2 |
| 2000 | catalog | 0.05 / 0.05 / 0.05 | 0.10–0.11 | 0.2 |

The first launch costs one listing per folder, once: 0.03–0.25 s more than a session with summaries for the first 12
cards, then the summaries are in the catalog and later sessions are the `catalog` row.

## Summary batches

`ThumbnailStore.summaryBatch` (64): summaries wait for the store's next batch (`commitDelay`, 1 s) and a full batch is
written at once. `ThumbnailDatabase.putSummaries` into a table of 10 000 rows, best of 10, same machine:

| rows | ms |
|---|---|
| 1 | 0.28 |
| 16 | 0.45 |
| 64 | 1.15 |
| 256 | 3.35 |

64 rows hold the store's actor about a millisecond; one row per transaction would cost a quarter of a millisecond each.
