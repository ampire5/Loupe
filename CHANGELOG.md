# Changelog

## 0.4.1 — 2026-11-09

- Choose Fixed, Adaptive or Off for continuous zoom stops. Adaptive settles at nearby stops during slow gestures and lets fast gestures pass through. `u` cycles the mode for the current tab; `⇧U` saves the default.
- Add folder-aware debanding and display grain, with their own controls and defaults.
- Refine trackpad navigation, filmstrip previews and haptic feedback, and update the default toolbar icons.
- Keep half-precision rendering compatible with the Intel build.

## 0.3.0 — 2026-11-05

- Browse Apple Photos alongside local folders. File View has a docked information inspector, and photo viewing history is tracked separately from file changes.
- Add subject circles and per-class protection to SmartZoom framing profiles.
- Keep the full-screen tab bar and toolbar together, with a choice of a stable visible header or automatic hiding.

## 0.2.1 — 2026-10-29

- Restore photo metadata and EXIF in the toolbar, with independent file and folder names and more readable text.
- Use native full-screen toolbar auto-hide for Home and the viewer, removing the custom edge monitor and hide timer.
- Keep one toolbar attached to each window and reuse Home/viewer controls when switching screens.

## 0.2.0 — 2026-10-29

- Add SmartZoom with Vision and optional user-supplied Core ML detectors, composition profiles, a profile editor and remembered model choices.
- Separate Manual, Pan and Auto workflows; improve framing, zoom carry and oversized subject groups.
- Add folder panels and slots with browsing independent of the open photo.
- Refine filmstrips and file cards, persistent last-opened markers, metadata, sorting and unreadable-file handling.
- Improve full-screen controls, photo status and folder information, and Logitech integration through MouseService.
- Update shared kits and remove personal collection paths from benchmark documentation.

## 0.1.0

Initial tagged release.
