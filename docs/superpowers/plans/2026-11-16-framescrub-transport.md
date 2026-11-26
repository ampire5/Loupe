# FrameScrub Playback Transport

**Goal:** Play timed video and audio from the provider's existing read-only descriptor. Keep pausing, seeking and stepping tied to the frame the provider actually shows.

- Test audio decoding against the same descriptor-backed cache as video, including a clip with no audio.
- Test frame scheduling against the presentation clock and keep one decoded frame pending.
- Add play, pause, seek and shutdown to the embedded transport. Verify the playback clock advances with real audio and stops when paused.
- Connect the provider and host to their product bundles and verify selection, cancellation and handoff.

On Apple Silicon, the ExtensionKit transport test played video against the FrameScrub audio clock and held the same position after pause. FrameScrub's focused suites passed 60 tests, including GIF and WebP timing and transparency, descriptor-backed playback and a paused VFR handoff. Loupe's signed build displays the poster and fallback controls in a mixed folder.

Xcode's ExtensionKit target enters through Foundation's `_NSExtensionMain`. The SwiftPM provider now links with the same entry point. A signed bundle containing that provider answered the production host's handshake and acknowledged the first picture of a local MP4, GIF and animated WebP. The engine's Xcode build also verified a round trip from 3.72 s to 3.68 s and back using the embedded frame buttons. The standard FrameScrub release packaging script completed with the new linker setting.
