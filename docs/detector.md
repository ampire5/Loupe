# Custom detector

SmartZoom can compose detections from a compatible, user-supplied Core ML object detector alongside Vision's faces,
people, objects and saliency. Loupe ships no models, weights or class-specific setup scripts. Choose models suitable
for your own use and prepare their compiled `.mlmodelc` packages with the model author's tools. The output must be
object observations understood by Vision, such as an object detector exported with non-maximum suppression.

## Controls and remembered choices

- **Shift-Z** or the toolbar **SmartZoom** button applies Auto using the selected profile's priority chain. Repeating
  it reapplies Auto; it does not toggle into another behavior.
- **Option-S / G** switches between Manual and the last SmartZoom behavior. Leaving SmartZoom keeps the achieved view.
- **0** selects Manual + Fit and preserves the selected profile and model. Ordinary fixed zoom presets select Manual.
- **M** selects the next profile; **N** selects the next complete group found on the photo.
- A manual wheel/pinch adjustment affects the current photo; it never teaches a new profile size. **Shift-M** explicitly
  saves the current framed size to the selected profile.

The last profile selection is remembered automatically for its folder. A last-used fallback is restored on later
launches when no explicit global/folder choice overrides it. This does not implicitly save composition parameters or
ordinary zoom preferences. Their save commands remain separate. The current Manual, Pan or Auto behavior also survives
relaunch; Manual remembers which SmartZoom behavior its toggle will resume.

## Model selector

Open the optional SmartZoom Slot panel from the toolbar. **Detection model** lists local compiled models and their
input resolution when metadata provides it. The list includes `~/Library/Application Support/Loupe/Models`, the
configured model's directory and the selected model's directory. **Choose model…** opens a file picker for another local compiled model. These controls appear at the top of the panel.

Selecting a model loads and validates it off the main thread, preserving the profile and its composition settings.
The last model selection survives relaunch. An unavailable remembered model falls back to the configured model.
An incompatible or failed model leaves the previous selection active and shows an error in the panel.

A model change invalidates pending framing and existing crop overlays, then analyses the current photo again when
SmartZoom is enabled. Boxes from another model cannot be reused as if they were from the selected model. Manual mode
starts no photo analysis. Catalog enumeration and model loading run off-main; the model cache is bounded.

## Profile editor

In the SmartZoom Slot panel, use **New profile…** to create a profile or **Edit profile…** to change the selected one.
The system Vision fallback is not an editable custom profile.

Select categories from your configured model mappings, then **Add** a priority rule. Select multiple model categories
to require them together. Vision categories are individual fallback rules. Select a rule to replace or remove it;
**↑ / ↓** changes its priority. The first complete group found on a photo wins.

Each category has a weight from 0.25 to 4. **Weight per type** shares that weight among instances of the same type;
**Weight per object** gives it to each instance. Adjust target size, maximum auto zoom, margin and Pan overflow in
the same editor. Categories come from your local model configuration; the editor does not invent detector labels.

**Create profile / Save profile** writes the draft to your private `detector.conf`, selects the profile and preserves
Manual/Pan/Auto. **Cancel** leaves the file unchanged. Loupe keeps a backup before the first editor write and reports
validation or write errors in the sheet. Profile edits affect all windows; model selection remains independent.

## detector.conf

This local file, next to `loupe.conf`, defines class mappings and composition profiles:

```
detector = off
model = ~/Models/pets.mlmodelc
look = whole, people
mode = play
score = 0.5
margin = 8%
max-zoom = 100%

[classes]
CAT_FACE = cat
DOG = dog
BALL = ball

[play]
chain = dog+ball, ball, cat, face, person, object, saliency
size = 65%
weights = dog:1.25, ball:1
weight-normalization = class
pan-overflow = fit

[pets]
chain = cat+dog, cat, dog, face, person
size = 70%
```

The first complete group in the chain wins. A `+` group requires every named type and includes all instances of those
types; distance does not reject it. The selected rectangles form one union. Weights affect the desired centre, while
full visibility, photo bounds and scale limits constrain the result. Auto never goes below Fit. Pan only never zooms
in; `pan-overflow=fit` reduces scale when necessary to fit the group, while `keep` preserves scale and keeps an object
visible if the weighted centre lands in empty space.

Legacy `reach` and `min-frame` are accepted for configuration compatibility but do not reject complete groups or
control the new composition. Changing a profile does not need inference again; changing a model or class mapping does.
