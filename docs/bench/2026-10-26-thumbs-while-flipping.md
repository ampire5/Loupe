# Thumbnails and covers while the user steps through photos

Before, the thumbnail generator started new reads only once the viewer cache had been idle for 100 ms, and Home's
covers waited for it too (spikes/rust/REPORT.md §3.3): stepping through photos keeps the neighbours reading almost all
the time, so the strip and the folder cards waited for a pause. Now only the current photo's work (`.current`) stops
them, as it did; while only neighbours read (`.neighbours`) the generator goes on with one read in flight
(`ThumbnailStore.neighbourReads`, against `readLimit` 2 when idle) and covers go on; the 100 ms count from the end of
the current photo's work.

What: scratchpad `thumbs-bench.py`: a photo opened with an empty thumbnail cache (`LOUPE_CACHE_DIR`, debug), 5 s,
40 flips right every 0.5 s, 10 s still; thumbnails made (`thumb …: read` lines) before, during and after the flips;
each flip's photo from `navigate` to its preview and to `full on screen`. M4 Max, release builds; `L$/…/Pics_URAA_HQ/AI`
(200 JPEG XL of 14000 px, PC share). Runs alternated.

| Build | Thumbnails during the flips | after (10 s) | Preview p50 | Sharp p50 / p90 |
|---|---|---|---|---|
| before, 3 runs | 110*, 10, 9 | 0, 35, 44 | 5–6 ms | 240–245 / 255–267 ms |
| after, 3 runs | 34, 36, 47 | 0, 0, 0 | 5–6 ms | 241–252 / 263–274 ms |

\* that run counted 30 flips of 40 (the first ones went before the window took the keys): fewer neighbour reads.

The flips' own times do not change (the thumbnail reads take `FileReader`'s background threads, beyond the viewer's
two); thumbnails made during the flips go from about 10 to about 40, and the folder is done by the end of them instead
of needing the pause after. One read and not two: the viewer's neighbours and the thumbnails share the one share, and
one read is what the measurement shows to leave the sharp times as they were. Not measured: a NAS over Wi-Fi (where
the share is the limit), Intel, Home's covers on their own.
