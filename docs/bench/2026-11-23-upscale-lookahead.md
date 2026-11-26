# Neural upscale lookahead on M4 Max

Measured on Mac16,6 with an M4 Max, 10 performance cores, four efficiency cores and 36 GiB of unified memory. Each debug run processed six copies of a macOS Default Aerial photograph using one warmed model instance per worker, Core ML CPU + GPU, and the installed model's tile context. Timed work started with the source pyramid resident and included GPU readback, Core ML inference, stitching, output pyramid upload and PNG encoding and commit. Source reads, initial decode and model warm-up were excluded.

| Input and model | Workers | Six photos | Photos/s | Median per photo | Peak process RSS | Main actor wake-up p95 |
|---|---:|---:|---:|---:|---:|---:|
| 1920×1080, 2× | 1 | 4.08–4.12 s | 1.46 | 0.68 s | 134–138 MiB | 4.07 ms |
| 1920×1080, 2× | 2 | 3.22 s | 1.86 | 1.07 s | 183 MiB | 4.07 ms |
| 1920×1080, 2× | 3 | 2.78 s | 2.16 | 1.38 s | 238 MiB | 4.07 ms |
| 3840×2160, 2× | 1 | 14.94–16.60 s | 0.36–0.40 | 2.48–2.73 s | 275–279 MiB | 4.08 ms |
| 3840×2160, 2× | 2 | 12.17 s | 0.49 | 3.94 s | 453 MiB | 4.08 ms |
| 3840×2160, 2× | 3 | 10.67 s | 0.56 | 5.33 s | 628 MiB | 4.08 ms |
| 1920×1080, 4× | 1 | 91.11 s | 0.066 | 15.27 s | 333 MiB | 8.06 ms |
| 1920×1080, 4× | 2 | 108.64 s | 0.055 | 36.33 s | 543 MiB | 4.09 ms |

Two workers increased throughput by about 27% at 1080p and 29% at 4K against the mean of the two serial trials. Starting a third saved another 0.45 s or 1.50 s per six photos, while increasing the 4K peak RSS by another 175 MiB. Process RSS does not include the entire Metal footprint. The main-actor probe measures a 16 ms timer's wake-up delay in the test host. It does not measure interactive frame latency in a viewer window. The highest delay in the 2× trials was 7.07 ms.

The application runs an interactive request alone and cancels speculative work on navigation or memory pressure. Two background slots are allowed for saving 2× lookahead with CPU + GPU on the measured hardware. The 4× model took 19% longer with two workers, so 4× stays serial. Other compute configurations and unmeasured hardware also use one slot. A memory-only buffer keeps one slot so the earlier photos retain priority in the texture budget.

A final 4K 2× rerun also encoded and committed the small File View JPEG for each saved copy. Six photos took 15.06 s with one worker and 11.21 s with two. Peak process RSS was 288 and 470 MiB respectively. The main-actor wake-up p95 remained 8.07 ms in both runs.

## Stepping onto a running ZIP request

The viewer regression test moves from a saved 4K photo onto the next photo in the ZIP, 400 ms after the next 2× job is queued. It withholds the next original to isolate reuse of running work. Before the change, no result was saved by the 6 s deadline. After the change, the worker saved the result about 2.5 s after navigation. The viewer keeps that job while the new original loads and uses its saved pixels on arrival.

A later +2 case jumps past one frame while another still-ahead frame is processing. Before rolling the queue,
the still-relevant copy was absent at the 6 s deadline. It saved about 2.3 s after the jump with the rolling queue.
In the same runs the initial 4K 2× texture was available after about 1.4 s and the PNG and File View thumbnail
were saved after about 2.9 s. The times include the viewer dwell and refer to the result returned to the viewer;
they do not measure display presentation.

Run the regression with `LOUPE_TEST_UPSCALE_ADVANCE_PHOTO` set to a 4K SDR JPEG and a compatible 2× model in the usual model directory.

## AVIF storage quality

The current encoder uses ImageIO at quality 0.78. On Mac16,6, a 7680×4320 raster prepared from the macOS Default
Aerial photo produced the sizes below. The 8K fixture isolates the encoder and uses resampling to control the
input to every run. It does not estimate file size for every Core ML output or subject.

| ImageIO setting | File size | Encode wall time | Normalized SSIM difference |
|---|---:|---:|---:|
| PNG | 28.92 MB | 1.11 s | 0 |
| AVIF 0.60 | 1.02 MB | 0.64 s | 0.0173 |
| AVIF 0.70 | 1.41 MB | 0.58 s | 0.0129 |
| AVIF 0.78 | 1.81 MB | 0.60 s | 0.0102 |
| AVIF 0.85 | 2.34 MB | 0.63 s | 0.0079 |

The 0.78 setting keeps more structural detail than 0.70, with about 23% less storage than 0.85 for this photo.
A VideoToolbox compression session with hardware encoding required accepted HEVC and rejected AV1 on this Mac.
Encoding runs on the same bounded utility workers as the previous image writes.

## Reproduce

Use a real SDR JPEG at the intended source size. Build the tests, then set `LOUPE_BENCH_UPSCALE_MODELS` to a directory with a compatible model and `LOUPE_BENCH_UPSCALE_PHOTO` to the JPEG path. Run the opt-in benchmark separately for each worker count. The scale defaults to 2×; set `LOUPE_BENCH_UPSCALE_SCALE=4` for 4×.

```sh
. scripts/libjxl-env.sh
swift build --build-tests --triple "$DEPS_TRIPLE"
for workers in 1 2 3 1; do
  LOUPE_BENCH_UPSCALE_WORKERS="$workers" swift test --skip-build --triple "$DEPS_TRIPLE" --filter UpscaleParallelismBench
done
```
