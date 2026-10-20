<div align="center">

<img src="docs/images/icon.png" width="128" alt="Loupe icon">

# Loupe

**A Metal image viewer for macOS that shows a 300-megapixel photo, fully sharp, in under a second from launch.**

Built for looking at beautiful things up close: space telescope mosaics, scans of old masters, huge AI renders,<br>
whole folders of photos on a NAS — with the keyboard, the trackpad or an MX Master.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Metal%20%2B%20MetalFX-blue)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange?logo=swift)
![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green)
![Stash](https://img.shields.io/badge/works%20with-Stash-8a2be2)

<img src="docs/images/viewer.webp" alt="Loupe showing the James Webb Cosmic Cliffs image, 14575 × 8441, decoded in 254 ms">

<sub>The Webb telescope's Cosmic Cliffs, 14 575 × 8 441 (123 MP), sharp on screen in under half a second from launch.</sub>

</div>

---

## Why Loupe

- **Huge images are not a special case.** A tiled Metal pyramid keeps 100–300 MP photos as fluid as a phone snapshot: zoom, pan, flick through a folder — no spinner, no blurry wait.
- **Every format gets its fastest decoder.** libjpeg-turbo for JPEG, a patched libjxl for JPEG XL (with an instant 1:8 preview), ImageIO for HEIC, AVIF, WebP, PNG, TIFF and the rest — chosen by the file's magic bytes, not its extension.
- **It predicts where you're going.** Neighbouring photos are decoded and uploaded to the GPU before you ask, so the next photo is already there.
- **A real home for your photos.** A Photos-style Home with Recent, Sessions, a folder browser with live covers, a sidebar tree, two thumbnail modes — and a native window onto your [Stash](https://github.com/stashapp/stash) library.
- **Made for hands, not menus.** mpv-style `input.conf` bindings, trackpad gestures, right-button drag zoom with inertia, and first-class Logitech MX Master 4 support, haptics included.

## Numbers

Measured on a MacBook Pro with M4 Max (36 GB), macOS 27, on the public images credited [below](#image-credits). Every figure can be reproduced with the scripts in this repo.

**From launch to a sharp picture** (`scripts/startup-bench.py`, median of 5 cold launches, ms from exec):

| File | Window up | First picture | Full resolution on screen |
|---|---:|---:|---:|
| Webb *Cosmic Cliffs*, JPEG, 14 575 × 8 441 (123 MP) | 117 | 375 | **462** |
| Same image as JPEG XL (lossless JPEG transcode) | 156 | 481 | **481** |
| Hubble *Orion Nebula*, JPEG, 18 000 × 18 000 (324 MP) | 149 | 694 | **994** |
| Bruegel *The Harvesters*, JPEG, 3 840 px | 168 | 285 | **285** |

**JPEG XL decoding of the 123 MP image** (`LoupeBench`, wall time):

| Method | Full decode | Preview |
|---|---:|---:|
| Apple ImageIO | 363 ms | 392 ms |
| **Loupe's libjxl** (multithreaded) | **114 ms** — 3.2× faster | **20 ms** (1:8 DC image) |

Lossy JPEG XL: 194 ms vs ImageIO's 580 ms. The 20 ms preview comes from `JxlDecoderGetDCImage`, a small addition to libjxl that Loupe ships with: you see the whole photo almost at once, and the full resolution replaces it a moment later.

While you look, the stats bar (`I`) shows what the GPU is doing — frame time, dropped frames, the decoder used and how long it took.

## Features

<table>
<tr>
<td width="50%"><img src="docs/images/zoom100.webp" alt="100% zoom into the Cosmic Cliffs"></td>
<td width="50%"><img src="docs/images/strip.webp" alt="The thumbnail strip with its magnifier"></td>
</tr>
<tr>
<td><b>Every pixel, instantly.</b> <code>1</code> for 100 %, <code>2</code>/<code>4</code> for 200/400 %, pinch, double-tap Smart zoom, or hold the right button and drag. Zoom stops at fit-width, fit-height and 100 % click under your finger.</td>
<td><b>The strip.</b> A dock-style magnifier over the folder's thumbnails; hover, scrub with two fingers, click to jump. It hides itself when you don't need it.</td>
</tr>
<tr>
<td><img src="docs/images/home-recent.webp" alt="Home: Recent"></td>
<td><img src="docs/images/folders.webp" alt="Folder browser with live covers"></td>
</tr>
<tr>
<td><b>Home.</b> Recent folders with their covers and progress, Sessions you can reopen, and browser-like tabs and windows that come back after a restart.</td>
<td><b>Folders.</b> A fast browser with live four-photo covers, built on a SQLite thumbnail catalog. It browses zip archives on a share without copying them.</td>
</tr>
<tr>
<td><img src="docs/images/thumbs-square.webp" alt="Square thumbnails"></td>
<td><img src="docs/images/thumbs-aspect.webp" alt="Thumbnails in their own aspect ratio"></td>
</tr>
<tr>
<td colspan="2"><b>Two thumbnail modes.</b> <i>Square</i> for a calm, even grid like Photos; <i>Aspect</i> to see every picture whole, in its own proportions. One click in the toolbar, and Loupe remembers it.</td>
</tr>
<tr>
<td><img src="docs/images/autocolour.webp" alt="Auto colour and vibrance, before and after"></td>
<td><img src="docs/images/info.webp" alt="Info panel"></td>
</tr>
<tr>
<td><b>Auto colour and vibrance.</b> <code>C</code> and <code>V</code> — left half original, right half corrected. Applied on the GPU as a colour cube, remembered per folder, never written to your files.</td>
<td><b>Info panel.</b> <code>⌘I</code>: file, EXIF, colour profile, bit depth, the decoder and its timings, memory — and AI generation parameters (A1111, ComfyUI) when a PNG carries them.</td>
</tr>
<tr>
<td><img src="docs/images/sidebar.webp" alt="Sidebar with the folder tree"></td>
<td><img src="docs/images/cheatsheet.webp" alt="Keys and gestures cheat sheet"></td>
</tr>
<tr>
<td><b>Sidebar.</b> Sources and places with a folder tree that follows you, for deep libraries.</td>
<td><b>Everything is a key.</b> <code>?</code> shows every binding of your current layout, gestures included.</td>
</tr>
</table>

### Image quality

Pick the resampling filter per folder (`S`): Lanczos-3 and Lanczos-2 with anti-ringing, Mitchell, Catmull-Rom, EWA Lanczos, bilinear, MetalFX spatial upscaling, and a crisp nearest-neighbour *pixel-art* mode for sprites and screenshots. Downscaling goes through a filtered pyramid, so a 300 MP photo at 20 % stays clean instead of shimmering. The render tests compare every filter pixel by pixel against Core Graphics and a CPU reference.

### Mouse, trackpad and MX Master

- Three-finger swipes and taps, force click, two-finger scrubbing on the strip, click-and-swipe chords.
- Right-button drag to zoom with inertia and rubber banding.
- **Logitech MX Master 4** over HID++ through the Bolt receiver, no Logi Options+: the haptic panel, gesture and shift buttons, button + wheel and button + move chords, and haptic feedback on zoom stops, limits, folder ends and more.

<p align="center"><img src="docs/images/settings-mouse.webp" width="49%" alt="Settings: Mouse & Trackpad"> <img src="docs/images/settings-zoom.webp" width="49%" alt="Settings: Zoom & Pan"></p>

## Stash

<img src="docs/images/stash.webp" alt="Stash library inside Loupe">

Loupe has a built-in window onto **[Stash](https://github.com/stashapp/stash)**, the self-hosted media organizer: your Stash library opens in a Loupe tab (`⇧⌘L`), and a click on a gallery opens it in Loupe's viewer — straight from your NAS, mounting the share if it isn't mounted yet, with Stash's own order and paging for previous/next.

- Path rules map Stash's paths (including Windows drive letters and `\\server\share`) to your Mac's mounts.
- Zip galleries open like folders, without unpacking.
- Works with or without an API key; **Settings → Stash → Check** verifies the connection.

Stash support is under active development in both Loupe and its sibling video player [FrameScrub](https://github.com/ampire5/FrameScrub).

<p align="center"><img src="docs/images/settings-stash.webp" width="60%" alt="Settings: Stash"></p>

## Install

```sh
brew install --cask ampire5/tap/loupe
```

Or download the zip from [Releases](https://github.com/ampire5/Loupe/releases). Builds are not signed with an Apple Developer ID yet; the cask clears the quarantine flag for you.

### Build from source

 You need macOS 26 or later on Apple Silicon and the Command Line Tools (`xcode-select --install`); Xcode is optional (its `actool` builds the Liquid Glass app icon).

```sh
brew install jpeg-turbo cmake ninja brotli highway

# Loupe links its own libjxl (v0.12.0 + the DC preview functions): clone it next to Loupe
git clone -b loupe https://github.com/ampire5/libjxl ../libjxl
git -C ../libjxl submodule update --init --recursive
scripts/build-libjxl.sh

scripts/make-app.sh --install      # → ~/Applications/Loupe.app
```

`make-app.sh` bundles the libraries into the app and checks that nothing links outside it, so the app runs without Homebrew afterwards. Homebrew's own `jpeg-xl` lacks the preview functions, so a plain `swift build` fails on purpose — the scripts point it at your build.

## Configure

Everything is in the Settings window (`⌘,`) — and in two plain-text files, so you can keep them in your dotfiles:

- `~/.config/loupe/loupe.conf` — about 130 `key=value` settings, mpv-style.
- `~/.config/loupe/input.conf` — key, mouse, trackpad and MX Master bindings: `<input> <action> [args]`. `Loupe --print-input-conf` prints the full template.

Both reload when you switch back to Loupe; a mistake shows up in the window instead of being ignored. Your own Dock icons go in `~/.config/loupe/icons`.

## Tests

```sh
scripts/test.sh           # core, ~5 s
scripts/test.sh render    # + pixel-exact render tests, ~80 s
scripts/test.sh full      # everything
```

`LoupeBench` measures decoding, thumbnails, rendering, pyramids, auto colour and the browser; `scripts/latency-matrix.sh` measures input-to-photon latency.

## Image credits

The screenshots show public-domain and openly licensed works: space images by NASA, ESA, CSA and STScI (Webb and Hubble, CC BY 4.0) and NASA (public domain); paintings and sculpture from The Metropolitan Museum of Art Open Access (CC0) and public-domain works on Wikimedia Commons (Van Gogh, Hokusai, Leonardo, Vermeer, Bruegel, Klimt, Munch, Kandinsky, Mondrian and others); historic photographs in the public domain (Library of Congress, NARA); birds and animals under CC0.

## License

[GPL-3.0](LICENSE). Loupe uses [libjxl](https://github.com/libjxl/libjxl) (BSD-3-Clause) and [libjpeg-turbo](https://libjpeg-turbo.org) (BSD-style), and the MIT-licensed packages [HomeScreenKit](https://github.com/ampire5/HomeScreenKit), [InfoPanelKit](https://github.com/ampire5/InfoPanelKit), [SettingsKit](https://github.com/ampire5/SettingsKit) and [StashKit](https://github.com/ampire5/StashKit), and [LogiHIDPP](https://github.com/ampire5/LogiHIDPP) (GPL-3.0).
