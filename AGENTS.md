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

## Kits and branches

An app of this family builds on kits released by tag; kit work for the app's branch `X` goes on a branch `X` in the
kit. A branch is closed kits first: kit `X` merged into the kit's `main`, the kit tagged, the app's Package.swift and
Package.resolved moved to that tag (never committed from `swift package edit` mode), the app's CI green, only then the
app's `X` merged; last, the `X` branches deleted and the kits' clones back on `main`. In Loupe the steps are in
docs/kits.md and `scripts/kits-check.py` checks them.

## Architecture entry point

Read [docs/architecture.md](docs/architecture.md) before changing a subsystem. Follow its source/test entry points,
and update it in the same change when ownership, data flow, target dependencies or cancellation changes.
Historical plans and specs explain decisions; verify current behavior against the architecture map and source.

## Soft Detents / Semantic Stops

Use a soft detent when a continuous control has a few values worth landing on exactly, such as unity gain,
zero rotation, a fit scale or a timeline landmark. Preserve fine adjustment between them. Use hard steps
for inherently discrete choices and reserve hard bounds for the actual limits of the range.

- **Snapping** chooses a discrete target at a boundary or on commit. **Magnetic snapping** pulls a nearby
  value toward a target based on proximity. A **stateful detent** captures a landmark during a gesture, holds
  the displayed value while input keeps moving, and releases when signed travel exceeds a threshold.
- **Capture radius** defines the approach zone. Measure it in the control's native motion units, such as
  doublings for zoom. Keep it small and cap it on each side at the midpoint to the neighboring landmark.
  Emit one capture cue and keep the gesture active.
- **Breakaway threshold** measures signed input displacement from the capture point. Reversal unwinds
  displacement before building it in the opposite direction. Tune the threshold for each input mapping.
  Prefer a spatial threshold over timed lockouts or absolute-distance accumulation.
- **Hysteresis** suppresses the released stop until the value clears its capture zone by a margin.
  Other stops stay available. **Velocity bypass** lets a deliberate sweep pass without latching. Estimate
  speed from raw input with valid timestamps. Preserve a predictable spatial fallback for untimed input.
- **Continuity** starts release at the held value and applies only the displacement beyond the threshold.
  Rebase the input-to-value mapping at that transition and retain its ordinary sensitivity. Avoid replaying
  absorbed travel, jumping to a neighboring landmark, warping the pointer or animating the value behind input.
  Keep the held value on release and discard gesture state. On cancellation, follow the control's existing
  commit or rollback convention and discard the state without applying pending motion.
- **Input and accessibility** share landmark values across mouse, trackpad, touch, keyboard and assistive
  actions. Give discrete actions an explicit route to landmarks and fine steps independent of gesture speed.
  Expose a label, current value and adjustment actions. Keep visual or spoken feedback available alongside
  optional haptics, and announce meaningful changes without repeating the hold on every event.
  See [Apple's accessibility guidance for adjustable controls](https://developer.apple.com/videos/play/tech-talks/111433/).
- **Acceptance** exercises approach from both sides, hold across pauses and jitter, signed reversal, release
  just past the threshold, immediate reversal after release, and recapture after clearance. Check fast sweeps
  across several landmarks, fine adjustment away from stops, close landmarks, limits, and a fresh gesture after
  end or cancel. Replay different event sizes and check the feel on each supported device. Verify exact landmark
  values, continuity at breakaway, and usable feedback with haptics disabled and with assistive input.
