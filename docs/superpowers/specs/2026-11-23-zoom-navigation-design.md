# Stable manual zoom across photo navigation

When browsing a folder, the viewer should carry the zoom the user set past an unusually small photo. Returning to a photo should bring back its own framing, including the detail the user had in view if the window changed shape.

## Approaches

- **Carry the last displayed view.** This is simple and makes each step depend on what is currently visible. A scaled-down intermediate photo can change the baseline for the rest of the sequence, and revisiting a photo cannot recover its previous framing.
- **Restore each photo or open at Fit.** This makes revisits repeatable and avoids enlarging small files, at the cost of losing the ability to compare new photos at a shared zoom.
- **Restore each photo or carry the last manual zoom.** This is the chosen approach. The viewer remembers individual framing and uses the active carry mode to derive the zoom on a first visit. An automatic result leaves the manual reference intact.

## First visits and small photos

With **Keep Zoom** on, a first visit within the folder derives zoom from the last explicit manual zoom in that browsing sequence. An explicit Fit or percentage command is also a manual choice. An automatic carry or restore leaves that reference intact. If the user zooms a small photo themselves, that new choice becomes the reference. The existing pan setting decides where a new photo lands.

The cap applies to automatically carried free zoom. Named modes remain named. The example uses a 1200 × 800 viewing area, a 6000 × 4000 photo at a free zoom of 40%, and a new 1200 × 800 photo.

| Carry mode | Rule | New photo |
| --- | --- | --- |
| Scale | Preserve the reference's pixel scale. | 40% |
| Share of photo | Preserve the visible fraction where possible. Cap the result at 100%, or at the reference scale if the user already chose a scale above 100%. | 100% |
| Share of screen | Preserve how much of the viewing area the photo covers, including magnification past Fill. | 200% |

If the following photo is another 6000 × 4000 file, it opens at 40% in this example. The intermediate photo's automatic result is local to that visit.

## Revisits and window size

With **Keep Zoom** on, an already visited photo in the same tab uses its own last manual-mode framing. Keep its named mode or its free zoom relative to Fit. Restore the same point of the photo as close to the center of the viewing area as the edges allow. Center each axis that fits. Temporary clamping as an axis fits leaves the remembered point available when the window shape changes again.

For example, a photo at 2× Fit near an edge reopens at 2× Fit in a narrower window. A photo last viewed with the explicit 100% preset reopens at 100%. Changing another photo's zoom does not change either result.

## Controls and lifetime

- Turning **Keep Zoom** off suspends both first-visit carry and per-photo restoration during browsing. Turning it on makes previously remembered framing available and starts the next carry from the view currently shown.
- The tab remembers up to 256 recently viewed framings. Changing folders starts a new carry reference from the destination's normal opening view. The tab can still restore remembered framing for a photo when returning to a folder.
- Keep the existing persisted folder-opening rules for launches and fresh opens. In a live tab, an applicable per-photo framing wins on a revisit with **Keep Zoom** on. SmartZoom keeps control of its composition while active.

## Verification

Check forward and backward navigation with all three carry modes, including a small intermediate photo that the user leaves alone and one they zoom explicitly. Check revisits after changing the window shape and after an axis stops and starts overflowing. Check **Keep Zoom** off and back on, returning from another folder, and closing and reopening the tab. During rapid navigation, only a photo actually shown can contribute a remembered view, and later image refinements must preserve its framing. Use existing viewer and core entry points and keep navigation free of synchronous I/O.
