# Viewer mouse workflows

Approved in the toolbar conversation on 2026-10-30. RMB is a modifier and retains vertical drag zoom. The user clarified that the earlier mention of LMB was a slip; LMB keeps image panning.

Viewer defaults: Gesture toggles Manual/SmartZoom; Back/Forward choose detected groups in either direction; RMB+Back/Forward choose profiles; RMB+main wheel changes neighbouring folders; thumb wheel remains smooth zoom; RMB+Gesture toggles stats; Panel toggles auto colour; Panel+wheel adjusts auto-colour strength; Middle stays Fit/100%; Panel long press toggles Vibrance; RMB+middle stays Fit Width. Vibrance uses the requested long Panel press; other frequent commands use taps or wheels. File View keeps Back/Forward directory history, independent of viewer bindings.

Manual adjustments affect only the current photo: SmartZoom mode/profile/group remain selected and automation resumes on the next photo. Explicit Manual/SmartZoom switching preserves the current view when disabling and restores the last enabled mode when enabling. Add reverse group/profile actions. Keyboard defaults retain G power, N/Shift+N group next/previous, M/Shift+M profile next/previous; move save detector size to Option+Shift+M. User bindings override defaults.

B toggles native viewer toolbar pinned/autohide, including fullscreen. Pinned suppresses stats without destroying their stored preference; autohide restores the previous stats policy. Existing Option+Command+T toolbar enable/disable remains separate. Typed text fields must retain B. Explicitly requesting stats while pinned switches to autohide and shows stats, so that command has a visible result.

Wheel navigation drops excess impulses, never buffers a burst. Use the existing configurable folder-scroll-repeat interval and reject new wheel transitions while a folder transition is pending. Late/cancelled work cannot replace a newer destination.

Right-modified wheel chords suppress tap/long actions and accidental RMB drag zoom. Releasing the modifier first must not turn a modified gesture into an ordinary colour adjustment. Neutral public examples only.

Ownership: this task temporarily owns ViewerWindowController.swift and ViewerView.swift plus input/toolbar files. Inspector session owns HomeScreenKit and final packaging/installation. Preserve existing dirty changes; no whole-file commits of mixed work, no release/tag/merge/push.

The SmartZoom toolbar mode group contains Auto and Pan only. Choosing profiles or detected groups does not enable power implicitly. The selected group is remembered per profile. No Panel+thumb-wheel chord is assigned. Back/Forward and Gesture taps wait for release so a drag does not fire a click action.

Windowed autohide uses an event-driven AppKit monitor and one cancellable delayed hide; fullscreen uses the existing native compatibility boundary. No new private API was introduced, but the existing guarded AppKit pin/autohide selectors remain private API and a compatibility risk.

## Hardware correction

The user reports that Panel cannot be pressed while RMB is held. RMB+Panel defaults were removed; generic custom chord parsing is retained. Vibrance toggles with a long Panel press (on release) or V. The user chose toolbar-only strength adjustment, so no Vibrance wheel binding is assigned. Merely holding RMB must not suppress vertical drag zoom; wheel/chord use suppresses it until release, and the next RMB press restores zoom.
