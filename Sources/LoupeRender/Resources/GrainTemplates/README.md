# Nonadaptive display grain banks

Neutral monochrome patterns; no photographs or user media. Five immutable FP16
banks, 131072 bytes each. White/Fine/Soft use four 128×128 layers; AV1/Particles
use sixteen 64×64 layers. Mean is approximately zero, RMS approximately one before
bilinear sampling, output quantization and symmetric gamut limiting.

White is uncorrelated Gaussian noise. Fine and Soft use circular 3×3 convolution
with respectively weak and stronger spatial correlation. Reproduce these banks
with `python3 scripts/make-basic-grain.py` (standard library only).

AV1 and Particles are the evaluated neutral banks from FrameScrub:

- AV1 SHA256: `47239db5d7c765a050e9bbd52b100a0df888e4be6be58e397c2a928ed7060fb9`.
  Luma-table synthesis adapted from Niklas Haas / libplacebo under the accompanying
  MIT permission in `AV1-LICENSE.txt`. Gaussian lookup, 16-bit PRNG, lag-1 integer
  AR with authored coefficients 8/28/8/28 and shift 7, normalized/offline edge-blended.
  This is a pattern, not a conformant AV1/AFGS1 decoder or metadata reconstruction.
- Particles SHA256: `25d1019d751959026bae1ad1cc6b5bfced47ca3aca0ff9144e2576730f878f0b`.
  Independent periodic Poisson Boolean-disc field: median radius .55 px,
  log-spread .30, expected coverage 50%, 8× pixel integration, .25 px optical blur.
  No IPOL code was copied; this is not a full physical film reconstruction.

The source generator is FrameScrub's `scripts/make-grain-banks.py`; it requires
NumPy and the public libplacebo `src/shaders/film_grain_av1.c` at SHA256
`d0acee2090ad38777e12f2472bc3e970339b3aeb7eb20ac919cd12575dde3b69`.
All banks are loaded lazily off-main and reused as small Metal texture arrays.
There are no adaptive masks, luminance-response curves, animation or image analysis.
