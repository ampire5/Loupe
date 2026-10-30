# Persistent photo metadata

User authorized implementation on polish-3 after discussing the missing persistent fields. Keep the existing catalog and lazy inspector; do not build a second index or scan files at startup. FrameScrub receives its own implementation handoff in its existing integration chat.

1. Store successful complete PhotoMetadata reads, including absent optional values, in a versioned file-id record. Persist GPS, software, description, generation summary/text, workflow byte count, file dates, depth, alpha and the existing capture/header fields. Persist no CGColorSpace objects, decoded pixels, arbitrary EXIF dictionaries or full workflow JSON. Header geometry/orientation/profile names are sufficient to reproduce the inspector.
2. Validate size/mtime on reads and conditional writes. Delete records on file replacement/removal. Transient errors must retry. Bound each payload and the total retained metadata bytes; use additive schema creation without wiping the existing catalog.
3. Expose catalog reads/writes through the existing ThumbnailStore actor, including files opened directly in the viewer. Keep disk-disabled behavior. A full catalog hit completes the inspector without a source read or debounce. Viewer and browser share persistent metadata.
4. Tests: close/reopen round trip of all useful values, empty successful reads, failed/oversized reads, late stale writes, both replacement paths and removal; loader catalog hit and source-read avoidance; store persistence and disabled disk. Run metadata/database/inspector suites and build the app. Measure warm catalog lookups and total cache-budget behavior; report Intel verification as outstanding.

Review focus: stale source reads after replacement; absent data versus unread data; unsupported/corrupt payload version; no disk when disabled; retaining header orientation without serializing runtime rendering objects.
