# File browser inspector

Approved in chat: a hideable right inspector with disclosure sections, following the selected file without opening it. Native AppKit controls, selectable values, a compact thumbnail/name/format summary, primary image facts, Capture or Generation, File and Location, and Technical Details. Remember width and expanded sections. Empty sections disappear. Cmd-I in File View and a toolbar button toggle it; the photo viewer keeps its existing panel.

## Approaches

Disclosure sections were selected over tabs: the primary facts stay visible and related details can be read together. A floating window was considered less useful for browsing a grid. Use a native split-view inspector with its own space, not an overlay on the cards.

## Responsiveness

Selection immediately clears the old file's values and shows known listing facts. Only the latest pending selection is read; at most one inspector read runs per window. File access and metadata parsing are utility work. No full image decode for metadata. Thumbnail work uses bounded downsampling. Cache by URL, size and modification time; stale replies are discarded. Hide, park and invisible windows stop pending work. Native synchronous reads already in progress may finish; they must not create an unbounded backlog. ZIP metadata may require extraction, so only a settled selection can start it.

No idle polling or diagnostic timer in File View. Build inspector controls once, update changed values. Benchmark the real window, first/return visits and repeated selections using main-thread CPU time; record machine and limitations. Intel hardware measurement remains required before claiming Intel budgets.

## Scope and defaults

Initial width 320 pt, native draggable divider, sensible minimum width. No automatic edge reveal for this initial docked inspector. The referenced user glass guide was absent at the supplied path; avoid inventing its motion timings or glass palette. Use a standard inspector material and system label colors. Native disclosure triangles, scroll view and buttons. Empty selection and unsupported sources get explanatory states. No recursive folder-size work, Maps loading or generation-workflow parsing. Local implementation only: no publishing kit releases or changing unrelated work.

## Follow-up: lazy creation

At the user's request, a hidden inspector now registers only a one-shot factory and toolbar action. Its controller, loader and split item are created on first visible request and retained afterward. A visibility request while Home is parked waits for unpark; explicit restore of an open inspector still creates it when it needs to become visible. Selection callbacks before construction do not read files; the factory takes the latest selection on first opening. See docs/bench/2026-10-29-lazy-startup.md for the A/B measurement and further startup candidates.
