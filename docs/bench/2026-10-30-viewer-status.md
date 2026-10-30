# Unified viewer status — 2026-10-30

The status is a retained AppKit view, fixed at 46 pt, in the native unified toolbar. Neutral fixtures exercise the actual controls and session command routes without opening user media.

## Environment and method

Apple M4 Max, 14 physical cores; debug arm64 build, macOS 27 SDK, deployment target macOS 26. Build concurrency: four jobs. Measurements use `CLOCK_THREAD_CPUTIME_ID` through `ThreadCPU.milliseconds()`, on the main actor. They are CPU time, not elapsed animation time or an Intel result.

`ViewerToolbarStatusTests.nativeWindowBenchAndSnapshot` opens an actual NSWindow and NSToolbar, applies 100 changed statuses per round, resizes through seven widths, constructs a current profile menu, and opens/closes the retained numeric NSPopover. Ten rounds distinguish first use from returns. Settling periods isolate deferred resize drawing from the next operation; they are test-only and do not exist in the application. Native menu tracking is excluded from timings: its modal event loop includes unrelated UI work. The measured menu operation is construction of its current items.

Reproduce with the prepared decoder dependencies:

```sh
LOUPE_STATUS_BENCH=1 PKG_CONFIG_PATH="$PWD/.deps/arm64/lib/pkgconfig" \
  swift test --jobs 4 --triple arm64-apple-macosx26.0 --filter ViewerToolbarStatusTests
```

Set `LOUPE_STATUS_PROFILE=1` to write the test PID to `/tmp/loupe-status-profile.pid` and allow a bounded two-second attachment interval before the first panel. `sample PID 4 1 -file /tmp/loupe-status-sample.txt` collects a four-second profile at 1 ms intervals. This instrumentation is limited to the opt-in test.

## Results

Initial unprofiled run, all nine status tests passed:

| Operation | First round, main CPU ms | Return rounds 2–10, main CPU ms |
| --- | ---: | ---: |
| Create and show window/toolbar | 47.954 | — |
| Change status and lay out, per update | 0.089 | 0.077–0.151 |
| Resize and lay out, per resize | 9.247 | 8.740–9.972 |
| Build profile menu | 0.053 | 0.042–0.145 |
| Open numeric panel, including first draw | 65.593 | 7.207–13.419 |

There is no increasing cost across return rounds. Identical updates do not rebuild views or ask for menu choices. There are no timers, I/O or detection requests in the status view. Resize work runs only on window resize notifications.

The first numeric panel remains above the approximate 50 ms control budget. A separate sample traced its first responder path through `NSTextField.selectText`, `NSTextInputContext.invalidateCharacterCoordinates`, `NSCampoLightweightUIController.isEligible`, and the cold `WritingToolsUILibraryCore` / `dlopen` path. Numeric fields now explicitly disallow prose tools, but the observed cold panel cost did not materially improve (58.961 ms before, 65.593 ms after, within run variability); this is not recorded as a performance fix. Warm returns remain below budget. Physical Intel measurement and cold-panel investigation remain release checks; no distributable build was handed over.

## Geometry and regressions

The native toolbar keeps the status attached at window widths 320, 400, 640, 800, 1024 and 1800 pt. Back remains inline from 400 pt. Secondary controls yield to native overflow. The status reserves up to 900 pt and leaves 240 pt for native titlebar/Back/overflow space, with a 140 pt lower bound at the 320 pt minimum window. Those limits were checked in the actual unified toolbar on the machine above, not inferred from a browser mockup.

Standalone geometry also checks 140–1800 pt allocated widths, long names and EXIF values. Every EXIF field retains positive space; at extreme compression text truncates and its full value remains in the tooltip/accessibility text. All five values fit without truncation at normal wide allocation. Measurements use the text cell size: NSTextField's intrinsic width was smaller than its actual cell width and prematurely inserted ellipses. Profile/group remain available through every collapse stage. Delayed/missing EXIF and resizing from missing metadata back to loaded metadata are covered.

## Validation and release state

- Nine focused native status tests, including the real-window benchmark: pass in the main checkout and the isolated check copy.
- Ordinary suite in an isolated source snapshot, excluding the two concurrently incomplete PhotosPresentationTests files and renderer suite: 2207 core, 63 settings, and 17 native tests passed. This was supporting evidence while the shared checkout was being edited, not a claim that all current Photos changes pass.
- The subsequent ordinary run in the main checkout failed in concurrent Photos work: PhotosLocationTests.reopeningTheSamePhotosAssetRefreshesItsCollectionOrder and an AppKit abort in PhotosBrowserTests. Those files were not changed by this task. Scoped status checks still pass.
- Independent scoped review found EXIF overflow and hidden-state restoration issues; both were fixed and covered by regressions.
- `kits-check.py --no-fetch` reports the existing unmerged HomeScreenKit polish-3 branch/edit mode. The original released HomeScreenKit pin is preserved. Kit release/merge and physical Intel checks are still required before distribution.
- Status changes are collected in a separate commit on polish-3; unrelated pending work is preserved.

## Visual follow-up

Restored native graphical previous/next, zoom steps, five zoom presets and SmartZoom settings to the left of the status. Keep Zoom moved to that button row and follows session state; it does not control full-screen toolbar visibility. The third section now aligns Zoom/Mode/Profile/Group captions above their values and uses a two-column grid when narrow. Ten focused tests pass, including active preset selection, Keep Zoom state, wide-row alignment and the existing 320–1800 pt native window checks. The previous cold-panel measurements remain historical evidence, not a claim that this visual correction fixes the native first-use cost.

## Compression and text alignment correction

Removed the resize-dependent 900 pt minimum reservation: the native item now compresses between 140 and 840 pt before other controls overflow. The capture section measures its metadata/EXIF text and is capped at 320 pt instead of taking a fixed fraction of the status. A native 1800 pt window regression verifies that the Vibrance slider stays visible. Text buttons use leading alignment; third-section captions are muted uppercase 11 pt above brighter 12 pt values. The previous 240 pt window reservation described above is historical and is no longer used.

## File/group space and workflow correction

Restored the native Manual / SmartZoom selection group and its existing manualZoom / zoomSubject commands. Its selected state follows the session. Back keeps precedence at narrow widths. Quick zoom presets yield to native overflow before colour sliders.

The file title now uses the complete first row. Folder text uses the second row; its position counter hides first below a 320 pt file section instead of taking space from the folder. Duplicate step arrows remain in the native toolbar rather than consuming the file section. File space can grow to 600 pt according to its text; the status is no longer capped at 840 pt. A bounded 680 pt content floor is used on desktop widths, falling to 140 pt with narrower windows, to protect names rather than an empty capture column.

Profile and group use separate rows with aligned inline captions. The group gets the whole second row, and its preferred width follows its text, capped at 500 pt before truncating with a full tooltip. Zoom and the active SmartZoom mode share the profile row. Native snapshots now include a 2400 pt desktop and realistic longer file/folder/group names.

The workflow/name correction passed all ten focused tests in the main checkout and the isolated source check. Native checks still cover 320–1800 pt and Vibrance visibility at 1800 pt. Workflow tests verify Manual/SmartZoom state synchronisation. Final snapshots exercise longer titles at 2400, 1800, 1280, 640 and 320 pt.

## Ultra-wide balance regression

The previous screen-sized maximum let all surplus width accumulate in the third section. The toolbar maximum is now the sum of measured preferred file, capture and zoom-section widths. The same measurement drives native bounds and internal layout; space beyond that stays outside the glass. File/capture/zoom remain capped at 600/320/500 pt respectively and can compress below their preferred sizes. The folder measurement now includes the complete 88 pt counter/inset budget, avoiding a two-point truncation. Eleven focused tests pass, including native 2400/3000 pt widths, content-bound item size, growth for realistic longer names/groups, and full text fitting at its preferred width.
