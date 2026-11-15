# Roadmap

Loupe is made by one person in their spare time, so there are no dates here — just the order things are likely to happen in. Bugs are always fixed first. **What would make Loupe work better for you?** Tell me in a [feature request](https://github.com/ampire5/Loupe/issues/new?template=feature_request.yml): what you want to do, how you do it today, and what your collection looks like. Requests and 👍 on existing issues decide what comes next; questions and ideas are welcome in [Discussions](https://github.com/ampire5/Loupe/discussions).

## Next

- **Light, dark or system theme everywhere.** Home, the folder browser and the keys cheat sheet follow the choice in Settings, as the Settings window already does.
- **Compare two photos side by side.** Two images in one window with zoom and pan locked together — for picking the best shot of a burst, the best of several AI renders, or checking an edit against the original.
- **Photo favorites and viewing status.** Mark individual photos and filter by *Unviewed*.
- **Stash: write back.** Rating, O count and Organized from the viewer; `F` for full screen on the Stash tab.

## Implemented in the next release

- Favorite folders appear in the sidebar and as cover cards on a Favorites page.
- File View can include photos from subfolders, and sidebar folders can open in new tabs.
- The viewer has an updated toolbar and status bar, and continuous zoom can settle at configurable stops.

## Planned

- **Logitech, deeper.** More of the mouse's own features and more events worth feeling, mice connected over Bluetooth without a receiver, and more HID++ devices as people test them.
- **A contributing guide**: how to build, test and send a pull request, plus the code layout and conventions.
- **Animated images:** GIF, animated WebP, APNG, animated AVIF and JPEG XL.
- **HDR photos** shown the way macOS shows them: gain-map HEIC from the iPhone, Ultra HDR JPEG, HDR AVIF and JPEG XL on XDR and HDR displays.
- **Manual colour:** exposure, contrast, saturation and warmth per folder, built into the same colour cube as auto colour, so they cost nothing per frame.
- **Instant 100 % on 100–300 MP photos:** decode only the visible region, keep the full-resolution level sparse, and give memory back under pressure.

## Exploring

- **Everything search in Home.** Try opening photos directly from results provided by a user-configured Everything server.
- **Media-server plugins.** A documented plugin architecture shared with [FrameScrub](https://github.com/ampire5/FrameScrub): a *source* (library, metadata, viewed marks and history) and a *transport* (local path, share, HTTP). The existing Stash integration becomes the first plugin; others — Immich, PhotoPrism, Synology Photos, Nextcloud, WebDAV, S3 — are open to the community.
- **Faster reading from network shares:** decoding while the file is still arriving, paged folder listings on slow SMB shares, a first picture from the stored thumbnail.

## Not planned

- **Developer ID signing and notarization** — not for now. Install with Homebrew (it clears the quarantine flag) or allow the app once in System Settings.
- **macOS before 26.** Loupe is built on Metal and the macOS 26 interface. Intel Macs are built for as long as they get macOS 26.
- **Editing.** Loupe shows photos; colour adjustments are never written to your files.
