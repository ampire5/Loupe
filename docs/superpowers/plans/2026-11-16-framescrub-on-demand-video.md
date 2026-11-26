# FrameScrub On-Demand Video Implementation Plan

**Goal:** Verify a FrameScrub decoding session that can read from a descriptor supplied by Loupe, seek by presentation time and step in either direction without building a full-file index.

**Architecture:** FrameScrubCore owns read-only descriptor access and the decoder session. The session uses MediaSource, ReadCache and VideoDecoder directly. A single provider worker will own the session and its cancellation when it is wired to the extension.

**Spec:** [Optional FrameScrub playback](../specs/2026-11-15-optional-framescrub-playback-design.md)

- [x] Test that FileByteSource accepts an independently owned read-only descriptor, continues reading after the original handle closes, and rejects a writable descriptor.
- [x] Test on-demand seeks and directional steps against presentation timestamps and pixel markers on CFR, VFR, fragmented MP4 and open-GOP HEVC fixtures.
- [x] Implement descriptor access and the decoder session in FrameScrubCore. Validate the focused integration tests and the existing decoder and read-cache tests.
- [x] Exercise FrameScrubCore in the ExtensionKit provider and confirm the host displays and steps frames through the existing descriptor handoff.

See the [prototype run instructions and results](../../../prototypes/framescrub-extension/README.md).
