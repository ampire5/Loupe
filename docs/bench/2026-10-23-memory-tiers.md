# Memory tiers on a discrete card

What: `LoupeBench replay --script 100,backfast --screen 5120x2880 <folder>` with the defaults (no `--conf`), twice on
each side. Both scripts browse at 100 % (level 0 needed):

- **100-steps**: from the first photo (2 s on it), 30 steps → at 1.5 s, then 10 ← at 1.5 s (the folder has 20
  photos, so 29 steps are taken and 11 moves go nowhere).
- **back-fast**: 15 steps → at 1.5 s, then 14 ← at 0.6 s, faster than a 147 MP decode and upload.

Sides:

- **Before**: the spec state of the branch (pan-lts before the hardware defaults), one budget: `cache-memory` 4 GiB
  for files and pyramids together.
- **After**: the hardware defaults with two tiers. Graphics tier (pyramids) = half the card's Metal working set,
  4.29 GB (4088 MiB); system tier (`cache-memory`, compressed files and ready decodes) = a fifth of the memory,
  13.69 GB (13 056 MiB). Ready decodes one at a time at `.utility` on two threads.

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
| 100-steps | after | 1 | 29 | 0 | 1 / 1 / 783 | – | 144.5 | 12.56 | 6.58 |
| 100-steps | after | 2 | 29 | 0 | 1 / 2 / 1126 | – | 148.2 | 12.61 | 6.58 |
| back-fast | before | 1 | 19 | 10 | 1 / 628 / 729 | 4 of 14, 1 / 628 | 166.0 | 1.73 | 6.65 |
| back-fast | before | 2 | 18 | 11 | 1 / 593 / 803 | 3 of 14, 1 / 593 | 162.2 | 1.69 | 6.65 |
| back-fast | after | 1 | 29 | 0 | 1 / 230 / 245 | 14 of 14, 198 / 245 | 136.6 | 12.55 | 6.58 |
| back-fast | after | 2 | 29 | 0 | 1 / 241 / 1255 | 14 of 14, 172 / 244 | 137.0 | 12.55 | 6.65 |

After, from `CacheStats`: graphics tier peak 3867–3911 MiB of 4088; system tier peak 11 391 MiB of 13 056; 20 ready
decodes held at the peak (every photo of the folder).

Reading:

- **A step back is an upload.** back-fast: 29 of 29 sharp against 18–19; the 14 back steps 172–198 ms p50 and
  244–245 ms max to sharp (the upload of a ready decode), against 10–11 of 14 not sharp before the next step.
- **Graphics memory as before.** The card peaks at 6.58–6.65 GB on both sides: the graphics tier (4.29 GB) plus
  what is on screen and being uploaded, below the ~7.6 GB where panning starts to stall (spec, «Замер потолка
  карты»).
- **Less CPU.** 100-steps 144–148 s against 154–161, back-fast 137 s against 162–166: a step back no longer decodes
  the file again.
- **System memory is what buys it**: 12.6 GB peak against 1.5–1.7 (`cache-memory`, a fifth of 64 GB, holds every
  photo of this folder ready).
- **100-steps: more steps instant, one step slower.** 28 of 29 steps were already sharp when reached (22–26 before),
  p90 1–2 ms against 35–206. The exception is the first step after opening: its photo's ready decode had started in
  the background during the open (two threads, `.utility`, 2.4–2.8 s for 147 MP), and the full job for it waits for
  that decode rather than decode the file a second time (trace `readyAwait`, ~1 ms after the step). That step took
  783 and 1126 ms to sharp against 725 and 578 before; in back-fast run 2 the same first step took 1255 ms (729 and
  803 before). The other full jobs that awaited a ready decode (back-fast run 2, steps 3 and 4) did it while the photo
  was still a neighbour, 1.3–1.4 s before the step, and their steps were instant.
- A first run of "after" had the bench's defaults without the graphics tier (`CacheLimits()` instead of the app's
  `CacheLimits(config:)`): one 13.7 GB budget for everything put 19.5 GB (18 594 MiB) on the card and made forward steps 0.36–0.54 s p50, up to 1.25 s.
  The replay now takes its defaults the way the app does.
