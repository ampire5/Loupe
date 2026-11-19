# Keep FrameScrub an optional playback provider

Loupe and FrameScrub ship independently. The separately installed FrameScrub provides the embedded playback surface and transport for video and animated images. The Loupe bundle contains only its side of the integration and ships without FrameScrub binaries.

The user enables the separately installed ExtensionKit provider through the system extension controls available from Loupe settings. When the provider is unavailable or disabled, Loupe keeps video and animated image posters in the same browsing order and offers Open With.

## First release

- The provider opens files available by filesystem path, including mounted SMB shares.
- Loupe keeps the left and right arrow keys for file navigation. The provider offers distinct frame-step commands.
