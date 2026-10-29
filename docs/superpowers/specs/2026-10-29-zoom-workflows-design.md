# Separate manual zoom and SmartZoom

Approved in chat: direct Auto command, independent manual/Smart settings and saves.

- Shift-Z and Subject always enter/reapply Auto using the selected profile and its priority chain. Legacy toggle-step-zoom and native Smart Zoom gesture are aliases, so existing mouse binding works directly.
- Option-S exits to Manual without changing the achieved view; resuming the last Smart mode reapplies its composition. G becomes a compatibility alias for the same world switch; digits never change meaning.
- 0 selects Manual + Fit, without clearing the selected detector/profile. Fixed ordinary zoom presets select Manual. Wheel/pinch adjustments can temporarily adjust the current photo but never teach a new profile size.
- SmartZoom defaults to Auto when first activated; Pan is an explicit additional panel choice. N/M and profile/group selectors resume the last Smart mode from Manual.
- All ordinary keep/default/carry settings and Smart profile/composition settings have disjoint save scopes. Option-L saves only the currently active world. Menu exposes separately named folder/default saves. Saving Smart while Manual preserves its last enabled mode.
- Auto always uses the configured profile size and recomputes composition, rather than learning manual changes. Per-photo saved ordinary views cannot override Auto on arrivals.
- Toolbar always retains ordinary zoom presets and offers explicit Manual/Auto controls plus the optional SmartZoom panel. Status identifies Manual or SmartZoom, Auto/Pan, profile, selected group, and actual zoom.
- Original-image cap and Fit floor remain. No analysis while Manual. No main-thread I/O or new polling.

Alternative rejected: keep the old toggles and add instructions. Their meanings depend on prior state and do not give a repeatable one-command Auto path.
