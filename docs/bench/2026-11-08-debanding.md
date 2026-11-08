# Debanding port

2026-11-08, M4 Max (Mac16,6), 14 physical CPU / 32 GPU cores, 36 GiB,
macOS 27.2. No physical Intel measurements.

## Behavior

Quality → Debanding adds Four samples, Two passes, Adaptive, Reference (libplacebo)
and Adaptive window. Global `deband=off` remains the default. Strength0–1,
threshold.1–32 RGB8 levels, radius1–64 input-level pixels, reference iterations1–4,
texture protection0–1. Fixed-sample modes derive threshold/radius from strength;
protection applies to Adaptive/Window. Filtering is spatial and deterministic,
before scaling and colour correction. Grain remains separate in either stage.
Original files, decoder/pyramid pixels and export data remain unchanged.

`DebandCache` filters visible tiles of the selected resident level plus reconstruction
padding into FP16. A fitting photo may occupy that complete level; no second
pyramid is generated. Two weakly source-keyed entries reuse results through
unchanged views and colour/grain edits. Retained filtered storage is bounded by
min(1 GiB,physicalRAM/32), including actual Metal allocation sizes. Command buffers
retain resources through completion, so this is not a peak-process memory bound.
A budget/allocation failure preserves the original and issues a scoped one-shot
viewer notice. Off/empty releases cleanup entries. No worker queue, timer or
history is added. Compilation uses a separate lazy library/pipeline lock on the
render thread; disabled filters do not compile that library or allocate windows.

Input reads use encoded views where available; alpha unpremultiplies in linear
light and mismatched coverage rejects neighbouring colour. Output retains center
alpha and linear premultiplication. Double recomputes the first-pass neighbourhood
instead of retaining a second whole window; unlike FrameScrub's two physical
passes it does not quantize that intermediate to FP16. Reference logic reads
immutable originals, caps iterations and retains the LGPL adaptation notice,
source revision and license under third_party/libplacebo (also packaged in app).

## MetalFX precision

Enabled cleanup replaces existing MetalFX input/output with encoded FP16 while
retaining perceptual processing. Compose encodes; final sampling decodes each
texel before bilinear interpolation. Limiting references actual encoded-half input,
including first-checker reconstruction. Off retains original RGB8 formats/path.

A native isolated texture probe demonstrated why processing mode must stay fixed:
linearFP16/.linear versus original had max7.43 RGB8-code difference and >2 codes
in4.55% of channel pixels on a sharp texture. EncodedFP16/.perceptual reduced this
to max2.64 and four channels of230400 >2. The final production geometry/composition
then passed its ≤2-code texture comparison. Sub-code gradient tests retain more
than two output values over a ramp narrower than one RGB8 code.

## Correctness evidence

Known quantized grayscale ramp, strength1, default texture protection, source1536×768,
2× upscale into320×240. MSE against a known continuous ramp (smaller is better):

| Mode | Bilinear | Lanczos3 | EWA | MetalFX |
|---|---:|---:|---:|---:|
| Off |1.4776|1.4776|1.4776|1.5683|
| Four samples |.3565|.4429|.4087|.5549|
| Two passes |.1351|.1823|.1659|.2707|
| Adaptive |.3072|.3256|.3215|.3203|
| Reference |.5040|.7107|.5813|.8940|
| Adaptive window |.2013|.2043|.2043|.2036|

This synthetic metric is not a general image-quality ranking. Strong cleanup can
remove genuine low-contrast detail. Tests also cover sharp steps, alpha boundaries,
clipped compact windows, cache reuse/eviction/invalidation, zero-memory rejection,
odd mirrored coarse levels, nearest, ROMM RGB, constant LUT plus both grain stages,
and both checker colors with LUT fade/P3 conversion/FP16 composition. CPU/Metal
uniforms preserve previous strides via compact slice offsets; deband ABI is64 bytes.

## Final state after removing experimental MetalFX anti-ringing

The complete serial suite passed: 2312 ordinary tests (7 skipped), 160 renderer
methods. Debanding, FP16 MetalFX composition, grain and Lanczos anti-ringing remain.
The composition regression still compares both checker backgrounds with solid
references, LUT fade, P3 conversion and debanding; it does not depend on a limiter.

On M4 Max, release production renderer, 4000×3000 input and 6144×3456 output,
Adaptive window at 200% measured 2.26 / 2.87 ms GPU median / p90 over 30 sequential
frames after 5 warmups. The cold frame took 6.18 ms GPU; retained cleanup was
110.0 MiB and existing FP16 MetalFX textures 326.0 MiB. Cleanup dispatched once
and subsequent unchanged frames reused it. At 125%, cold GPU time was 7.29 ms;
cleanup retained 210.4 MiB, with the image not filling the view. No concurrent
build/test ran. This is not a sustained/Intel or peak-process-memory guarantee.
