# Full-screen tabs implementation plan

**Goal:** Keep native tabs reachable in full screen and centre the Pro Camera summary.

**Design:** `fullscreen-tabs=shown|auto`, default `shown`, belongs beside the full-screen toolbar setting. Shown keeps the native header expanded whenever the tab bar is present; auto hides the toolbar and its bottom accessory together. B remains a temporary override. Use AppKit's native centring when space permits, preserving compact status layouts.

**Approaches:** A separate custom tab strip duplicates AppKit tab routing; pointer-driven pinning can move the header during interaction. Keep the existing native header and select its visibility policy instead. The visible-header tradeoff was explained in chat after the user's choice of visible tabs with an optional switch.

**Constraints:** No private tab view classes, polling, recurring timers, new kit dependency or user media fixtures. Existing toolbar compatibility selectors remain isolated in WindowToolbarController.

- [x] Observe failing native summary-centre assertions; use centeredItemIdentifiers; verify narrow layouts.
- [x] Observe failing config default/parser test for fullscreen-tabs.
- [x] Add the config, settings row and native accessory policy. Include tabs in effective pinning; reconcile on tab layout, selection and setting changes.
- [x] Verify default shown, auto, live switching, B override and exit in the real two-tab full-screen bench; run the normal suite separately from UI probes.
- [x] Update architecture and bench evidence, inspect neutral snapshots, build and sign the final app.
