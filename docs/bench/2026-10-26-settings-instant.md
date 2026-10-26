# Settings window: switches without lag (2026-10-26)

Follows [2026-10-24-settings-switch.md](2026-10-24-settings-switch.md). Kit: SettingsKit 0.5.0 → 0.6.0.

`LoupeBench settings [--rounds N] [--settle MS] [--icons N] [--start ID] [--shots DIR]`, the real window and all 11
pages over an empty loupe.conf, 85 icons of ~1 MB in the Dock icon row unless `--icons 0`. New in the bench:

- **turn ms**: the longest run loop turn after the switch, in main-thread CPU (`CLOCK_THREAD_CPUTIME_ID`, from the
  loop's wake or entry to its next wait or exit, after the Core Animation commit). Input is handled between turns, so
  this is how long a click or key waits at worst. The CPU column stays: the total of the switch, all turns.
- a ← press before the rounds: the window's first key press sets up text input for the search field (~40 ms once).
- **at rest**: main-thread CPU in 2 s with nothing to do (1–3 ms after: nothing runs).
- `--start ID` opens on that page, to measure one page's first visit (start on the page before it); `--shots DIR`
  saves the window after each first visit (the pictures checked against the old build: same pixels, sidebar and pages,
  glass and plain).

Machine: Mac16,6, Apple M4 Max, macOS 27.0.1 (the Intel iMac was not at hand; the previous document's Intel numbers
were ~2.7–3× these). The machine was shared with other builds: runs vary, a loaded run doubles everything; the numbers
below are from quiet runs (load average < 5), 2–3 each.

## Before and after

| | before (0.5.0) | after (0.6.0) |
|---|---:|---:|
| return to a page, CPU per switch | 26–52 ms | 10–16 ms |
| round of 20 switches, all pages kept | 780–810 ms | 250–265 ms |
| first visit, longest turn | the whole page in one turn: 33–262 ms | 20–34 ms (Key Bindings 55) |
| first visit, CPU in all | 33–262 ms | 40–250 ms, in turns of ~10–15 ms |
| one setting changed by the store | 8–19 ms | 4–6 ms |
| at rest | 1–2 ms in 2 s | 1–3 ms in 2 s |

## What cost what

1. **Kept pages lost their AppKit controls when hidden.** At opacity 0 in one SwiftUI tree, SwiftUI drops a hidden
   page's platform views from the display list: every return put the fields, pop-ups, the bindings tables and the
   scroll view back into the window (`_AppKitAddSubview` → `-[NSView _setWindow:]` down each subtree), two thirds of a
   return. Each kept page is now its own `NSHostingView` in an AppKit container (`PageStack`), and a switch sets
   `isHidden`. Returns 32–58 → 18–27 ms.
2. **The sidebar `List` redid its rows on every switch.** The open page's sub-sections are rows that come and go, so
   the stock `NSOutlineView` diffed its rows, made row views and measured automatic row heights each time
   (`OutlineListCoordinator.update`, `_preparedRowViewForRow`). The sidebar is now a scroll view of rows with the
   list's metrics (rows 28 pt + 4 above and below, content 16 pt in, selection 10 pt in). Returns → 10–15 ms.
3. **A first visit built the whole page in one turn.** A page is now built a few lines per run loop turn
   (`PagePieces`): half a piece at once, then one piece per turn, each sized to ~10 ms by the cost per line measured
   on the Mac (at most 4 lines: cheap pieces of nested switches taught a low cost, and a piece of pop-ups sized by it
   took 50–120 ms). It shows at once and fills in below; input gets through between pieces. Of a page's cost about a
   third is the AppKit controls, a third the rest of the rows (symbols, texts, notes), a third the page itself; the
   cards' glass ~8 %; tooltips, context menus and gestures nothing measurable (each taken out in turn).
4. **The bindings tables were SwiftUI `Table`s**, a hosting view per cell: ~40 ms for the visible rows. Now
   `NSTableView`s with plain text cells (cells laid out by frame instead of constraints measured slower: 76 vs 59 ms
   for the page). Their columns now share the width (the Source column was cut off before).
5. **The Dock icon row read every icon to show one.** `iconChoices()` lists ~/.config/loupe/icons and each pack
   (~900 files here: 20–25 ms of the main thread), on the main thread, when General is built (with the window) and on
   every change of `app-icon`. The row now asks `Settings.appIconChoice` for its one picture; the grid reads the list
   when it opens. With the grid closed nothing watches the folder (the watch starts and stops with the grid) and no
   thumbnail is made; the thumbnails stay in a 32 MB cache once made. 85 icons against none made no measurable
   difference to the switches.

## Not done / open

- Key Bindings' first visit: 55 ms for the first table card in one turn.
- The window's title is set on every switch: ~2–3 ms, part of it waiting for the window server (a CA fence).
- Opening the window: 500–650 ms of CPU, now in turns (the first page builds in pieces); not looked at further.
- Two one-off returns of 200+ ms in one run, not seen again in the next runs (the machine was loaded at the time).
- Not measured on an Intel Mac.
