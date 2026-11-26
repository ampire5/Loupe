# Playback input implementation plan

**Goal:** Add temporary FrameScrub gestures and Scrub Lock to the active playback surface.

**Architecture:** Loupe classifies and owns the gesture until its last event. The FrameScrub provider translates forwarded gestures and keys with its existing gesture router and input bindings. Playback extensions that predate the input protocol retain the original controls.

**Spec:** [Optional FrameScrub playback](../specs/2026-11-15-optional-framescrub-playback-design.md)

- [x] Test the host route for modifier release, momentum, exit and the modifier-only chord.
- [x] Route input at the viewer window, preserving text editing and regular browsing. Use system icons, accessible names and a dark backdrop for controls over the picture.
- [x] Load the current layout and scrub configuration on the provider's worker. Reuse FrameScrub's input map and gesture router. Apply volume independently of the playback clock.
- [x] Build both apps and exercise the lock button, seek and frame keys, volume, Escape and ordinary file navigation with the signed extension.
- [ ] Exercise a physical wheel, two-axis trackpad and modifier-only chord through AppKit in the signed apps. The remote desktop API declined scroll delivery to the test window and requires a non-modifier key for synthetic key chords.

The Apple Silicon run passed 7 Loupe playback tests and 104 FrameScrub input and decoder tests. The signed player loaded the configured volume, sought inside the active video while locked, stepped to the next presentation frame, then navigated to the next file after Escape.
