# Upscale models

Loupe can use local Core ML models to add detail to SDR photos while you view them. The app ships without model files. Choose models you trust and follow their licenses.

1. In a viewer slot's **+** menu, add **Neural Upscale**. The slot shows the model directory and has a **Choose Folder…** button.
2. Put any number of compatible model bundles in the directory. The default is `~/Library/Application Support/Loupe/Upscale Models`. Create this directory if needed, or select a directory that already exists.
3. Click **Reload**, choose **Scale** (2× or 4×), then choose a compatible **Model**. Enable **Zoom → Neural Upscale** or press **⌥U**. Press **⌥⇧U** to remember the current on/off setting for new windows and tabs.

A compatible model is a `.mlpackage` or compiled `.mlmodelc` with one RGB image input and one RGB image output whose declared dimensions are exactly 2× or 4× the input width and height. Loupe uses the declared default input size for each tile. Loupe reads the input and output names from the model. Tensor input or output requires conversion to Core ML image features before installation. For example, a 2× model with 384×384 RGB input declares a 768×768 RGB output. Keep the model bundle's internal directory structure intact.

**Compute** selects the hardware Core ML may use. Automatic allows CPU, GPU and Neural Engine. **Tile context** is the number of input pixels along each interior tile edge reserved for context. Loupe discards the corresponding output border before stitching. More context can reduce visible seams and increases the number of tiles for a fixed model input size.

Loupe remembers the overrides for each model path. To distribute default settings alongside a model, place a JSON file with the model bundle's full name plus `.json` next to it. For `Example.mlpackage`, write `Example.mlpackage.json`:

```json
{
  "name": "Example",
  "margin": 40,
  "compute": "cpuAndGPU"
}
```

The supported compute values are `cpuAndGPU`, `cpuAndNeuralEngine` and `all`. The default context is 16 pixels and the default compute setting is CPU and GPU. The tile's usable interior must be at least one pixel wide and high.

## While viewing

- **⌥U** toggles Neural Upscale for this viewer. Standard zoom commands, folder zoom rules and SmartZoom control the display size and position. The slot's **Scale** sets the native model output size. Change the shortcut by binding `toggle-neural-upscale` in `input.conf`.
- The viewer draws the photo immediately. A new result replaces its pixels at the same size and position once the texture is ready, while any requested AVIF saves. With lookahead or automatic saving enabled, this includes Fit. With both off, a new in-memory result is used above 100%. A saved upscale takes over at any zoom, including Fit, even when Neural Upscale is off. Use **Zoom → Show Original** or **Show original** in the slot to compare at the same zoom and position. The next photo uses its enhanced version by default.
- **Look ahead** sets the next 0–8 playlist positions to prepare in the direction you are browsing. The default is **Off**. The current photo has priority. The buffer starts after a pause and drops obsolete work as you move. If a photo is already being prepared when you open it, its calculation continues while the original loads. Jobs for photos still ahead after a jump can also continue. It is constrained by the output memory budget. With lookahead or automatic saving enabled, inference can prepare photos at Fit.
- The in-memory cache is shared across viewers. Its key includes the photo revision, model revision and parameters. Use **Reload** after replacing a model or editing its sidecar file.
- Source pixels pass through 8-bit sRGB for inference, which can clip wide-gamut colors. Videos, transparency, HDR, spreads and requests outside the memory or tile limits keep the regular display path. The buffer and automatic saving skip formats that may contain animations.

## Saving and replacing

**Save copies automatically** keeps enhanced AVIFs at ImageIO quality 78/100 for filesystem photos and photos inside ZIP archives. It is on by default and can be disabled in the Neural Upscale slot. Loupe writes to the hidden `.loupe-upscales` directory beside the source photo or ZIP and uses the latest saved result for that source revision. Reopening the photo reuses its saved result regardless of the selected model. Changing the model, scale or model settings while Neural Upscale is enabled can rebuild the open photo. The copy stays out of the playlist and File View. The original card shows the enhanced thumbnail and an **Upscale** indicator. A file renamed, moved, or edited externally needs a new saved result. Earlier PNG copies are ignored and remain on disk.

In File View, use Command-click to select individual images or Shift-click to select a range. Choose **Batch Upscale** from the context menu or the File menu. The batch uses the current model and scale and saves AVIFs even when automatic saving is off. It skips images that already have a saved upscale or whose originals were replaced with one. **File → Cancel Batch Upscale** stops the batch and keeps any copies already saved.

Use **Replace Original…** in the viewer slot or **Replace Original with Upscale…** on a File View photo. The folder's context menu also offers **Replace Originals with Upscales…**. It counts eligible files directly inside that folder and asks before replacing any. Replacement supports regular JPEG and PNG files with a current copy. The new file uses the original format and orientation. The complete originals, including their file metadata, are backed up in `.loupe-upscales/Originals`. Loupe skips a file if its original changed after the confirmation.

## Performance on M4 Max

On a 36 GB M4 Max, an FP16 2× model with 384×384 input, 40 pixels of context and CPU + GPU processed the macOS Default Aerial photo in **354 ms at 1920×1080** and **1156 ms at 3840×2160**. These are medians of three warm runs through Loupe's source readback, tile inference, stitching and GPU pyramid upload. The first 1080p run took 456 ms. The measurements start with a decoded photo and exclude the viewer's 150 ms dwell.

The retained cache holds up to 512 MiB, with a 256 MiB cap per result and smaller limits under memory pressure. A 4K input with a 2× model retains about 204 MiB in full and reduced Metal textures, including tile borders. Temporary inference and upload buffers are additional.
