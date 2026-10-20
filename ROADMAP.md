# Roadmap

Loupe is made by one person in their spare time, so there are no dates here — just the order things are likely to happen in. Bugs are always fixed first. Ideas and votes are welcome in [Issues](https://github.com/ampire5/Loupe/issues).

## Next

- **Compare two photos side by side.** Two images in one window with zoom and pan locked together — for picking the best shot of a burst, the best of several AI renders, or checking an edit against the original.
- **Favorites and Viewed.** Mark photos and folders, see at a glance what you haven't looked at yet, filter by *Unviewed*.
- **A new stats bar and strip** in the viewer, in the style of the new Home.
- **Stash: write back.** Rating, O count and Organized from the viewer; `F` for full screen on the Stash tab.

## Planned

- **Animated images:** GIF, animated WebP, APNG, animated AVIF and JPEG XL.
- **HDR photos** shown the way macOS shows them: gain-map HEIC from the iPhone, Ultra HDR JPEG, HDR AVIF and JPEG XL on XDR and HDR displays.
- **Manual colour:** exposure, contrast, saturation and warmth per folder, built into the same colour cube as auto colour, so they cost nothing per frame.
- **Instant 100 % on 100–300 MP photos:** decode only the visible region, keep the full-resolution level sparse, and give memory back under pressure.

## Exploring

- **Media-server plugins.** A documented plugin architecture shared with [FrameScrub](https://github.com/ampire5/FrameScrub): a *source* (library, metadata, viewed marks and history) and a *transport* (local path, share, HTTP). The existing Stash integration becomes the first plugin; others — Immich, PhotoPrism, Synology Photos, Nextcloud, WebDAV, S3 — are open to the community.
- **Faster reading from network shares:** decoding while the file is still arriving, paged folder listings on slow SMB shares, a first picture from the stored thumbnail.

## Not planned

- **Developer ID signing and notarization** — not for now. Install with Homebrew (it clears the quarantine flag) or allow the app once in System Settings.
- **Intel Macs and macOS before 26.** Loupe is built on Metal and the macOS 26 interface.
- **Editing.** Loupe shows photos; colour adjustments are never written to your files.
