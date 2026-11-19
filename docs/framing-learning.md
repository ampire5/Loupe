# Learning SmartZoom framing

Loupe can learn local crop preferences from examples. Open the SmartZoom panel or the Zoom menu's
**Learn from Reference Crops** command. No images or model requests are sent to a server.

1. Browse normally and adjust pan and zoom. SmartZoom can be on or off.
2. Click **Comfortable detail view** or **Good overview composition**. These are separate intentions, not fixed zoom
   percentages: both can be close views of an already close photo, or different views of a distant scene.
3. **Remember and next photo** saves the selected intention, then advances only after successful persistence and restores the originating Auto/Pan mode for the next photo.
4. In the learning window, remove accidental references, edit series names and reserve independent series for
   validation. A folder is the initial conservative series. Moving a row to another series moves all crop variants of that source photo;
   reserving a series applies to all of its members.
5. Click **Fit preferences**. Fitting is local, cancellable and yields to foreground image loading. A fit cannot
   use the reserved series to train. With little independent data it is marked exploratory.
6. Compare your reference with **First** and **Second** on reserved images. Choose **First is better**, **Second is
   better**, **Equal** or **Both poor**. The baseline/candidate order is balanced and its labels are hidden.
7. **Apply to this tab** is temporary. **Save to profile** persists the selected intention's learned policy.
   **Undo application** restores the prior policy. Detail and Overview remain independent.

Source occupancy, object count and relative positions describe how close the scene already is; the two intentions are learned separately. The learner considers every retained detection, including objects outside your desired crop and Vision's face,
person, object and saliency categories. Saliency is attention evidence, not an exact object outline. Excluding an
object is a preference for this composition, not a request to permanently lower that category's importance.

The report separates whole-view X/Y/scale errors from each object's screen position, visibility and edge cuts.
The **best proposal** error measures the best crop the bounded generator found. If even that crop is poor, more
ranking training alone cannot fix it; candidate geometry, detection quality or model expressiveness may need work.
It is a best-found value, not proof that a better crop is impossible.

Reference geometry, frozen detections, local source bookmarks, votes and learned policies live in private Application
Support storage. Originals are not copied. Comparison votes preserve the exact reference and two transforms shown, along with the dataset revision. The store accepts at most 4,096 references and reads at most 64 MiB; unsupported or damaged files are preserved rather than overwritten. A changed file revision requires a new reference; a missing source retains
numeric evidence but cannot supply image comparisons. Initial capture supports decoded, single-image oriented views,
including Auto and Pan, with settled geometry. Saving commits a pending zoom target, stops coasting and removes elastic overscroll before capturing; the saved centre follows the same clamping as the renderer. Historical animation residuals in the incoming replay snapshot are discarded. Capture requires filesystem URLs and excludes archive entries. Mounted volumes use off-main file access; their latency has not been benchmarked here. Spread views and unsupported orientation states are rejected.

Numeric proposal parameters belong to the learned intention's private policy; the ordinary shared profile remains
the compatibility baseline. Editing that baseline or changing incompatible detector context causes a safe fallback
to the existing priority chain until a compatible policy is applied.

Feedback while viewing is optional. Confirming one intention does not require the other; a missing label is
unknown. Detail means a comfortable starting viewport for inspection and later panning; Overview means a
composition you like. Objects outside the current detail viewport are not automatically marked unimportant.

Position the pointer over the image and use **Zoom → Object Feedback under Pointer…** or its assigned shortcut.
To also open it with a plain right-click, enable **Object feedback on right-click** in the SmartZoom panel.
The checkbox is off by default and Loupe remembers it across launches.
The menu prepares fresh detections from the captured image without blocking the main thread, and rejects a
changed file or a viewer that moved on. It lists overlapping objects smallest first with category, detection ID
and source position/size so you can choose which object you mean. For that object choose **Inspect this object**,
**Do not use as centre**, **Object is blurred**, or **Detector mistake**. These are source- and intention-specific
notes, never a global reduction in a category's weight. Saving a note does not create or edit a reference crop.

**Zoom → Undo Last Framing Feedback** (also in the context menu) restores the previous state of the last successful
confirmation or object note in this viewer. It is available after persistence and refuses to undo across another
edit, including edits from another window. Toasts confirm successful persistence and point to undo.

The new object notes are stored for subsequent modeling; the current fitter does not consume them yet. Comparison
votes likewise remain explicit stored evidence. **Compare framing variants…** opens the existing learning window;
comparison requires a fitted candidate and reserved validation images. There are no automatic comparison prompts
and ordinary browsing does not trigger fitting or implicit approval labels.

All these actions can be assigned in `input.conf` to keys or mouse buttons; existing bindings are unchanged:

```text
MBTN_BACK confirm-detail
MBTN_FORWARD confirm-overview
MBTN_MID show-framing-feedback
# Also: confirm-detail-and-next, confirm-overview-and-next,
# undo-framing-feedback, compare-framing, toggle-framing-intent
```

`toggle-smart-zoom` switches automatic framing on/off, and `toggle-framing-intent` switches Detail/Overview.
Manual viewport changes are retained; switching intention does not silently undo a manual inspection zoom.

Keyboard shortcuts in the viewer (also shown in the Zoom menu):

| Shortcut | Action |
| --- | --- |
| ⌥1 | Confirm comfortable detail view |
| ⌥2 | Confirm overview composition |
| ⇧⌥1 | Save detail crop and next photo |
| ⇧⌥2 | Save overview crop and next photo |

The toast names the saved intention and photo only after the write succeeds. Saving and next advances after
success; failed capture or persistence shows an error and leaves the current photo in place. Shortcuts ignore
key repeat and are inactive behind sheets or when a different window has focus.
