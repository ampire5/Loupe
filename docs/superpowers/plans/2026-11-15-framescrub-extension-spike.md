# FrameScrub ExtensionKit Spike Implementation Plan

**Goal:** Verify cross-app ExtensionKit playback before changing the product targets.

**Architecture:** Two throwaway macOS apps share an XPC protocol. The provider app embeds a sandboxed extension whose video surface is hosted by the other app. AVKit is a stand-in for the FrameScrub renderer in this experiment.

**Spec:** [Optional FrameScrub playback](../specs/2026-11-15-optional-framescrub-playback-design.md)

- [x] Build the apps and the provider extension. Inspect generated registration metadata and verify both ad hoc signatures.
- [x] Verify discovery, manual enablement, remote UI and an XPC reply from the provider process.
- [x] Play the local and SMB test clips using the initial bookmark transport. Record the subsequent SMB bookmark stall.
- [x] Play the local test clip using a read-only file descriptor sent over XPC.
- [x] Confirm visible descriptor-only playback after selecting an SMB file in the host and verify the hosted scene disconnects when the provider is disabled.
- [x] Verify plain arrows reach host navigation after clicking provider controls and Option–Right reaches the provider.
- [ ] Repeat on an Intel Mac with the intended release signing.

[Reproduction and results](../../../prototypes/framescrub-extension/README.md).
