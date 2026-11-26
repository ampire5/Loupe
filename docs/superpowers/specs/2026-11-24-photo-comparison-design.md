# Photo comparison

Compare two still photos in equal side-by-side viewports in a dedicated Loupe tab. The pair is fixed for the lifetime of that view. Source tabs keep their existing view and selection.

- Select exactly two photos in File View and choose **Compare Selected Photos**. Across tabs, choose **Select for Comparison** on A, then **Compare with Selected Photo** on B. The selected A is a photo address rather than a live subscription to its tab.
- Equal-proportion photos initially fit in both panels at the same displayed size, centered and linked. For example, a 6000 × 4000 image at 50% corresponds to a 3000 × 2000 image at 100%.
- Different proportions start independently fitted. Unlink to adjust either photo, then link again without moving either photo. **Match Visual Scale** uses the active panel as the reference and matches displayed widths. It is available for equal-proportion photos, where matching width also matches height.
- Linked pan uses the same screen displacement in both panels, limited by the first edge on each axis. Linked zoom applies the same multiplier around corresponding viewport positions, subject to both zoom limits. Each panel reports its real pixel zoom.
- Reuse the existing bounded cache and Metal renderer. The tab is transient and excludes playback and playlist navigation.

The existing two-page spread is built around a single virtual canvas. Comparison uses two independent viewports so both can be centered, zoomed, clipped and adjusted separately while reusing the photo pipeline.
