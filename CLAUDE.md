# Rules for coding agents

These rules hold in every repository of this family (Loupe, FrameScrub, HomeScreenKit, SettingsKit and the other
kits); each repository carries the same copy.

## Speed and responsiveness

The app must be fast, and it must never load the machine so much that the machine or the app stops responding.

- Background work (thumbnails, indexing, caches, preloading, analysis) never takes every core. Its parallelism is
  derived from the machine (physical cores, not logical threads) and capped at a share of them.
- Background work runs at `.utility` or `.background` QoS; what the user is waiting for runs at `.userInitiated` or
  `.userInteractive`. The background yields to the foreground: it pauses or is cancelled while the foreground is busy.
- The main thread never blocks: no synchronous I/O, decoding or long computation on it.
- Memory and I/O are bounded too: a bounded number of tasks and buffers in flight, no unbounded queues.
- No load peaks: big work is cut into bounded pieces with room for frames and input between them; show what exists at
  once and refine later.
- Quiet at rest: with no input and no pending work the app does nothing. No endless animations, timers or display
  links; everything repeating has a stop condition and pauses when the window is not visible.
- Parallelism and limits are chosen by measurement on real data, not guessed. The measurement (what, which machine,
  the result) is written next to the constant or in the bench document.

### Interface responsiveness

Learned from the settings window, where switching categories took 0.2–2.5 s.

- Every user action has a main-thread budget: switching screens, tabs or sections up to ~100 ms; changing one setting
  or pressing a control up to ~50 ms; opening a window up to ~300 ms. Check the budget on the slowest supported
  machine (an Intel Mac), not on the fastest.
- A new screen, window or list with many controls gets a bench before a build is handed over: the real window and
  pages, main-thread CPU time per action (`CLOCK_THREAD_CPUTIME_ID`), first visit and return separately, several
  rounds in a row. Rounds that get slower and slower mean something accumulates: that is a bug.
- A report of slowness is reproduced by a bench and profiled (`sample` or Instruments, self time per symbol) before
  anything is fixed. Measure each fix on its own; the bench document gets a before/after table and what each cause
  cost.
- Navigation does not rebuild a screen: pages built once are kept (hidden, without hit testing, hidden from
  VoiceOver) and a return to one builds nothing. In SwiftUI do not reset the tree with `.id(...)` on every switch.
- A change that concerns one place must not reach the whole tree:
  - no modifiers that change on every switch (`.disabled`, environment values) on hidden or inactive subtrees: each
    one re-evaluates every control below it; find a targeted way instead (e.g. skip invisible views in the ⇥ loop);
  - a view reads only its own state: a row that needs its own key does not read the current page or other shared
    state;
  - observed state is fine-grained: not one `@Observable` dictionary for all keys (any write wakes every reader) but
    one observable object per key or item.
- Expensive controls fill lazily: a pop-up menu holds only the chosen item until it first opens (`NSPopUpButton` on
  macOS 26 measures each item for ~1 ms); long lists are `Lazy` stacks or `NSTableView`.
- Check AppKit's traps when a window is created: without `autorecalculatesKeyViewLoop = true` every `addSubview` lays
  the window out synchronously.
- Building a screen cannot be cut into pieces, so it cannot be hidden in idle time: building pages ahead is allowed only
  when one piece fits the frame budget; otherwise a click lands in the block.
