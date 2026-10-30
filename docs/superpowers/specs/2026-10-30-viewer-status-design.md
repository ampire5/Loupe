# Viewer toolbar status

The approved design is one dark glass surface, 46 pt high, with two vertical separators. Its three sections are file/folder/navigation, file facts plus EXIF, and zoom plus SmartZoom profile/group. Names are plain text. File facts open the existing Info panel; there is no sibling-folder picker or second information card.

The initial alternative used separate capsules; the chosen unified surface retains the same grouping and responsive behaviour. Secondary labels and file-name space yield first; graphical toolbar controls remain available. EXIF, profile and group retain visible values at the window's supported 320 pt minimum; long user-supplied names may truncate with full accessible labels/tooltips. The panel never grows beyond 46 pt or shrinks its text below 11 pt.

Position opens a numeric jump control. Zoom offers existing presets and an exact percentage. SmartZoom mode, profile, group and keeping zoom use the existing session actions. Profile/group choices are populated only when opened. Existing keyboard shortcuts and advanced settings remain available.

Loading preserves prior facts until replacement metadata arrives, distinguishes missing EXIF from pending EXIF, and preserves title/folder error messages. Typed zoom information must not be parsed out of the human-readable stats string. No file I/O, model scanning, detection, timers or render-loop activity is introduced by the status view.

Validation covers native toolbar layout at 320, 400, 640, 800, 1024 and 1800 pt window widths, long names, missing and delayed metadata, empty sessions and action routing. A real-window benchmark measures main-thread CPU for first and repeated updates, resizes and popup construction. Record machine/results; a physical Intel Mac check remains required before distributable handoff if unavailable locally.

## Follow-up correction

Restore the graphical navigation, zoom-step, zoom-preset and SmartZoom controls to the left of the status. Keep zoom/position belongs in that button row, explicitly labelled by tooltip/accessibility; it does not control full-screen toolbar visibility. Replace the irregular third-section layout with aligned Zoom/Mode/Profile/Group columns (captions above values), collapsing to a consistent two-column grid when space is short. Keep the single 46 pt surface and existing actions.

## File/group and workflow follow-up

Manual / SmartZoom returns as a native toolbar selection group. File and folder text take separate full rows before optional position controls. Profile and group take separate rows, allowing a long group to use the full section width. Quick preset buttons yield first when this meaningful text needs room; the capture section remains bounded by its contents.

## Ultra-wide balance correction

The surface maximum equals the sum of its content-sized sections. Surplus window width stays outside the glass, rather than stretching the third section and separating mode/scale from profile/group. Long names and groups increase their section preferences within bounded limits; compression still applies in narrower windows.
