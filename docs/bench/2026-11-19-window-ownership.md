# Window ownership on Apple Silicon

The October window and network measurements used release builds on an M4 Max MacBook Pro with 36 GiB
of RAM and macOS 27.0.1. The November close replay used the same CPU and memory class on macOS 27.2.1.
The current Loupe instance was open during the November run, so the interactive measurements below
come from the October reports.

## Restore and switching

| Change | Scenario | Before | After |
|---|---|---|---|
| Avoid another directory listing on return if no event could have been missed | Five windows, six returns from Finder on Ethernet SMB | 30 listings | 5 listings |
| Restore one window per main-loop turn | Five windows, Ethernet SMB and Wi-Fi NAS, windowed and full screen | 261–300 ms longest main-thread turn | 74–111 ms. Full-screen restore completed 0.6–1.1 s later |
| Protect the current photo and its neighbours in inactive windows | Five full-screen windows with 147 MP JPEG XL photos on Ethernet SMB, 4 GiB cache | 9.2–9.4 GB evicted from inactive windows, 0/6 returns had a resident preview | 5.7–6.6 GB evicted, 8/12 returns had a resident preview. About 2 GB kept for inactive windows |
| Finish reads already past halfway | Same full-screen scenario, after keep sets | 5.7–6.6 GB evicted, 8/12 resident previews on return | 5.2–5.5 GB evicted, 6/6 resident previews. Four file rereads per run, counted across the whole run |
| Release cache entries and textures on window close | Three windows on Ethernet SMB, close two after settling | 6.23 GB before close, 5.87 GB at 0.5 s | 6.06 GB before close, 3.12 GB at 0.5 s. The remaining window refilled its cache to 3.68 GB at 5 s |
| Restore the last front window and separate visibility from activation | Five full-screen windows on Ethernet SMB | Wrong window visible on return, 4 activations during restore | Correct window visible, 1 activation in each of 3 runs |

The first two rows use the measurements around `40a6cd9` from [restore and rereads](2026-10-25-restore-and-rereads.md).
The keep-set, read and close rows use builds around `739e883`, `f766e3d` and `50db527` from [keep sets](2026-10-26-keep-sets.md).
The front-window comparison covers `50db527` through `e4ed221` and is recorded in the restore report.

After keep sets and half-read completion, the full-screen Apple Event probe was **56–58 ms p95, 96–129 ms max**.
These are round trips and include AppKit and automation overhead. They are a separate measurement from the
main-thread CPU time per restore turn. The logs show eviction from inactive windows with the tested budget
and include navigation during restore, so the reported cumulative rereads cannot establish a zero-reread rate
specifically for returns. The controlled `ImageCacheSessionsTests` cover keep-set residency and rereads after
eviction. The historical runs do not give a comparable `session opened` to first full image interval.

Keep the 50% share. It retained about 2 GB for inactive windows in the measured workload and improved preview
residency on return. The Ethernet share rarely caught reads halfway, so the data leave the 0.5 threshold at its
starting value. Confirm that threshold on a Wi-Fi NAS when the original slow-read workload is available.

## Close replay

Release `LoupeBench` built on `7831f10` with the close replay. It used six local synthetic
12,000 × 9,000 baseline JPEGs, the default cache, a 6144 × 3456 virtual screen and 100% zoom. Each cycle
registers a new cache session, opens the first image for 2 s, advances five times at 500 ms intervals, drops
the shown image and unregisters. It samples process footprint 0.5 s and 3 s after the cache goes idle,
then records Metal allocation and the cache's resident bytes. It exercises real reads, decodes and uploads
through the shared cache. The October runs contain no equivalent 20-cycle baseline for comparison.

The first 20-cycle run sampled at 0.5 s only. Footprint ranged from 9.4 to 884.8 MiB, while the
cache held zero bytes and Metal returned to 0.5 MiB at every sample. That run failed the plateau
check. The follow-up sampled twice after each close and again found short-lived footprint spikes.

| Follow-up sample | Process footprint | Metal allocation | Resident cache |
|---|---:|---:|---:|
| Before the first open | 6.5 MiB | 0.5 MiB | 0 |
| 0.5 s after idle, all 20 cycles | 8.4–145.7 MiB | | |
| 3 s after idle, all 20 cycles | 8.2–9.3 MiB | 0.5 MiB | 0 |
| 3 s after idle, last 10 cycles | 9.2–9.3 MiB | 0.5 MiB | 0 |

The settled footprint passed the ±5% plateau check with **0.88%** maximum deviation from the mean
over the last ten cycles. The warmed process settled about 2.8 MiB above its cold footprint. This establishes
a plateau with an empty cache and Metal at its initial allocation. The origin of the early process footprint
spikes was not isolated.

## Reproduce

From the repository root, build the release bench with the normal decoder dependencies.

```sh
source scripts/libjxl-env.sh
swift build -c release --product LoupeBench --triple "$DEPS_TRIPLE"
.build/release/LoupeBench replay --script close /path/to/six-or-more-photos
```

Run the GUI scripts in an unlocked macOS session with System Events Accessibility and Loupe closed. The scripts keep
the test config, state database and thumbnail cache under the supplied output directory and switch full-screen Spaces.
Use a separate output directory per run and supply full paths.

```sh
python3 scripts/session-bench.py --app /path/to/Loupe.app --out /path/to/session-run --label after \
  --file /path/to/folder1/image.jxl --file /path/to/folder2/image.jxl \
  --file /path/to/folder3/image.jxl --file /path/to/folder4/image.jxl --file /path/to/folder5/image.jxl
python3 scripts/switch-bench.py --app /path/to/Loupe.app --out /path/to/switch-run --restore \
  --viewer /path/to/viewer/image.jpg --home /path/to/NAS/folder
```

Intel measurements are deferred.
