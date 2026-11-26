# Optional FrameScrub playback in Loupe

Design agreed on 2026-11-15. See the [ExtensionKit spike results](../../../prototypes/framescrub-extension/README.md) for the checks completed on Apple Silicon and the remaining release checks.

Loupe lets people browse photos, animated images and videos in one sequence. Its lightweight player is an optional capability of the separately installed FrameScrub app. One command opens a video at the currently displayed position in the full FrameScrub app.

## Browsing and playback

- Include videos and animated images alongside photos in the first release for media available by filesystem path, including mounted SMB shares. Start animation coverage with GIF and animated WebP. Treat static images as photos.
- Show a poster with a Play action on selection by default. Play activates the provider. An autoplay setting activates it and starts the selected media when it becomes the active, visible item. With the provider disabled, absent or unavailable, keep the poster and offer Open With.
- Embed the provider's picture and compact transport in Loupe's viewer area. The transport offers play, pause, seek and exact previous/next presentation frame for video and animation. The picture supports fit, zoom and pan. In ordinary browsing, the unmodified left and right arrows navigate files. The provider has separate frame-step controls and keyboard commands.
- Reuse FrameScrub's manual color correction in the provider. FrameScrub settings supply the correction and the provider applies it to the picture. Reserve recurring automatic scene analysis, Loupe's photo effects and additional media sources for later work.
- Opening a video in standalone FrameScrub lands paused at the time of the last frame presented by the provider, or at the start if Loupe is still showing the poster. An in-flight seek can leave an earlier frame on screen. Handoff uses that displayed frame. FrameScrub's existing open link accepts a time. The handoff also needs explicit paused landing behavior.

## Scrub gestures and Scrub Lock

Over the active player, holding Control routes scroll gestures to FrameScrub. Horizontal trackpad motion and vertical mouse wheel motion scrub through presentation frames. Vertical trackpad motion and Option with the mouse wheel adjust player volume. The first scrub movement pauses playback and leaves the selected frame paused. Volume changes preserve the playing or paused state.

Press and release Shift-Control by itself to toggle Scrub Lock for the current item. Show the active mode in the player's controls and offer the same toggle there. While locked, the gestures work without Control. FrameScrub supplies the active layout and remapped playback keys. In Classic, Left and Right seek by five seconds, comma and period step by one exact frame, and Space toggles playback. Escape or the toggle restores Loupe's ordinary controls. Switching items, hiding the tab or losing the provider clears the lock.

FrameScrub supplies scrub sensitivity, acceleration, direction and trackpad momentum settings. Loupe keeps the route chosen at the start of a gesture through its momentum tail. Releasing Control during a gesture does not transfer the tail to file navigation. After leaving the lock or its media session, discard the old player's remaining events.

## Delivery and integration

Use an external ExtensionKit provider shipped as an extension inside `FrameScrub.app`. Loupe declares an extension point that accepts external providers and hosts the enabled provider's scene using `EXHostViewController`. The user enables the extension once in the system extension UI exposed in Loupe settings. `Loupe.app` ships its own host and protocol code; the provider executable, FrameScrub code and its playback dependencies ship with FrameScrub.

Use the XPC connection for playback commands and state. The provider owns access to the media, decoding, audio, frame presentation and the transport. Loupe owns the selected item, activation, the poster and fallback, and dispatch of the standalone open command. Confirm protocol compatibility before passing a file reference. An incompatible provider leaves the poster and Open With available. The protocol carries the file reference, session identity, playback policy and the time of the presented video frame. Choose the file access mechanism after testing the extension sandbox with both local files and mounted shares.

Tie every load and response to the current selection. On navigation, a hidden tab, window close or provider disconnect, stop audio and cancel work for the old selection. Release the old decoder and its buffers without waiting on the UI thread. Display the poster while loading and restore it if the provider deactivates. Late frames and responses from an old selection cannot replace the current item. An idle poster starts no playback process or index work.

The lightweight profile uses bounded read and decode work as playback or a frame step requests it. It avoids full-file indexing at open, even when autoplay is enabled. An exact first step into an uncached region can take longer, particularly on SMB. Use presentation timestamps and actual decoded frame order rather than nominal FPS to verify adjacent-frame stepping. Animation decoding preserves transparency, frame durations and loop metadata. Reuse the FrameScrub playback and rendering paths where they meet these requirements.

## Approaches considered

- **External ExtensionKit provider.** Keeps the complete embedded transport in FrameScrub and allows independent release of both apps. It requires one system enablement step and proof that file access, video rendering and responder routing work in the separate process.
- **Shared in-process player.** Reuses a player view and engine in both apps with direct view and file access. It would ship FrameScrub code with Loupe and couple Loupe's builds to that player.
- **Standalone open link.** Reuses the existing FrameScrub launch path and remains useful for handoff. On its own it takes the viewer out of Loupe for playback.

## Prototype and verification

Use two separately built, signed and installed app bundles with the intended distribution signing and sandbox settings. Verify discovery, manual enablement, UI hosting and XPC before extracting the full player. Play a video from a local folder and an SMB share with the same file access rules as the intended release. Verify the switch between photos, a poster and the embedded surface. Click the embedded controls and check that the plain arrows still navigate Loupe and the provider receives the separate frame-step shortcuts. Exercise failure and recovery when the extension is missing, disabled or disconnected.

Compare both directions of frame stepping against known presentation frames on constant and variable frame rate clips, after a seek and across a keyframe boundary. Verify animations with unequal durations and transparent frames. Exercise paused handoff from a displayed frame during a pending seek. Check that autoplay only starts the visible item, navigation keeps its existing key bindings and repeated switching releases resources.

Exercise the wheel and both trackpad axes during play and pause. Release Control during a scrub and check that its momentum never changes files. Verify the lock's shortcuts and indicator, Escape, item and tab changes, and provider loss. A volume gesture should preserve position while paused and leave transport running while playing.

Measure first-frame and first-step latency, UI-thread time during navigation, background reads and memory during playback, then idle work after leaving the player. Use real files on both local storage and SMB and run the responsiveness checks on Intel as well as Apple Silicon. Set resource limits from those measurements before distributing a build.

Related decisions: [Index video on demand](../../adr/0001-index-video-on-demand-in-lightweight-playback.md) and [Keep FrameScrub optional](../../adr/0002-keep-framescrub-an-optional-playback-provider.md). Platform reference: [Apple's guide to hosting extension UI](https://developer.apple.com/documentation/extensionkit/including-extension-based-ui-in-your-interface).
