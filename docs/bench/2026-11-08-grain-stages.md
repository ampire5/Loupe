# Display grain stages

Updated 2026-11-09 for the final feature without MetalFX anti-ringing.

`grain-stage=before|after`, default before. Before defines the discrete grain field
in full-resolution stored-image coordinates, independent of the resident pyramid
level. Pan, zoom and EXIF orientation carry the field with the photo. Its size is
in original photo pixels. After defines grain in physical output pixels, keeping
size and phase fixed through zoom, pan and viewport clipping.

Both stages overlay noise after colour correction in the existing final shader.
MetalFX scales the photo without receiving grain as input. Four-source-sample
filtering and a fixed four-stratum minification approximation bound work; unresolved
noise is attenuated. Alpha coverage prevents grain appearing over transparent
backgrounds. Immutable White/Fine/Soft/AV1/Particles banks load lazily on the render
thread behind a separate lock and are reused. There is no animation, adaptive mask,
extra full-screen pass or viewport scratch allocation. Grain uniforms are 40 bytes.

J toggles the current folder, preserving its pattern and parameters; Shift-J saves
pattern, strength, size and stage as defaults. Last enabled patterns are remembered
in the same bounded folder database entries. Nearest-parent inheritance is shared
with the other folder settings. Quality editors read/edit the effective folder
values when a photo is open; otherwise they edit global defaults.

Tests cover stage phase through zoom/pan/rotation, odd coarse levels, clipped
viewports, alpha, colour LUTs, nearest/table-curve output and minification. Reflection
pins the uniform layout. MetalFX source geometry/FP16-output metadata is 16 bytes;
its remaining source reads only provide grain position and alpha coverage.

## Final verification and measurements

Final serial run passed: 2312 ordinary tests (7 skipped), then 160 renderer methods
in 12 suites (178.177 s). This includes the retained MetalFX checker/solid-background
composition tests for sRGB/P3, LUT fade and both RGB8 and debanded FP16 sources.
The experimental MetalFX anti-ringing implementation, settings and diagnostics
are absent; legacy preference lines/rows are accepted and ignored without warnings.

Release production renderer on Apple M4 Max, 4000×3000 source, 6144×3456 output,
200% zoom, 30 sequential frames after 5 warmups. GPU median / p90: Fine before
3.58 / 4.39 ms, Fine after 2.20 / 2.88 ms, Adaptive-window debanding 2.26 / 2.87 ms.
Grain amount 2, size 1.25 in each stage's respective pixel units; these are different
spatial fields, not equal-output timing comparisons. The source-size-1 grain row
measured 3.58 / 4.27 ms. No build/test ran concurrently. These short runs do not
establish sustained latency or physical Intel performance. No extra viewport
staging is allocated for grain.

The final Display-Effects app was built locally and passed strict deep signature
verification. Resource hashes and bundled third-party licenses were checked.
