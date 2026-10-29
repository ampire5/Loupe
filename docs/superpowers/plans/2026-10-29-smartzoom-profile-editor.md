# SmartZoom persistence and profile editor implementation plan

Execute inline with superpowers:executing-plans and one independent review at the end.

- [x] Add regression tests for restored mode/last-enabled state and safe profile creation/editing.
- [x] Persist and restore runtime SmartZoom mode; verify profile and mode with separate write/read processes.
- [x] Add a graphical profile editor and clear model controls to the retained Slot panel; serialize writes off-main.
- [x] Verify actual sheet/actions and UI CPU budgets, run Core/Settings tests, review, build/sign/install the new bundle
      in the existing application location. The old bundle is backed up; the user must restart the already running old
      process. Native automation could not attach to its window (cgWindowNotFound); no forced termination was used.
