# Circle-based subject framing

The selected priority group still produces an axis-aligned rectangular frame. Each selected box contributes a circle
at its centre, with radius `circle-radius * min(pixelWidth, pixelHeight) / 2`; class overrides may replace that factor.
The existing head expansion, target size, weights, normalisation, native zoom cap and Fit floor remain applicable.
All distances use the oriented image's pixel dimensions. There is no enclosing circle or ellipse.

## Composition and protection

Circle bounds are the required group support. Margin is a soft preference around that support. Each protected class
has a maximum cut per edge, checked independently for every detected instance; 0 means retain the complete box.
Protection padding grows the box before applying its cut allowance. Only the part available in the source photo
can be protected. Vision faces are protected at 0 by default; configured head classes inherit that policy unless
explicitly overridden. Other classes are unrestricted unless configured. Protection applies to all found instances
by default, with an option to restrict it to the selected group's classes.

First propose the existing target-size zoom and weighted centre using the new circle frame. At that scale, project
the centre into the range satisfying group support and protection. Ordinary margin may be sacrificed. Reduce zoom
only when no feasible centre remains, by the smallest amount needed. Never go below Fit or zoom in in Pan mode.
Pan with Keep zoom preserves its scale and reports an unsatisfied protection constraint instead of silently zooming
out. Manual transforms are not constrained. The result reports unchanged, shifted, zoom-reduced or blocked protection.

For near-identical consecutive targets, optionally reuse the preceding framing centre, projected through the same
current-photo constraints. Existing burst similarity thresholds remain internal; no new animation or detector work.

## Editor and persistence

Keep priority groups, weights, target size, maximum zoom, margin and overflow controls. Add a global circle radius
(25–200%, default 100%), global protection padding (0–50%, default 0%), protection scope and steady-framing toggle.
Class rows add an inherited/explicit radius, maximum cut (Off or 0–49% per edge), and inherited/explicit protection
padding. Advanced class values can live in a detail row to keep the category table usable. Quick panel controls expose
global radius, scope/padding and steady framing; class policies are edited in the profile editor. Settings round-trip
through detector profiles, session/folder overrides and drafts without losing unrelated keys. Explain any protection
adjustment in the SmartZoom panel; overlays show the actual circle support and protected regions.

## Approaches

An enclosing circle and enclosing ellipse were evaluated and rejected in favour of circles directly enclosed by a
rectangle. Per-edge limits were chosen over aggregate retained area so a tolerated loss cannot concentrate on one
important edge or be traded between separate objects. Pan precedes any scale reduction, as requested.

## Constraints and verification

Preserve local-main metadata-loader extraction. Keep public examples neutral; private models, paths, configuration
and photos stay outside the repository. Retain the existing sidebar/glass presentation and manual-input hold policy.
Verify pixel geometry on non-square images, class inheritance, protection outside the selected group, shift-only and
minimum-outzoom cases, per-edge limits, source edges, invalid inputs, Keep zoom conflicts, profile round trips,
burst stability and real AppKit editor actions. Run the repository's ordinary test pass and a fresh branch review.
