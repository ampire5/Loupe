# SmartZoom profile editor verification

Verified on an Apple Silicon Mac (14 physical cores). Intel was not available.

- Core: 2,181 tests passed; Settings: 63 passed.
- Regression: commented and spaced profile headers initially produced duplicate sections; the fix edits one section
  in place and preserves the header. Atomic queued writes retain simultaneous edits to different profiles.
- Independent application processes: write Auto, read Auto; write Manual with remembered Pan, read Manual and resume
  Pan. Both the selected profile and mode were restored using a real temporary state database and isolated defaults.
- Actual panel/sheet actions: create with a category/weight, edit, add and reorder fallback rules, save, then reopen,
  change and cancel. File contents and selected profile were checked after each transaction. Manual stayed Manual.
- Measured sheet creation: 77.9 ms, edit: 67.7 ms, reopen: 74.0 ms, within the 300 ms local budget. This short run is
  not an extended memory or Intel performance assessment.

The GUI driver uses a disposable configuration containing user-supplied model mappings and neutral generated photo
fixtures. Never run it against a personal configuration: it creates `bench-custom`. Use a fresh copy for each run.

```sh
LOUPE_CONFIG_DIR=/tmp/loupe-editor-test \
LOUPE_DETECTOR_PREFERENCES_SUITE=local.loupe.editor-test \
LOUPE_BENCH_WINDOW_RULES=1 LOUPE_BENCH_PROFILE_EDITOR=1 \
.build/debug/Loupe --zoom-carry-bench /tmp/loupe-photo-fixtures
```

For independent-process persistence checks, replace `LOUPE_BENCH_PROFILE_EDITOR` with
`LOUPE_BENCH_REMEMBER=write-auto`, then `read-auto`, `write-manual-pan`, and `read-manual-pan` in separate launches.
Set the same `LOUPE_BENCH_STATE_DIRECTORY=/tmp/loupe-editor-state` and preferences suite for all four launches.

The installed application was older than the development bundle during diagnosis. Deployment verification therefore
includes replacing the actual installed bundle and checking its build label, rather than only producing a new build.

SmartZoom-5 was installed with a private backup of the old bundle; the installed signature and build label were
verified. The installed executable repeated the editor transaction checks successfully (create 75.0 ms, edit 69.4 ms,
reopen 64.7 ms). Native automation could not attach to the ordinary application window (`cgWindowNotFound`), so
interactive deployment verification is limited to the executable's panel/sheet driver. The already running old
application was not forcibly terminated; restart it to use the update.
