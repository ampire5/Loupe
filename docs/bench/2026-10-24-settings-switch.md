# Settings window: page switches (2026-10-24)

`LoupeBench settings [--rounds N]` — the real settings window with all 11 pages over an empty loupe.conf, on screen.
A round goes down the sidebar to the last page and back up, one ↓/↑ key event per switch sent to the window (the
path a click takes: `SettingsUIState.select`), then the run loop alone for 1.5 s. The number is the main thread's
CPU time per switch (`CLOCK_THREAD_CPUTIME_ID`): on the main thread it is also how long the window does not answer.

Machine: iMac20,1, Intel Core i7-10700K, 8 cores, macOS 26.7.1. Kit: SettingsKit `settings-speed-lts`.

Complaint: "switching between categories sometimes takes up to 2–2.5 s, whatever the categories". Reproduced in
the shipped L20 by stepping pages with the keyboard: 0.2–1.5 s per switch, Mouse & Trackpad the slowest.

## Before and after

ms of main-thread CPU per switch onto the page: the first visit, and the median of the later ones (3 rounds).

| Page | before: first | before: again | after: first | after: again |
|---|---:|---:|---:|---:|
| General | 917¹ | 835 | 130¹ | 155 |
| Zoom & Pan | 451 | 414 | 431 | 115 |
| Quality | 372 | 344 | 320 | 93 |
| Colour | 237 | 225 | 237 | 86 |
| Strip | 339 | 317 | 333 | 93 |
| Interface | 234 | 293 | 256 | 100 |
| Mouse & Trackpad | 1051 | 1085 | 441 | 141 |
| Key Bindings | 327 | 262 | 300 | 145 |
| Performance | 464 | 429 | 416 | 108 |
| Stash | 269 | 195 | 234 | 86 |
| Advanced | 100 | 84 | 71 | 90 |
| **round (20 switches)** | 8209 | 8487 | 4068 | 2158–2421 |
| one setting changed by the store (all pages opened) | 63–168 | | 31–48 | |

¹ General is built when the window opens; its "first" here is already a return to it after the old code rebuilt it.

⇥ once around Mouse & Trackpad: 8 stops (sidebar, its 6 number fields, search), none on a page that is not open.
Without the window's skip the loop had 57 stops, 49 of them on hidden pages.

## What cost what (each measured alone, in this order)

1. **Every switch rebuilt the whole page.** `PageView(page:).id(page.id)` threw the page away and made every row,
   switch, field and pop-up again. Now the pages opened so far stay in a `ZStack` (`SettingsUIState.keptPages`); the
   open one is drawn, the others are at opacity 0, without hit testing, hidden from VoiceOver.
2. **`.disabled(!open)` on the hidden pages cost as much as rebuilding** (switches stayed at 300–650 ms): the
   environment change reaches every control of two pages. Dropped; `SettingsWindow` skips invisible controls on
   ⇥/⇧⇥ instead (`selectKeyView(following:)`/`(preceding:)`). Returns to a page: 300–1100 → 150–260 ms.
3. **Every row read the open page.** `ui.isMatch(row.id)` looked in `matches[page]`, so each row of each kept page
   depended on `page` and was re-evaluated on every switch. Rows now pass their own page (`settingsPageID` in the
   environment). Returns: 150–260 → 85–170 ms.
4. **`NSPopUpButton` measures each item at ~1 ms on macOS 26.** Seven haptic pop-ups of 33 items each: 0.2 s to
   measure, 0.3 s more when added to a window (a stand-alone AppKit test, no SwiftUI). A SwiftUI menu `Picker` cost
   the same. `ChoicePopUp` keeps only the chosen item until its menu first opens (`menuNeedsUpdate`) and measures
   once, with the widest title alone (equal to the full button's size in every case tried). Mouse & Trackpad first
   visit: 1090 → 430 ms; with the items cut to 3 the page took 490–540 ms, so the remaining cost is not the menus.
5. **Window opening laid out the window on every added view.** Without `autorecalculatesKeyViewLoop`, each
   `addSubview` ran `-[NSView _setDefaultKeyViewLoop]`, which lays the subtree out synchronously: ~25 % of the main
   thread while a page was built. On: window opening 990 → 471 ms, and rounds stopped getting slower
   (4.5 → 5.3 → 5.8 s before).
6. **Kept pages made every setting change expensive.** `SettingsModel` held values, errors and drafts in one
   dictionary each; Observation tracks a dictionary as one property, so a change to any key re-evaluated every row
   that read any key — on all kept pages: 190 ms per changed setting. Each key's state is now its own observable
   `KeySlot`: 31–48 ms.

## Not done / open

- A first visit still costs 70–440 ms: SwiftUI building ~15–25 ms per row on this Mac. Building the other pages
  ahead in idle time would make every switch a return, but one page is one uninterruptible block of up to 0.4 s on
  the main thread, which a click could land in; not done.
- Returns still cost 85–170 ms (layout and the Core Animation commit of the split view and sidebar list).
- In four runs of the intermediate builds a first visit sometimes took 0.8–1.3 s (Interface, Performance, Stash) and
  once a return 0.9 s; not seen in the final runs, cause not found.
- The pop-ups' look was not compared by pictures (`screencapture` needs the Screen Recording permission the
  terminal lacks): check by eye.
