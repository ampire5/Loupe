# Shared thumbnail codec decision

The shared photo/video benchmark is maintained in FrameScrub: `docs/bench/2026-10-30-thumbnail-codecs.md` and `scripts/bench/thumbnail-codecs.swift` plus optional benchmark-only C adapters. It ran on Apple Silicon, macOS 27.2, on 2026-10-30. Six public Kodak images, common opaque 8-bit sRGB input, 256/480/up-to-1280px; quality settings refined against JPEG80 corpus-mean PSNR and 8x8 SSIM, with per-image differences reported. No personal images or new production codec dependencies.

The decision for both apps is **ImageIO JPEG, quality 80**. At 480px JPEG80 averaged 62.8 KB, 0.76 ms encode and 0.77 ms decode. Quality-matched WebP92 averaged 51.1 KB, 11.61/2.31 ms; JXL effort 7 q92 49.8 KB, 70.05/3.95 ms; ImageIO AVIF84 45.7 KB, 37.76/8.70 ms. libjpeg-turbo q94 was faster (0.33/0.60 ms) but produced 68.9 KB, and adding a decoder/encoder dependency to FrameScrub for the small saving was not justified. These means do not imply equal perceived quality for every image.

The synthetic 128px ImageIO cell comparison showed distinct native downsampling paths for some codecs; its quality and timing are not exact Loupe UI predictions. Native HEIC/AVIF remain explicit optional choices, not a silent default change. Intel and a larger perceptual corpus remain unmeasured.

## Loupe implementation

`ThumbnailEncoding.current` is a lazy per-process snapshot. Advanced application preferences `thumbnail-format=jpeg|heic|avif` and `thumbnail-quality=10...100` (80 default) take effect after relaunch. The selected encoder is resolved against system capabilities; an unavailable encoder falls back to JPEG. A failed optional encoding also attempts JPEG. Existing decoder/cell APIs detect payload type from its header.

`Thumbs.db` records selected codec/rounded quality alongside its existing size, catalog id and format version. On policy change only thumbnail payloads are reset; `Catalog.db`, photo metadata and file ids remain. Legacy payloads with no encoding stamp are treated as JPEG80, preserving the existing default cache on upgrade. All encoding, database opening and type discovery stay on existing worker/store paths; no startup scan or new UI controls.

Verification: three tests cover preferences/defaults/clamping/capability fallback, actual supported encoder payloads through existing cell decoding, and thumbnail-only invalidation with metadata/id retention. The 99-test targeted thumbnail/metadata/inspector run passed, followed by the standard repository test script (2243 core-pass tests, 7 skips). Existing UI/control checks are recorded separately in `2026-10-30-mouse-workflows.md`.

Additional reset regression: an incompatible catalog format must drop all file-id-keyed auxiliary tables before ids are reassigned. The new red/green test reproduced stale photo metadata attaching to a different file after format reset; clearing photo metadata, facts and subjects with the file table fixes it. The follow-up 140-test database/store/metadata/inspector run passed.

Final standard test-script rerun after the catalog-reset fix: 2244 tests passed, 7 skipped.
