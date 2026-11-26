# Photo cache memory on Apple silicon

Measured on a MacBook Pro with M4 Max, 36 GiB and macOS 27.2.1. For the photo pyramid's private 528 × 528 BGRA
texture array, `MTLTexture.allocatedSize` and `heapTextureSizeAndAlign` both reported 1,327,104 bytes per slice
at array lengths 1, 4, 16 and 64. The geometry estimate was 1,115,136 bytes per slice. Metal allocated 19.0% more. The pre-upload estimate now uses the device's
size query. Resident bytes come from the textures themselves and exclude their sampling views.

A live release process had 9.36 GiB of physical footprint and an 11.04 GiB peak. The OS attributed 6.87 GiB to
owned unmapped graphics memory and 1.06 GiB to IOSurface. Sizes matching integer multiples of the measured
texture slice accounted for 6.13 GiB of the owned unmapped graphics allocation. The snapshot cannot identify
which cache entries or viewers owned those regions.

## Navigation replay

`LoupeBench replay --screen 6144x3456 --limit 32 --script backfast|pingpong --conf <config> <folder>` on two real
photo folders. Debug builds from the same source revision with and without Metal accounting. The two configs
copied the same photo-cache and JXL settings, differing only in `cache-memory`. Each row is a single timed run.
Peak process footprint and peak Metal allocation measure different views of the same process memory.

| Workload | Limit | Accounting | Peak footprint (MiB) | Peak Metal (MiB) | Sharp before next step | Sharp on arrival |
|---|---:|---|---:|---:|---:|---:|
| JPEG XL, 15 forward and 14 back at 100% | 4 GiB | Nominal | 7077 | 5189 | 5/29 | 5/29 |
| JPEG XL, same sequence | 4 GiB | Metal | 6359 | 4358 | 4/29 | 3/29 |
| JPEG XL, same sequence | 2 GiB | Metal | 4060 | 2397 | 1/29 | 0/29 |
| JPEG, 20 alternating steps at 100% | 4 GiB | Metal | 3770 | 3580 | 20/20 | 20/20 |
| JPEG, same sequence | 2 GiB | Metal | 2616 | 2267 | 20/20 | 20/20 |

Both JPEG runs had a 1 ms median to sharp. The JPEG XL timing percentile uses only steps that showed a sharp
image, so the success and hit counts are the comparisons here. The 2 GiB JPEG XL run reduced peak footprint
by 2299 MiB, with fewer steps served from cache. The JPEG run reduced peak footprint by 1154 MiB with the
same hit count for this two-photo pattern. The replay exercises navigation and uploads with a simulated viewer.

## Return to a tab

A separate debug probe replayed the cache lifecycle of four tabs in the JPEG XL folder at 100% zoom. It warmed
the tabs at offsets 0, 8, 16 and 24, then made eight returns in reverse and forward order. It measured from a
cache activation to the presence of level 0 at a 5 ms polling interval. The runs shared a process and used
the order 4, 2, 2, 4 GiB. This measures cache availability and reload time through the real decoder and
Metal uploader. AppKit tab choreography and presentation time are outside the probe.

| Limit | Sharp on activation, runs 1 and 2 | Median to sharp (ms), runs 1 and 2 | Sampled peak footprint (MiB), runs 1 and 2 |
|---|---|---|---|
| 4 GiB | 8/8, 8/8 | 7.0, 6.6 | 5420, 5582 |
| 2 GiB | 2/8, 2/8 | 1711.0, 1973.5 | 3604, 3427 |

The probe held a reference to each tab's last pyramid, then hid the tabs and forced the cache budget to zero.
All four runs released every borrowed texture. After unregistering the sessions and settling for three seconds,
the cache held zero bytes and process footprint was 816–838 MiB. The footprint also covers other allocations
in the Swift test host. The regression test detects the old behavior by keeping a reference to an evicted
pyramid and checking whether any of its levels are still resident.

On these workloads, 2 GiB was sufficient for the JPEG pair. The large JPEG XL workflow benefited from 4 GiB,
especially on tab returns.
