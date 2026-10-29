# Zoom and position across ordinary photo steps

The installed pre-composition SmartZoom build reproduced `400% → Right → Fit` on two identical neutral PNG files. Turning the detector off with `0` did not resolve it: the independent `step-zoom=subject` remained active. Choosing Zoom After a Step → As Kept preserved 400% through the same transition. The temporary test tab was closed afterward.

The SmartZoom branch now has one explicit Off / Pan only / Auto framing state. Off uses the kept view; Pan only preserves zoom and composes position; Auto framing explicitly owns zoom. Legacy auto-step controls no longer compete in the primary UI. Initial loading of the old configuration selects Pan only unless the new SmartZoom mode says otherwise.

A real ViewerWindowController/ViewerSession benchmark loaded both supplied JPEG XL files (10470×13956) and stepped using the viewer's actual Previous/Next actions, with detection disabled and Keep Zoom enabled. Results on both the SmartZoom branch and unchanged main (4742d86):

| View before the step | Scale after step | Stored center after step |
|---|---|---|
| 100% | 100% | (0.4, 0.65) |
| Free zoom, 3×Fit | unchanged | (0.4, 0.65) |
| Fit Width | Fit Width | (0.4, 0.65) |

Thus the verified cause is the old automatic framing override, which does not exist on main. Main's production behavior needs no speculative patch. A regression test in both branches pins ordinary stepping and subsequent image refinements so they cannot replace the kept view with default Fit.

Private logs and image paths are not included in the repository. The repeatable application benchmark in the SmartZoom branch is `Loupe --zoom-carry-bench <fixture-folder>`; its fixture contains `001.png` and `002.png`. Set `LOUPE_BENCH_WINDOW_RULES=1` to exercise the real window's configured rules, or `LOUPE_BENCH_EXTENSION=jxl` for JPEG XL. Use a disposable `LOUPE_CONFIG_DIR`; do not run with an auto-framing configuration when verifying normal carry.
