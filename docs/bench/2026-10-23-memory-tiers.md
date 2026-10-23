# Memory tiers on a discrete card

What: `LoupeBench replay --script 100,backfast --screen 5120x2880 <folder>` with the defaults (no `--conf`), twice on
each side. Both scripts browse at 100 % (level 0 needed):

- **100-steps**: from the first photo (2 s on it), 30 steps → at 1.5 s, then 10 ← at 1.5 s (the folder has 20
  photos, so 29 steps are taken and 11 moves go nowhere).
- **back-fast**: 15 steps → at 1.5 s, then 14 ← at 0.6 s, faster than a 147 MP decode and upload.

Sides:

- **Before**: the spec state of the branch (pan-lts before the hardware defaults), one budget: `cache-memory` 4 GiB
  for files and pyramids together.
- **After, waiting (93a5644)**: the hardware defaults with two tiers. Graphics tier (pyramids) = half the card's
  Metal working set, 4.29 GB (4088 MiB); system tier (`cache-memory`, compressed files and ready decodes) = a fifth
  of the memory, 13.69 GB (13 056 MiB). Ready decodes one at a time at `.utility` on two threads; a full job that
  finds the photo's ready decode in progress waits for it.
- **After, overtake** (introduced in ca004df, measured at 6cc6a34, which also gives up a ready job still queued): the
  same, but the photo on screen waits for its ready decode only when that is expected to end no later than a decode
  of its own (running ms/MP figures), else decodes at once; a ready job still queued is given up. Four runs: the
  first had a step not sharp in time, so two more were made.
- **After, waiting (d581405)**: the overtake removed, the photo on screen waits for its ready decode again; a ready
  job still queued (not decoding yet) is still given up. Two runs.

Machine: iMac, Intel i7-10700K (8 cores, 16 threads), AMD Radeon Pro 5500 XT 8 GB (Metal working set 8.57 GB),
64 GB memory, 5K screen, macOS 26; release build; other apps open, the machine ~86 % idle before each run.

Data: five 147 MP JPEG XL (transcoded JPEG) linked twenty times, local SSD.

Columns: sharp = steps whose photo was sharp for the zoom before the next step, of 29; sharp p50 / p90 / max = ms
from the step to sharp over the steps that made it; back steps = the 14 ← steps of back-fast; CPU = the process's
CPU time for the script; RAM = peak `phys_footprint`, GPU = peak `MTLDevice.currentAllocatedSize` (sampled every
33 ms, the same measure on both sides); GB are decimal.

| script | side | run | sharp | not shown | sharp p50 / p90 / max | back steps sharp, p50 / max | CPU s | RAM peak GB | GPU peak GB |
|---|---|---|---:|---:|---|---|---:|---:|---:|
| 100-steps | before | 1 | 29 | 0 | 1 / 206 / 725 | – | 160.5 | 1.57 | 6.65 |
| 100-steps | before | 2 | 29 | 0 | 1 / 35 / 578 | – | 153.6 | 1.53 | 6.65 |
| 100-steps | waiting (93a5644) | 1 | 29 | 0 | 1 / 1 / 783 | – | 144.5 | 12.56 | 6.58 |
| 100-steps | waiting (93a5644) | 2 | 29 | 0 | 1 / 2 / 1126 | – | 148.2 | 12.61 | 6.58 |
| back-fast | before | 1 | 19 | 10 | 1 / 628 / 729 | 4 of 14, 1 / 628 | 166.0 | 1.73 | 6.65 |
| back-fast | before | 2 | 18 | 11 | 1 / 593 / 803 | 3 of 14, 1 / 593 | 162.2 | 1.69 | 6.65 |
| back-fast | waiting (93a5644) | 1 | 29 | 0 | 1 / 230 / 245 | 14 of 14, 198 / 245 | 136.6 | 12.55 | 6.58 |
| back-fast | waiting (93a5644) | 2 | 29 | 0 | 1 / 241 / 1255 | 14 of 14, 172 / 244 | 137.0 | 12.55 | 6.65 |
| 100-steps | overtake | 1 | 28 | 1 | 1 / 2 / 278 | – | 151.9 | 12.56 | 6.58 |
| 100-steps | overtake | 2 | 29 | 0 | 1 / 1 / 567 | – | 139.5 | 12.56 | 6.52 |
| 100-steps | overtake | 3 | 29 | 0 | 1 / 2 / 796 | – | 149.5 | 12.60 | 6.97 |
| 100-steps | overtake | 4 | 29 | 0 | 1 / 1 / 747 | – | 144.9 | 12.54 | 6.58 |
| back-fast | overtake | 1 | 29 | 0 | 1 / 230 / 785 | 14 of 14, 166 / 230 | 144.0 | 12.63 | 6.52 |
| back-fast | overtake | 2 | 29 | 0 | 1 / 222 / 292 | 14 of 14, 181 / 292 | 133.3 | 12.55 | 6.52 |
| back-fast | overtake | 3 | 29 | 0 | 1 / 261 / 787 | 14 of 14, 195 / 260 | 148.7 | 12.55 | 6.58 |
| back-fast | overtake | 4 | 29 | 0 | 1 / 252 / 278 | 14 of 14, 174 / 278 | 142.1 | 12.55 | 6.58 |
| 100-steps | waiting (d581405) | 1 | 29 | 0 | 1 / 1 / 2 | – | 147.2 | 12.56 | 6.58 |
| 100-steps | waiting (d581405) | 2 | 29 | 0 | 1 / 1 / 1 | – | 143.9 | 15.32 | 6.58 |
| back-fast | waiting (d581405) | 1 | 29 | 0 | 1 / 221 / 237 | 14 of 14, 186 / 237 | 135.8 | 12.55 | 6.58 |
| back-fast | waiting (d581405) | 2 | 29 | 0 | 1 / 206 / 309 | 14 of 14, 184 / 309 | 135.0 | 12.55 | 6.58 |

The first step after opening (its photo's ready decode began during the 2 s open), ms to sharp, and what its full
job did with that decode:

| side | 100-steps | back-fast |
|---|---|---|
| before | 725, 578 | 729, 803 |
| waiting (93a5644) | 783, 1126 (waited, both) | 1, 1255 (–, waited) |
| overtake | not sharp in 1.5 s (overtook), 567 (waited), 796 (overtook), 747 (waited) | 785 (overtook), 1 (–), 787 (overtook), 2 (–) |
| waiting (d581405) | 1, 1 (–, both) | 1, 1 (–, both) |

After (every version), from `CacheStats`: graphics tier peak 3849–3911 MiB of 4088; system tier peak 11 391 MiB of
13 056; 20 ready decodes held at the peak (every photo of the folder).

In flight, beyond that: the system tier bounds what the cache holds, not the decodes being made. Up to four full
decodes run at once (three on the decode pool, one ready decode), each ~0.6 GB of output at 147 MP plus libjxl's own
buffers, so the process can stand ~2.5–3 GB above the tier for a moment (`ImageCache.readyPool`). That accounts for
the one 15.3 GB RAM peak against the cache's 11 391 MiB (100-steps, d581405 run 2).

Reading:

- **A step back is an upload.** back-fast: 29 of 29 sharp against 18–19; the 14 back steps 172–198 ms p50 and
  244–245 ms max to sharp (the upload of a ready decode), against 10–11 of 14 not sharp before the next step.
- **Graphics memory as before.** The card peaks at 6.52–6.65 GB on both sides, 6.58 GB in all four final runs
  (d581405): the graphics tier (4.29 GB) plus what is on screen and being uploaded, below the ~7.6 GB where panning
  starts to stall (spec, the measurement of the card's ceiling); one overtake run peaked at 6.97 GB.
- **Less CPU.** Final runs (d581405): 100-steps 144–147 s against 154–161, back-fast 135–136 s against 162–166: a
  step back no longer decodes the file again (93a5644: 144–148 s and 137 s).
- **System memory is what buys it**: 12.6 GB peak against 1.5–1.7 (`cache-memory`, a fifth of 64 GB, holds every
  photo of this folder ready). One final run peaked at 15.3 GB: transient, from the decodes in flight (above), not
  from what the cache holds.
- **100-steps at 93a5644: more steps instant, one step slower** (superseded by d581405, below: no step waits there,
  and the first step is instant). 28 of 29 steps were already sharp when reached (22–26 before),
  p90 1–2 ms against 35–206. The exception is the first step after opening: its photo's ready decode had started in
  the background during the open (two threads, `.utility`, 2.4–2.8 s for 147 MP), and the full job for it waits for
  that decode rather than decode the file a second time (trace `readyAwait`, ~1 ms after the step). That step took
  783 and 1126 ms to sharp against 725 and 578 before; in back-fast run 2 the same first step took 1255 ms (729 and
  803 before). The other full jobs that awaited a ready decode (back-fast run 2, steps 3 and 4) did it while the photo
  was still a neighbour, 1.3–1.4 s before the step, and their steps were instant.
- **The overtake does not win that step back.** An overtaking decode at the current role runs beside the ready
  decode it overtook (which cannot be stopped mid-decode) and the neighbours' work: the step took 785–796 ms to
  sharp, and in one run of four the photo was not sharp before the next step 1.5 s later (its full level landed at
  the end of the step). When the expected times said wait, it waited: 567 and 747 ms. Before the tiers: 578–803 ms.
  Elsewhere the overtake version matches the waiting one: back-fast 29 of 29, back steps 166–195 ms p50 and
  230–292 ms max, CPU 133–152 s.
- **The overtake was removed** (user decision on these numbers): the photo on screen waits for its ready decode
  again, as in «After, waiting»; a ready job still queued is given up. Its rows stay as the measurement behind it.
- **Waiting again (d581405): no step waited.** In both runs of both scripts no full job met a ready decode in
  progress (no `readyAwait`): the ready job of the photo after the first was still queued when its full job came and
  was given up, so that photo was decoded during the open and the first step was already sharp (1 ms; 29 of 29 hits
  in 100-steps). 100-steps max 1–2 ms against 578–725 before the tiers; back-fast 29 of 29, back steps 184–186 ms
  p50 and 237–309 ms max; CPU 144–147 s and 135–136 s. The 309 ms is one sample in two runs (the overtake runs
  reached 292 ms), the noise level rather than a change against the prototype's ~260 ms. One RAM peak of 15.3 GB
  (100-steps run 2, transient, from the decodes in flight; 12.6 GB otherwise), the GPU 6.58 GB in all four.
- A first run of "after" had the bench's defaults without the graphics tier (`CacheLimits()` instead of the app's
  `CacheLimits(config:)`): one 13.7 GB budget for everything put 19.5 GB (18 594 MiB) on the card and made forward
  steps 0.36–0.54 s p50, up to 1.25 s. The replay now takes its defaults the way the app does, and `CacheLimits()`
  itself now carries the Mac's graphics tier.
